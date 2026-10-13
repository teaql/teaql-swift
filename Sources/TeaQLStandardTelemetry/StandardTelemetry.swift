import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import TeaQLCore

public enum StandardTelemetryModule {
  /// Application assembly registration; creates no SDK/export resources.
  public static func install() {
    RuntimeTelemetryStartup.register { try StandardTelemetry(configuration: $0) }
  }
}

private final class ParentContext: @unchecked Sendable {
  let context: SpanContext
  init(_ context: SpanContext) { self.context = context }
}
private enum OwnedContext { @TaskLocal static var parent: ParentContext? }

// DispatchWorkItem.cancel is thread safe; this immutable owner narrows the
// SDK's missing Sendable annotation without disabling Swift concurrency checks.
private final class OwnedCancellation: @unchecked Sendable {
  let item: DispatchWorkItem
  init(_ body: @escaping @Sendable () -> Void) { item = DispatchWorkItem(block: body) }
  func cancel() { item.cancel() }
}

private final class LifecycleReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
  @discardableResult func finish() -> Bool {
    let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
    pending?.resume(); return pending != nil
  }
}

public final class StandardTelemetry: RuntimeTelemetry, StandardTelemetryLifecycle, SQLTelemetryObserver, @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var lifecycleWorkers = 0
  private var shutdownGroup: DispatchGroup?
  private var shutdownDeadline: DispatchTime?
  private let acceptedFlushes = DispatchGroup()
  private let ownedExporters: [OwnedOTLPExporter]
  private let ownedMetricExporter: OwnedOTLPExporter?
  private let owner = UUID()
  public var isShutdown: Bool { lock.withLock { closed } }
  private let traces: TracerProviderSdk
  private let metrics: MeterProviderSdk
  private let logs: LoggerProviderSdk
  private let spanProcessor: AdmittedSpanProcessor
  private let logProcessor: AdmittedLogProcessor
  private let tracer: any Tracer
  private let logger: any Logger
  private let duration: DoubleHistogramMeterSdk
  private let operations: LongCounterSdk
  private let losses: ExportLosses
  public var exportLosses: [String: Int64] { losses.snapshot }
  public var exportLossReasons: [String: Int64] { losses.reasons }
  public var rejectedRecords: [String: Int64] { losses.rejected }
  public var exportResponses: [String: Int64] { losses.responses }
  public var exportResources: [String: Int] {
    ["active_http_requests": ownedExporters.reduce(0) { $0 + $1.activeRequests },
      "owned_http_transports": ownedExporters.count,
      "closed_http_transports": ownedExporters.filter { $0.isClosed }.count,
      "lifecycle_workers": lock.withLock { lifecycleWorkers }]
  }
  public var exportQueues: [String: [String: Int]] {
    ["traces": spanProcessor.admission.snapshot, "logs": logProcessor.admission.snapshot]
  }
  var queueOutstanding: [String: Int] {
    ["traces": spanProcessor.admission.outstanding, "logs": logProcessor.admission.outstanding]
  }

  public convenience init(configuration: TelemetryStartupConfiguration) throws {
    try Self.validate(configuration)
    let losses = ExportLosses()
    try self.init(configuration: configuration,
      traceExporter: OwnedOTLPExporter(endpoint: configuration.endpoint, losses: losses),
      metricExporter: OwnedOTLPExporter(endpoint: configuration.endpoint, losses: losses),
      logExporter: OwnedOTLPExporter(endpoint: configuration.endpoint, losses: losses), losses: losses)
  }

  private static func validate(_ configuration: TelemetryStartupConfiguration) throws {
    guard configuration.enabled,
      TelemetryStartupConfiguration.read([
        TelemetryStartupConfiguration.enabledVariable: "true",
        TelemetryStartupConfiguration.serviceVariable: configuration.serviceName,
        TelemetryStartupConfiguration.endpointVariable: configuration.endpoint,
      ]) == configuration else { throw ConfigurationError.invalid }
  }

  // Internal exporter seam validates the production ownership and processing
  // path without making deterministic tests depend on a live collector.
  init(configuration: TelemetryStartupConfiguration,
    traceExporter: any SpanExporter, metricExporter: any MetricExporter,
    logExporter: any LogRecordExporter, losses: ExportLosses = ExportLosses()) throws {
    try Self.validate(configuration)
    self.losses = losses
    ownedMetricExporter = metricExporter as? OwnedOTLPExporter
    ownedExporters = [traceExporter as? OwnedOTLPExporter, metricExporter as? OwnedOTLPExporter,
      logExporter as? OwnedOTLPExporter].compactMap { $0 }
    let resource = Resource(attributes: [
      "service.name": .string(configuration.serviceName), "teaql.runtime.language": .string("swift")])
    spanProcessor = AdmittedSpanProcessor(exporter: traceExporter, losses: losses)
    traces = TracerProviderBuilder().with(resource: resource).with(sampler: Samplers.alwaysOn)
      .add(spanProcessor: spanProcessor).build()
    metrics = MeterProviderSdk.builder().setResource(resource: resource)
      .registerMetricReader(reader: PeriodicMetricReaderBuilder(exporter: metricExporter).setInterval(timeInterval: 10).build())
      .registerView(selector: InstrumentSelectorBuilder().build(), view: View.builder().build()).build()
    logProcessor = AdmittedLogProcessor(exporter: logExporter, losses: losses)
    logs = LoggerProviderBuilder().with(resource: resource).with(processors: [logProcessor]).build()
    tracer = traces.get(instrumentationName: "io.teaql.runtime")
    logger = logs.get(instrumentationScopeName: "io.teaql.runtime")
    let meter = metrics.get(name: "io.teaql.runtime")
    duration = meter.histogramBuilder(name: "teaql.runtime.operation.duration").build()
    operations = meter.counterBuilder(name: "teaql.runtime.operation.count").build()
    losses.attach(meter.counterBuilder(name: "teaql.telemetry.export.lost").build(),
      rejected: meter.counterBuilder(name: "teaql.telemetry.export.rejected").build(),
      responses: meter.counterBuilder(name: "teaql.telemetry.export.response").build())
  }
  private enum ConfigurationError: Error { case invalid }

  private func begin(_ operation: RuntimeOperation) -> any Span {
    let builder = tracer.spanBuilder(spanName: "teaql.\(operation.family)")
    if let parent = OwnedContext.parent?.context ?? OpenTelemetry.instance.contextProvider.activeSpan?.context {
      builder.setParent(parent)
    } else { builder.setNoParent() }
    for (key, value) in operation.attributes { builder.setAttribute(key: key, value: attribute(value)) }
    return builder.startSpan()
  }

  public func withOperation<Result: Sendable>(_ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result) async rethrows -> Result {
    if isShutdown { recordLateOperation(); return try await body() }
    let span = begin(operation), started = ContinuousClock.now
    defer { span.end() }
    return try await SQLTelemetryObservationContext.$observer.withValue(self) {
      try await OwnedContext.$parent.withValue(ParentContext(span.context)) {
      do {
        let result = try await body()
        finish(operation, span: span, started: started, outcome: "success", completion: completion(result))
        return result
      } catch {
        failed(operation, span: span, started: started, error: error)
        throw error
      }
      }
    }
  }
  public func withSynchronousOperation<Result>(_ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue], _ body: () throws -> Result) rethrows -> Result {
    if isShutdown { recordLateOperation(); return try body() }
    let span = begin(operation), started = ContinuousClock.now
    defer { span.end() }
    return try SQLTelemetryObservationContext.$observer.withValue(self) {
      try OwnedContext.$parent.withValue(ParentContext(span.context)) {
      do {
        let result = try body()
        finish(operation, span: span, started: started, outcome: "success", completion: completion(result))
        return result
      } catch {
        failed(operation, span: span, started: started, error: error)
        throw error
      }
      }
    }
  }
  private func failed(_ operation: RuntimeOperation, span: any Span, started: ContinuousClock.Instant, error: any Error) {
    let type = String(reflecting: Swift.type(of: error)), category = runtimeErrorCategory(type)
    span.setAttribute(key: "teaql.error.type", value: type)
    span.setAttribute(key: "teaql.error.category", value: category)
    finish(operation, span: span, started: started, outcome: "failure", completion: [:], category: category)
  }
  private func finish(_ operation: RuntimeOperation, span: any Span, started: ContinuousClock.Instant,
    outcome: String, completion: [String: RuntimeTelemetryValue], category: String? = nil) {
    span.status = outcome == "success" ? .ok : .error(description: "TeaQL operation failed")
    for (key, value) in completion where key == "teaql.result.cardinality" || key == "teaql.cache.result" {
      span.setAttribute(key: key, value: attribute(value))
    }
    let elapsed = started.duration(to: .now)
    let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    var values: [String: AttributeValue] = ["teaql.operation.family": .string(operation.family), "teaql.operation.outcome": .string(outcome)]
    lock.withLock {
      duration.record(value: milliseconds, attributes: values)
      operations.add(value: 1, attributes: values)
    }
    values["teaql.operation.name"] = .string(operation.name)
    values["teaql.operation.duration_ms"] = .double(milliseconds)
    if let category { values["teaql.error.category"] = .string(category) }
    logger.logRecordBuilder().setSpanContext(span.context).setSeverity(.info)
      .setBody(.string("TeaQL runtime operation completed")).setAttributes(values).emit()
  }
  public func inject(_ carrier: inout [String: String]) {
    guard let parent = OwnedContext.parent?.context else { return }
    W3CTraceContextPropagator().inject(spanContext: parent, carrier: &carrier, setter: CarrierSetter())
  }
  package func beginSQL(operation: String, entity: String) -> (any SQLTelemetryObservation)? {
    guard !isShutdown else { return nil }
    let operation = RuntimeOperation(family: "provider", name: "sqlite.\(operation)",
      attributes: ["teaql.provider.kind": .string("sqlite"),
        "teaql.provider.execution": .string("statement"), "teaql.entity.type": .string(entity)])
    let span = begin(operation)
    return ExecutionObservation(owner: owner, span: span) { [self] span, started, success in
      finish(operation, span: span, started: started,
        outcome: success ? "success" : "failure", completion: [:])
    }
  }

  public func recordSQL(_ metadata: SQLExecutionMetadata) {
    guard !isShutdown, metadata.isSafeProjection else { return }
    guard let identity = metadata.telemetryCorrelation, identity.owner == owner else {
      RuntimeTelemetryStartup.notice("TeaQL telemetry: SQL execution correlation unavailable; no span identity invented.")
      return
    }
    let traceID = TraceId(fromHexString: identity.traceID), spanID = SpanId(fromHexString: identity.spanID)
    guard traceID.isValid, spanID.isValid else { return }
    let context = SpanContext.create(traceId: traceID, spanId: spanID,
      traceFlags: TraceFlags(fromByte: 1), traceState: TraceState())
    var values: [String: AttributeValue] = [
      "teaql.sql.debug": .string(metadata.debugSQL),
      "teaql.sql.log_mode": .string("masked"),
      "teaql.sql.operation": .string(metadata.operation.rawValue),
      "teaql.sql.elapsed_us": .int(Int(clamping: metadata.elapsedMicros)),
      "teaql.sql.outcome": .string(metadata.executionOutcome ?? "unknown"),
      "teaql.intent.comment": .string(metadata.comment ?? metadata.auditReason ?? ""),
      "teaql.intent.purpose": .string(metadata.purpose ?? ""),
      "teaql.intent.audit_reason": .string(metadata.auditReason ?? ""),
      "teaql.trace_chain": .string(traceJSON(metadata.traceChain)),
      "teaql.trace_path": .string(traceJSON(metadata.tracePath)),
      "teaql.mutation_lineage": .string(traceJSON(metadata.mutationLineage)),
    ]
    if let count = metadata.resultCount { values["teaql.sql.result_count"] = .int(count) }
    if let count = metadata.affectedRows { values["teaql.sql.affected_rows"] = .int(count) }
    logger.logRecordBuilder().setSpanContext(context).setSeverity(.info)
      .setBody(.string("TeaQL SQL execution")).setAttributes(values).emit()
  }
  public func flush() async { await lifecycle(close: false) }
  public func shutdown() async { await lifecycle(close: true) }
  private func recordLateOperation() {
    spanProcessor.admission.recordLateOffer(); logProcessor.admission.recordLateOffer()
  }
  private func lifecycle(close: Bool) async {
    let launch = lock.withLock { () -> (group: DispatchGroup, owner: Bool, deadline: DispatchTime) in
      if let shutdownGroup, let shutdownDeadline { return (shutdownGroup, false, shutdownDeadline) }
      let group = DispatchGroup(), deadline = DispatchTime.now() + 6
      for _ in 0..<3 { group.enter() }
      lifecycleWorkers += 3
      if close { closed = true; shutdownGroup = group; shutdownDeadline = deadline }
      else { acceptedFlushes.enter() }
      return (group, true, deadline)
    }
    guard launch.owner else { await awaitLifecycle(launch.group, deadline: launch.deadline); return }
    let group = launch.group
    if !close { group.notify(queue: .global()) { [self] in acceptedFlushes.leave() } }
    if close { spanProcessor.admission.close(); logProcessor.admission.close() }
    let spanPrefix = spanProcessor.admission.prefix, logPrefix = logProcessor.admission.prefix
    // Blocking SDK hooks run outside the caller's executor. A fixed deadline
    // cannot cancel a broken exporter, but it bounds business shutdown waiting.
    let drain = DispatchGroup()
    let drainDeadline = DispatchTime.now() + 5.6
    if close { drain.enter(); drain.enter() }
    let cancelMetric = OwnedCancellation { [ownedMetricExporter] in
      ownedMetricExporter?.shutdown(explicitTimeout: 0)
    }
    if close {
      // The final cumulative snapshot must include losses caused by draining
      // and retirement. Give metrics only the remaining caller budget and
      // cancel an already-running owned HTTP request at that same deadline.
      ownedMetricExporter?.setLifecycleDeadline(.now.advanced(by: .seconds(5.8)))
      DispatchQueue.global().asyncAfter(deadline: .now() + 5.8, execute: cancelMetric.item)
    }
    for signal in 0..<3 {
      if !close && signal != 1 {
        let admission = signal == 0 ? spanProcessor.admission : logProcessor.admission
        let prefix = signal == 0 ? spanPrefix : logPrefix
        admission.observe(prefix: prefix, timeout: 5.8) { [self] settled in
          if !settled { RuntimeTelemetryStartup.notice("TeaQL telemetry: flush prefix incomplete; business outcome unchanged.") }
          lock.withLock { lifecycleWorkers -= 1 }; group.leave()
        }
        continue
      }
      DispatchQueue.global().async { [self] in
        defer { lock.withLock { lifecycleWorkers -= 1 }; group.leave() }
        switch signal {
        case 0:
          defer { if close { drain.leave() } }
          if close { traces.shutdown() }
          else if !spanProcessor.admission.wait(prefix: spanPrefix, timeout: 5.8) {
            RuntimeTelemetryStartup.notice("TeaQL telemetry: traces flush prefix incomplete; business outcome unchanged.")
          }
        case 1:
          if close {
            if drain.wait(timeout: drainDeadline) == .timedOut
              || acceptedFlushes.wait(timeout: drainDeadline) == .timedOut {
              RuntimeTelemetryStartup.notice("TeaQL telemetry: drain before final metrics incomplete; business outcome unchanged.")
            }
            _ = metrics.forceFlush()
            _ = metrics.shutdown()
          } else if !isShutdown { _ = metrics.forceFlush() }
        default:
          defer { if close { drain.leave() } }
          if close { _ = logProcessor.shutdown() }
          else if !logProcessor.admission.wait(prefix: logPrefix, timeout: 5.8) {
            RuntimeTelemetryStartup.notice("TeaQL telemetry: logs flush prefix incomplete; business outcome unchanged.")
          }
        }
      }
    }
    await awaitLifecycle(group, deadline: launch.deadline)
    cancelMetric.cancel()
    if !close, let closing = lock.withLock({ () -> (DispatchGroup, DispatchTime)? in
      guard let shutdownGroup, let shutdownDeadline else { return nil }
      return (shutdownGroup, shutdownDeadline)
    }) {
      await awaitLifecycle(closing.0, deadline: closing.1)
    }
  }
  private func awaitLifecycle(_ group: DispatchGroup, deadline: DispatchTime) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let reply = LifecycleReply(continuation)
      group.notify(queue: .global()) { reply.finish() }
      DispatchQueue.global().asyncAfter(deadline: deadline) { [weak reply] in
        if reply?.finish() == true {
          RuntimeTelemetryStartup.notice("TeaQL telemetry: owned lifecycle timed out; business outcome unchanged.")
        }
      }
    }
  }
}

private final class ExecutionObservation: SQLTelemetryObservation, @unchecked Sendable {
  private let lock = NSLock()
  private var ended = false
  private let span: any Span
  private let started = ContinuousClock.now
  private let complete: @Sendable (any Span, ContinuousClock.Instant, Bool) -> Void
  let correlation: SQLTelemetryCorrelation
  init(owner: UUID, span: any Span,
    complete: @escaping @Sendable (any Span, ContinuousClock.Instant, Bool) -> Void) {
    self.span = span; self.complete = complete
    correlation = SQLTelemetryCorrelation(owner: owner,
      traceID: span.context.traceId.hexString, spanID: span.context.spanId.hexString)
  }
  func finish(success: Bool) {
    let first = lock.withLock { if ended { return false }; ended = true; return true }
    guard first else { return }
    complete(span, started, success)
    span.end()
  }
}

private func traceJSON(_ nodes: [TraceNode]) -> String {
  // Only explanatory structure crosses telemetry; object IDs remain local.
  let fields = nodes.map { ["entity": $0.entity, "comment": $0.comment,
    "purpose": $0.purpose, "kind": $0.kind, "name": $0.name, "level": String($0.level),
    "detail": $0.comment.isEmpty ? $0.name : $0.comment] }
  guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
    let text = String(data: data, encoding: .utf8) else { return "[]" }
  return text
}

private struct CarrierSetter: Setter {
  func set(carrier: inout [String: String], key: String, value: String) { carrier[key] = value }
}

private func attribute(_ value: RuntimeTelemetryValue) -> AttributeValue {
  switch value {
  case .string(let v): return .string(v)
  case .integer(let v): return .int(Int(v))
  case .double(let v): return .double(v)
  case .boolean(let v): return .bool(v)
  }
}
