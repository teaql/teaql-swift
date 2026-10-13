import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import TeaQLCore

/// The SDK moves an entire staging list out of its native queue. Admission
/// therefore lasts until actual export completion, not until dequeue. This is
/// a bounded identity ledger, not another payload queue.
final class QueueAdmission: @unchecked Sendable {
  private let lock = NSCondition()
  private let capacity: Int
  private let signal: String
  private let losses: ExportLosses
  private struct Entry { let sequence: Int; var exporting = false }
  private var pending: [String: Entry] = [:]
  private var closed = false
  private var offered = 0, admitted = 0, completed = 0, overflow = 0, late = 0, handoffFailed = 0, retired = 0
  private var peakOutstanding = 0
  private struct PrefixWaiter { let prefix: Int; let complete: @Sendable (Bool) -> Void }
  private var waiters: [UUID: PrefixWaiter] = [:]
  init(signal: String, losses: ExportLosses, capacity: Int = 2048) {
    precondition(capacity > 0)
    self.signal = signal; self.losses = losses; self.capacity = capacity
  }
  var outstanding: Int { lock.withLock { pending.count } }
  var snapshot: [String: Int] {
    lock.withLock { ["offered": offered, "admitted": admitted, "completed": completed,
      "overflow": overflow, "post_shutdown": late, "handoff_failed": handoffFailed,
      "retired": retired, "outstanding": pending.count, "peak_outstanding": peakOutstanding,
      "exporting": pending.values.filter { $0.exporting }.count] }
  }
  var prefix: Int { lock.withLock { admitted } }
  /// Async lifecycle callers must not exhaust Dispatch's thread pool while
  /// waiting for SDK OperationQueue work that needs that same pool.
  func observe(prefix: Int, timeout: TimeInterval, complete: @escaping @Sendable (Bool) -> Void) {
    let ticket = UUID()
    let pendingPrefix = lock.withLock {
      guard pending.values.contains(where: { $0.sequence <= prefix }) else { return false }
      waiters[ticket] = PrefixWaiter(prefix: prefix, complete: complete); return true
    }
    guard pendingPrefix else { complete(true); return }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
      let expired = lock.withLock { waiters.removeValue(forKey: ticket) }
      expired?.complete(false)
    }
  }
  private func readyWaitersLocked() -> [PrefixWaiter] {
    let ready = waiters.filter { waiter in !pending.values.contains { $0.sequence <= waiter.value.prefix } }
    for ticket in ready.keys { waiters.removeValue(forKey: ticket) }
    return Array(ready.values)
  }

  /// Wait for actual completions in the captured successful-handoff prefix.
  /// Later admissions cannot extend this wait, and newer completions cannot
  /// substitute for an older record. Native forceFlush can cancel a staged
  /// SDK operation without exporting its records, so it is not our oracle.
  func wait(prefix: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(max(0, timeout))
    lock.lock(); defer { lock.unlock() }
    while pending.values.contains(where: { $0.sequence <= prefix }) {
      if !lock.wait(until: deadline) { return !pending.values.contains { $0.sequence <= prefix } }
    }
    return true
  }

  /// Only the SDK's nonblocking handoff runs under this lock. No business
  /// callback, exporter, HTTP request or diagnostic may run under it.
  @discardableResult
  func submit(_ identity: String, handoff: () -> Bool) -> Bool {
    let reason: String? = lock.withLock {
      offered += 1
      guard !closed else { late += 1; return "shutdown" }
      guard pending[identity] == nil else { handoffFailed += 1; return "handoff_failure" }
      guard pending.count < capacity else { overflow += 1; return "queue_overflow" }
      pending[identity] = Entry(sequence: admitted + 1)
      guard handoff() else { pending.removeValue(forKey: identity); handoffFailed += 1; return "handoff_failure" }
      admitted += 1
      peakOutstanding = max(peakOutstanding, pending.count)
      return nil
    }
    if let reason { losses.record(signal: signal, count: 1, reason: reason); return false }
    return true
  }
  func beginExport(_ identities: [String]) -> Set<String> {
    lock.withLock {
      var admitted = Set<String>()
      for identity in identities where pending[identity]?.exporting == false {
        pending[identity]?.exporting = true; admitted.insert(identity)
      }
      return admitted
    }
  }
  func complete(_ identities: Set<String>) {
    let ready = lock.withLock {
      for identity in identities where pending.removeValue(forKey: identity) != nil { completed += 1 }
      lock.broadcast()
      return readyWaitersLocked()
    }
    ready.forEach { $0.complete(true) }
  }
  func close() { lock.withLock { closed = true } }
  func recordLateOffer() {
    lock.withLock { offered += 1; late += 1 }
    losses.record(signal: signal, count: 1, reason: "shutdown")
  }
  /// Only never-attempted entries are retired. Exporting records retain their
  /// identity until transport cancellation completes and are never counted
  /// again as retirement. SDK copies subsequently skip retired tickets.
  func retireQueued() {
    let (count, ready) = lock.withLock {
      closed = true
      let queued = pending.filter { !$0.value.exporting }.map(\.key)
      for identity in queued { pending.removeValue(forKey: identity) }
      retired += queued.count; lock.broadcast(); return (queued.count, readyWaitersLocked())
    }
    losses.record(signal: signal, count: count, reason: "shutdown")
    ready.forEach { $0.complete(true) }
  }
}

private func spanIdentity(_ context: SpanContext) -> String {
  context.traceId.hexString + ":" + context.spanId.hexString
}
private func spanIdentity(_ span: SpanData) -> String {
  span.traceId.hexString + ":" + span.spanId.hexString
}

final class AdmittedSpanProcessor: SpanProcessor, @unchecked Sendable {
  let admission: QueueAdmission
  private let batch: BatchSpanProcessor
  private let exporter: AdmittedSpanExporter
  let isStartRequired = false, isEndRequired = true
  init(exporter: any SpanExporter, losses: ExportLosses) {
    admission = QueueAdmission(signal: "traces", losses: losses)
    self.exporter = AdmittedSpanExporter(exporter, admission: admission)
    batch = BatchSpanProcessor(spanExporter: self.exporter,
      scheduleDelay: 0.2, exportTimeout: 3, maxQueueSize: 2048, maxExportBatchSize: 128)
  }
  func onStart(parentContext: SpanContext?, span: any ReadableSpan) {}
  func onEnd(span: any ReadableSpan) {
    guard span.context.traceFlags.sampled else { return }
    admission.submit(spanIdentity(span.context)) { batch.onEnd(span: span); return true }
  }
  func forceFlush(timeout: TimeInterval?) {
    if !admission.wait(prefix: admission.prefix, timeout: timeout ?? 6) {
      RuntimeTelemetryStartup.notice("TeaQL telemetry: traces flush prefix incomplete; business outcome unchanged.")
    }
  }
  func shutdown(explicitTimeout: TimeInterval?) {
    admission.close()
    if !admission.wait(prefix: admission.prefix, timeout: min(5, explicitTimeout ?? 5)) {
      admission.retireQueued(); exporter.shutdown(explicitTimeout: 0.5)
      if !admission.wait(prefix: admission.prefix, timeout: 0.5) {
        RuntimeTelemetryStartup.notice("TeaQL telemetry: traces shutdown prefix incomplete; business outcome unchanged.")
      }
    }
    batch.shutdown(explicitTimeout: 0.5)
  }
}

private final class AdmittedSpanExporter: SpanExporter, @unchecked Sendable {
  private let exporter: any SpanExporter
  private let admission: QueueAdmission
  private let closeLock = NSLock()
  private var closed = false
  init(_ exporter: any SpanExporter, admission: QueueAdmission) {
    self.exporter = exporter; self.admission = admission
  }
  func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    let admitted = admission.beginExport(spans.map(spanIdentity))
    defer { admission.complete(admitted) }
    let actual = spans.filter { admitted.contains(spanIdentity($0)) }
    guard !actual.isEmpty else { return .success }
    return exporter.export(spans: actual, explicitTimeout: explicitTimeout)
  }
  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { exporter.flush(explicitTimeout: explicitTimeout) }
  func shutdown(explicitTimeout: TimeInterval?) {
    let first = closeLock.withLock { if closed { return false }; closed = true; return true }
    if first { exporter.shutdown(explicitTimeout: explicitTimeout) }
  }
}

/// ReadableLogRecord is a value type with no stable SDK object identity. A
/// private ticket travels only through our owned processor and is stripped
/// before every downstream exporter. It is never an entity ID or SQL key.
private let logAdmissionTicket = "io.teaql.internal.admission.ticket"
final class AdmittedLogProcessor: LogRecordProcessor, @unchecked Sendable {
  let admission: QueueAdmission
  private let batch: BatchLogRecordProcessor
  private let exporter: AdmittedLogExporter
  init(exporter: any LogRecordExporter, losses: ExportLosses) {
    admission = QueueAdmission(signal: "logs", losses: losses)
    self.exporter = AdmittedLogExporter(exporter, admission: admission)
    batch = BatchLogRecordProcessor(logRecordExporter: self.exporter,
      scheduleDelay: 0.2, exportTimeout: 3, maxQueueSize: 2048, maxExportBatchSize: 128)
  }
  func onEmit(logRecord: ReadableLogRecord) {
    let ticket = UUID().uuidString
    var tagged = logRecord
    tagged.setAttribute(key: logAdmissionTicket, value: .string(ticket))
    admission.submit(ticket) { batch.onEmit(logRecord: tagged); return true }
  }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    admission.wait(prefix: admission.prefix, timeout: explicitTimeout ?? 6) ? .success : .failure
  }
  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    admission.close()
    var settled = true
    if !admission.wait(prefix: admission.prefix, timeout: min(5, explicitTimeout ?? 5)) {
      admission.retireQueued(); exporter.shutdown(explicitTimeout: 0.5)
      settled = admission.wait(prefix: admission.prefix, timeout: 0.5)
    }
    let result = batch.shutdown(explicitTimeout: 0.5)
    return settled ? result : .failure
  }
}

private final class AdmittedLogExporter: LogRecordExporter, @unchecked Sendable {
  private let exporter: any LogRecordExporter
  private let admission: QueueAdmission
  private let closeLock = NSLock()
  private var closed = false
  init(_ exporter: any LogRecordExporter, admission: QueueAdmission) {
    self.exporter = exporter; self.admission = admission
  }
  func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
    let tickets = logRecords.compactMap { record -> String? in
      if case .string(let ticket) = record.attributes[logAdmissionTicket] { return ticket }
      return nil
    }
    let admitted = admission.beginExport(tickets)
    defer { admission.complete(admitted) }
    let actual = logRecords.compactMap { record -> ReadableLogRecord? in
      guard case .string(let ticket) = record.attributes[logAdmissionTicket], admitted.contains(ticket) else { return nil }
      var clean = record; clean.setAttribute(key: logAdmissionTicket, value: nil); return clean
    }
    guard !actual.isEmpty else { return .success }
    return exporter.export(logRecords: actual, explicitTimeout: explicitTimeout)
  }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { exporter.forceFlush(explicitTimeout: explicitTimeout) }
  func shutdown(explicitTimeout: TimeInterval?) {
    let first = closeLock.withLock { if closed { return false }; closed = true; return true }
    if first { exporter.shutdown(explicitTimeout: explicitTimeout) }
  }
}
