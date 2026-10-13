import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterCommon
import TeaQLCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ExportLosses: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [String: Int64] = [:]
  private var reasonCounts: [String: Int64] = [:]
  private var rejectedCounts: [String: Int64] = [:]
  private var responseCounts: [String: Int64] = [:]
  private var counter: LongCounterSdk?
  private var rejectedCounter: LongCounterSdk?
  private var responseCounter: LongCounterSdk?
  var snapshot: [String: Int64] { lock.withLock { counts } }
  var reasons: [String: Int64] { lock.withLock { reasonCounts } }
  var rejected: [String: Int64] { lock.withLock { rejectedCounts } }
  var responses: [String: Int64] { lock.withLock { responseCounts } }
  func attach(_ counter: LongCounterSdk, rejected: LongCounterSdk, responses: LongCounterSdk) {
    lock.withLock { self.counter = counter; rejectedCounter = rejected; responseCounter = responses }
    for signal in ["traces", "logs", "metrics"] {
      counter.add(value: 0, attributes: ["teaql.telemetry.signal": .string(signal), "teaql.telemetry.reason": .string("export_failure")])
      rejected.add(value: 0, attributes: ["teaql.telemetry.signal": .string(signal)])
      for reason in ["partial_success", "warning", "invalid_response"] {
        responses.add(value: 0, attributes: ["teaql.telemetry.signal": .string(signal), "teaql.telemetry.reason": .string(reason)])
      }
    }
    for signal in ["traces", "logs"] {
      for reason in ["queue_overflow", "shutdown", "handoff_failure"] {
        counter.add(value: 0, attributes: ["teaql.telemetry.signal": .string(signal), "teaql.telemetry.reason": .string(reason)])
      }
    }
  }
  func response(signal: String, reason: String, rejected: Int64 = 0) {
    let first = lock.withLock {
      let key = signal + ":" + reason, first = responseCounts[key] == nil
      responseCounts[key, default: 0] += 1
      responseCounter?.add(value: 1, attributes: ["teaql.telemetry.signal": .string(signal), "teaql.telemetry.reason": .string(reason)])
      if rejected > 0 {
        rejectedCounts[signal, default: 0] += rejected
        rejectedCounter?.add(value: Int(rejected), attributes: ["teaql.telemetry.signal": .string(signal)])
      }
      return first
    }
    if first { RuntimeTelemetryStartup.notice("TeaQL telemetry: \(signal) response=\(reason); business outcome unchanged.") }
  }
  func record(signal: String, count: Int, reason: String = "export_failure") {
    guard count > 0 else { return }
    let first = lock.withLock {
      let key = signal + ":" + reason, first = reasonCounts[key] == nil
      counts[signal, default: 0] += Int64(count)
      reasonCounts[key, default: 0] += Int64(count)
      counter?.add(value: count, attributes: ["teaql.telemetry.signal": .string(signal),
        "teaql.telemetry.reason": .string(reason)])
      return first
    }
    if first { RuntimeTelemetryStartup.notice("TeaQL telemetry: \(signal) loss=\(reason); business outcome unchanged.") }
  }
}

/// Official OTLP encoding with an owned HTTP transport. The native 2.5.1 HTTP
/// exporters retain failed batches and use the customer's global feedback
/// callback. This transport deliberately does neither. SDK batch queues remain
/// the only queues; delivery failures are counted, not retried without a bound.
final class OwnedOTLPExporter: SpanExporter, MetricExporter, LogRecordExporter, @unchecked Sendable {
  private let endpoint: String
  private let transport: BoundedOTLPHTTP
  private let losses: ExportLosses
  private let lifecycleLock = NSLock()
  private var lifecycleDeadline: ContinuousClock.Instant?
  var activeRequests: Int { transport.activeRequests }
  var isClosed: Bool { transport.isClosed }
  func setLifecycleDeadline(_ deadline: ContinuousClock.Instant) {
    lifecycleLock.withLock { lifecycleDeadline = deadline }
  }
  init(endpoint: String, losses: ExportLosses, session: URLSession? = nil) {
    self.endpoint = endpoint; self.losses = losses
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 3
    transport = BoundedOTLPHTTP(configuration: session?.configuration ?? configuration)
  }
  private func send(_ data: Data?, signal: String, count: Int, submitted: Int, timeout: TimeInterval?) -> Bool {
    guard count > 0 else { return true }
    guard let data, let url = URL(string: endpoint + "/v1/" + signal) else {
      losses.record(signal: signal, count: count); return false
    }
    let remaining = lifecycleLock.withLock { () -> Double in
      guard let deadline = lifecycleDeadline else { return 3 }
      let duration = ContinuousClock.now.duration(to: deadline)
      return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    guard remaining > 0 else { losses.record(signal: signal, count: count); return false }
    let deadline = min(3, remaining, max(0.001, timeout ?? 3))
    var request = URLRequest(url: url)
    request.httpMethod = "POST"; request.httpBody = data
    request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = deadline
    switch transport.send(request, timeout: deadline) {
    case .received(let body):
      do {
        let response = try OTLPAcknowledgement.decode(body, signal: signal, submitted: submitted)
        if response.rejected > 0 { losses.response(signal: signal, reason: "partial_success", rejected: response.rejected) }
        else if response.warning { losses.response(signal: signal, reason: "warning") }
        return true
      } catch { losses.response(signal: signal, reason: "invalid_response") }
    case .invalidResponse: losses.response(signal: signal, reason: "invalid_response")
    case .failed: break
    }
    losses.record(signal: signal, count: count); return false
  }
  func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    var request = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest()
    request.resourceSpans = SpanAdapter.toProtoResourceSpans(spanDataList: spans)
    return send(try? request.serializedData(), signal: "traces", count: spans.count, submitted: spans.count, timeout: explicitTimeout) ? .success : .failure
  }
  func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
    var request = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest()
    request.resourceLogs = LogRecordAdapter.toProtoResourceRecordLog(logRecordList: logRecords)
    return send(try? request.serializedData(), signal: "logs", count: logRecords.count, submitted: logRecords.count, timeout: explicitTimeout) ? .success : .failure
  }
  func export(metrics: [MetricData]) -> ExportResult {
    var request = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest()
    request.resourceMetrics = MetricsAdapter.toProtoResourceMetrics(metricData: metrics)
    let points = request.resourceMetrics.flatMap(\.scopeMetrics).flatMap(\.metrics).reduce(0) { count, metric in
      switch metric.data {
      case .gauge(let value): count + value.dataPoints.count
      case .sum(let value): count + value.dataPoints.count
      case .histogram(let value): count + value.dataPoints.count
      case .exponentialHistogram(let value): count + value.dataPoints.count
      case .summary(let value): count + value.dataPoints.count
      case nil: count
      }
    }
    return send(try? request.serializedData(), signal: "metrics", count: metrics.count, submitted: points, timeout: nil) ? .success : .failure
  }
  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
  func flush() -> ExportResult { .success }
  func shutdown() -> ExportResult { transport.shutdown(); return .success }
  func shutdown(explicitTimeout: TimeInterval?) { transport.shutdown() }
  func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .cumulative }
}
