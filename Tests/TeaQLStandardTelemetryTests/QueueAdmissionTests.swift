import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import TeaQLCore
import XCTest
@testable import TeaQLStandardTelemetry

final class QueueAdmissionTests: XCTestCase {
  func testQueuedStagedAndExportingRecordsShareOneVisibleQuota() async throws {
    let held = HeldQueueExporter(), metrics = SDKCapture()
    let telemetry = try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-queue-test",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: held, metricExporter: metrics, logExporter: held)
    // The real SDK worker moves a large staging list out of its queue before
    // calling the first 128-record export. Hold that export, not the producer.
    for _ in 0..<1200 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {} }
    let spansStarted = held.spansEntered.wait(timeout: .now() + 2) == .success
    let logsStarted = held.logsEntered.wait(timeout: .now() + 2) == .success
    for _ in 1200..<5000 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {} }
    let overflow = telemetry.exportLosses
    // Always release before assertions so a red test cannot strand SDK workers.
    held.release()
    await telemetry.flush(); await telemetry.shutdown()
    XCTAssertTrue(spansStarted && logsStarted)
    XCTAssertEqual(overflow["traces"], 5000 - 2048)
    XCTAssertEqual(overflow["logs"], 5000 - 2048)
    XCTAssertEqual(held.spanCount, 2048)
    XCTAssertEqual(held.logCount, 2048)
    XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    XCTAssertEqual(telemetry.exportQueues["traces"]?["peak_outstanding"], 2048)
    XCTAssertEqual(telemetry.exportQueues["logs"]?["peak_outstanding"], 2048)
    XCTAssertFalse(held.leakedTicket)
    XCTAssertEqual(telemetry.exportLossReasons["traces:queue_overflow"], 2952)
    XCTAssertEqual(telemetry.exportLossReasons["logs:queue_overflow"], 2952)
    let late = await telemetry.withOperation(RuntimeOperation(family: "query", name: "after-close")) { 42 }
    XCTAssertEqual(late, 42)
    XCTAssertEqual(held.spanCount, 2048)
    XCTAssertEqual(held.logCount, 2048)
    XCTAssertEqual(telemetry.exportLossReasons["traces:shutdown"], 1)
    XCTAssertEqual(telemetry.exportLossReasons["logs:shutdown"], 1)
  }

  func testFailedSDKExportsReleaseCapacityBeforeRecovery() async throws {
    let held = HeldQueueExporter(), metrics = SDKCapture()
    held.release(); held.failExports = true
    let telemetry = try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-queue-recovery",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: held, metricExporter: metrics, logExporter: held)
    for _ in 0..<32 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "failed")) {} }
    await telemetry.flush()
    XCTAssertEqual(held.spanCount, 32); XCTAssertEqual(held.logCount, 32)
    XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    held.failExports = false
    for _ in 0..<32 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "recovered")) {} }
    await telemetry.flush(); await telemetry.shutdown()
    XCTAssertEqual(held.spanCount, 64); XCTAssertEqual(held.logCount, 64)
    XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    XCTAssertTrue(telemetry.exportLossReasons.isEmpty)
    XCTAssertFalse(held.leakedTicket)
  }

  func testFailedHandoffAndDuplicateCompletionCannotConsumeAnotherPermit() {
    let losses = ExportLosses(), admission = QueueAdmission(signal: "traces", losses: ExportLosses(), capacity: 2)
    let failing = QueueAdmission(signal: "logs", losses: losses, capacity: 1)
    XCTAssertFalse(failing.submit("not-delivered") { false })
    XCTAssertEqual(failing.outstanding, 0)
    XCTAssertEqual(losses.reasons["logs:handoff_failure"], 1)
    XCTAssertTrue(admission.submit("one") { true })
    XCTAssertFalse(admission.submit("one") { true })
    XCTAssertTrue(admission.submit("two") { true })
    XCTAssertFalse(admission.submit("three") { true })
    let first = admission.beginExport(["one"])
    XCTAssertEqual(first, ["one"])
    XCTAssertEqual(admission.outstanding, 2)
    XCTAssertTrue(admission.beginExport(["one"]).isEmpty)
    admission.complete(first); admission.complete(first)
    XCTAssertEqual(admission.outstanding, 1)
    admission.close()
    XCTAssertFalse(admission.submit("three") { XCTFail("closed gate must not hand off"); return true })
    admission.complete(admission.beginExport(["two"]))
    XCTAssertEqual(admission.outstanding, 0)
  }

  func testConcurrentOffersHaveExactQuotaWithoutExporterUnderAdmissionLock() async {
    let losses = ExportLosses(), admission = QueueAdmission(signal: "logs", losses: losses, capacity: 64)
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<1000 {
        group.addTask { admission.submit("\(index)") { true } }
      }
    }
    XCTAssertEqual(admission.outstanding, 64)
    XCTAssertEqual(admission.snapshot["peak_outstanding"], 64)
    XCTAssertEqual(losses.reasons["logs:queue_overflow"], 936)
    admission.close()
  }
  func testFlushPrefixUsesActualIdentityAndOnlySuccessfulHandoffs() {
    let admission = QueueAdmission(signal: "logs", losses: ExportLosses(), capacity: 4)
    XCTAssertFalse(admission.submit("failed") { false })
    XCTAssertEqual(admission.prefix, 0)
    XCTAssertTrue(admission.submit("older") { true })
    let prefix = admission.prefix
    XCTAssertTrue(admission.submit("newer") { true })
    admission.complete(admission.beginExport(["newer"]))
    XCTAssertFalse(admission.wait(prefix: prefix, timeout: 0.005))
    admission.complete(admission.beginExport(["older"]))
    XCTAssertTrue(admission.submit("still-pending-newer") { true })
    XCTAssertTrue(admission.wait(prefix: prefix, timeout: 0))
    XCTAssertEqual(admission.outstanding, 1)
    admission.close()
  }
  func testRetirementExcludesExportingRecordsAndIgnoresRepeatedCompletion() {
    let losses = ExportLosses(), admission = QueueAdmission(signal: "traces", losses: losses, capacity: 4)
    for key in ["exporting", "staged", "queued"] { XCTAssertTrue(admission.submit(key) { true }) }
    let active = admission.beginExport(["exporting"])
    admission.retireQueued(); admission.retireQueued()
    XCTAssertEqual(admission.snapshot["retired"], 2)
    XCTAssertEqual(admission.snapshot["exporting"], 1)
    XCTAssertEqual(losses.reasons["traces:shutdown"], 2)
    XCTAssertTrue(admission.beginExport(["staged", "queued"]).isEmpty)
    admission.complete(active); admission.complete(active)
    XCTAssertEqual(admission.snapshot["completed"], 1)
    XCTAssertEqual(admission.outstanding, 0)
  }
  func testBackloggedShutdownRetiresUnattemptedRecordsAndCancelsOwnedExportOnce() async throws {
    let traceHeld = HeldQueueExporter(), logHeld = HeldQueueExporter(), metrics = SDKCapture()
    let telemetry = try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-queue-backlog",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: traceHeld, metricExporter: metrics, logExporter: logHeld)
    for _ in 0..<3000 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "backlog")) {} }
    let spansStarted = traceHeld.spansEntered.wait(timeout: .now() + 2) == .success
    let logsStarted = logHeld.logsEntered.wait(timeout: .now() + 2) == .success
    let before = ContinuousClock.now
    await telemetry.shutdown()
    let elapsed = before.duration(to: .now)
    traceHeld.release(); logHeld.release()
    XCTAssertTrue(spansStarted && logsStarted)
    XCTAssertLessThan(elapsed, .seconds(6))
    XCTAssertGreaterThanOrEqual(elapsed, .seconds(4.9))
    XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    XCTAssertEqual(traceHeld.spanCount, 128); XCTAssertEqual(logHeld.logCount, 128)
    for signal in ["traces", "logs"] {
      XCTAssertEqual(telemetry.exportQueues[signal]?["retired"], 1920)
      XCTAssertEqual(telemetry.exportLossReasons[signal + ":shutdown"], 1920)
      XCTAssertEqual(telemetry.exportQueues[signal]?["admitted"], 2048)
    }
    XCTAssertEqual(traceHeld.shutdownCount, 1); XCTAssertEqual(logHeld.shutdownCount, 1)
    await telemetry.shutdown()
    XCTAssertEqual(traceHeld.shutdownCount, 1); XCTAssertEqual(logHeld.shutdownCount, 1)
  }
}

private final class HeldQueueExporter: SpanExporter, LogRecordExporter, @unchecked Sendable {
  let spansEntered = DispatchSemaphore(value: 0), logsEntered = DispatchSemaphore(value: 0)
  private let spansRelease = DispatchSemaphore(value: 0), logsRelease = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var spanBatches = 0, logBatches = 0, spans = 0, logs = 0
  private var failed = false, ticket = false, shutdowns = 0
  var failExports: Bool { get { lock.withLock { failed } } set { lock.withLock { failed = newValue } } }
  var leakedTicket: Bool { lock.withLock { ticket } }
  var shutdownCount: Int { lock.withLock { shutdowns } }
  var spanCount: Int { lock.withLock { spans } }
  var logCount: Int { lock.withLock { logs } }
  func release() { spansRelease.signal(); logsRelease.signal() }
  func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    let first = lock.withLock { spanBatches += 1; return spanBatches == 1 }
    if first { spansEntered.signal(); _ = spansRelease.wait(timeout: .now() + 10) }
    let failed = lock.withLock { self.spans += spans.count; return self.failed }
    return failed ? .failure : .success
  }
  func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
    let first = lock.withLock { logBatches += 1; return logBatches == 1 }
    if first { logsEntered.signal(); _ = logsRelease.wait(timeout: .now() + 10) }
    let failed = lock.withLock {
      logs += logRecords.count
      ticket = ticket || logRecords.contains { $0.attributes.keys.contains("io.teaql.internal.admission.ticket") }
      return self.failed
    }
    return failed ? .failure : .success
  }
  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
  func shutdown(explicitTimeout: TimeInterval?) { lock.withLock { shutdowns += 1 }; release() }
}
