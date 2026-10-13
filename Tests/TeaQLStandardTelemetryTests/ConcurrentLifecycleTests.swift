import Foundation
import OpenTelemetrySdk
import TeaQLCore
import XCTest
@testable import TeaQLStandardTelemetry

final class ConcurrentLifecycleTests: XCTestCase {
  private func module(trace: any SpanExporter, metric: any MetricExporter, log: any LogRecordExporter) throws -> StandardTelemetry {
    try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-concurrent-lifecycle",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: trace, metricExporter: metric, logExporter: log)
  }

  func testConcurrentShutdownCallersWaitForTheSameOwnedClosure() async throws {
    let paused = PausedSpans(), capture = SDKCapture(), returned = LifecycleCounter()
    let telemetry = try module(trace: paused, metric: capture, log: capture)
    await telemetry.withOperation(RuntimeOperation(family: "query", name: "one")) {}
    let first = Task { await telemetry.shutdown() }
    let exporting = paused.entered.wait(timeout: .now() + 2) == .success
    let second = Task { await telemetry.shutdown(); returned.increment() }
    try await Task.sleep(for: .milliseconds(50))
    let premature = returned.value
    // Release before assertions, including on the expected red path.
    paused.release.signal(); await first.value; await second.value
    XCTAssertTrue(exporting)
    XCTAssertEqual(premature, 0, "closed admission is not completed resource shutdown")
    XCTAssertEqual(returned.value, 1)
    XCTAssertEqual(paused.shutdowns.value, 1)
    XCTAssertEqual(telemetry.exportResources["lifecycle_workers"], 0)
  }

  func testFlushDuringShutdownJoinsClosureAndDoesNotStartAnotherSDKFlush() async throws {
    let paused = PausedMetrics(), capture = SDKCapture(), returned = LifecycleCounter()
    let telemetry = try module(trace: capture, metric: paused, log: capture)
    await telemetry.withOperation(RuntimeOperation(family: "query", name: "before-flush")) {}
    let flushing = Task { await telemetry.flush() }
    let exporting = paused.entered.wait(timeout: .now() + 2) == .success
    let closing = Task { await telemetry.shutdown() }
    for _ in 0..<200 where !telemetry.isShutdown { try await Task.sleep(for: .milliseconds(1)) }
    let closed = telemetry.isShutdown
    let later = Task { await telemetry.flush(); returned.increment() }
    try await Task.sleep(for: .milliseconds(50))
    let premature = returned.value
    paused.release.signal(); await flushing.value; await closing.value; await later.value
    XCTAssertTrue(exporting && closed)
    XCTAssertEqual(premature, 0, "flush during shutdown must await owned closure")
    XCTAssertEqual(paused.exports.value, 2, "only the accepted flush and final snapshot may export")
    XCTAssertEqual(paused.shutdowns.value, 1)
    XCTAssertEqual(telemetry.exportResources["lifecycle_workers"], 0)
  }

  func testBusinessBodiesCompletingAfterShutdownKeepTheirResultAndOriginalError() async throws {
    for fails in [false, true] {
      let entered = LifecycleLatch(), resume = LifecycleLatch(), capture = SDKCapture()
      let callbacks = LifecycleCounter(), telemetry = try module(trace: capture, metric: capture, log: capture)
      let work = Task {
        try await telemetry.withOperation(RuntimeOperation(family: "query", name: "late-body"),
          completion: { (value: Int) in callbacks.increment(); return ["teaql.result.cardinality": .integer(Int64(value))] }) {
            await entered.open(); await resume.wait()
            if fails { throw LateBusinessFailure() }
            return 42
          }
      }
      await entered.wait(); await telemetry.shutdown()
      let metricNames = capture.metricNames
      let metricRecords = capture.metricRecordCount
      await resume.open()
      do { let result = try await work.value; XCTAssertFalse(fails); XCTAssertEqual(result, 42) }
      catch { XCTAssertTrue(fails); XCTAssertTrue(error is LateBusinessFailure) }
      XCTAssertEqual(callbacks.value, fails ? 0 : 1)
      XCTAssertTrue(capture.spans.isEmpty && capture.logs.isEmpty)
      XCTAssertEqual(capture.metricNames, metricNames)
      XCTAssertEqual(capture.metricRecordCount, metricRecords, "late business completion must not export another snapshot")
      XCTAssertEqual(telemetry.exportLossReasons["traces:shutdown"], 1)
      XCTAssertEqual(telemetry.exportLossReasons["logs:shutdown"], 1)
      XCTAssertEqual(telemetry.exportResources["lifecycle_workers"], 0)
      XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    }
  }

  func testConcurrentAcceptedFlushesSettleBeforeOnceOnlyShutdown() async throws {
    let capture = SDKCapture(), telemetry = try module(trace: capture, metric: capture, log: capture)
    for _ in 0..<50 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "parallel-flush")) {} }
    let started = ContinuousClock.now
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<12 { group.addTask { await telemetry.flush() } }
    }
    let flushed = started.duration(to: .now)
    XCTAssertLessThan(flushed, .seconds(2), "Concurrent flush must not starve native SDK export workers")
    XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    await telemetry.shutdown()
    XCTAssertEqual(capture.spans.count, 50); XCTAssertEqual(capture.logs.count, 50)
    XCTAssertTrue(telemetry.exportLosses.isEmpty)
    XCTAssertEqual(telemetry.exportResources["lifecycle_workers"], 0)
  }
}

private final class LifecycleCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
private actor LifecycleLatch {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() { opened = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
private struct LateBusinessFailure: LocalizedError {
  var errorDescription: String? { "PRIVATE-LATE-BUSINESS-CANARY" }
}
private final class PausedSpans: SpanExporter, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), shutdowns = LifecycleCounter()
  func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    entered.signal(); _ = release.wait(timeout: .now() + 3); return .success
  }
  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func shutdown(explicitTimeout: TimeInterval?) { shutdowns.increment() }
}
private final class PausedMetrics: MetricExporter, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
  let exports = LifecycleCounter(), shutdowns = LifecycleCounter()
  func export(metrics: [MetricData]) -> ExportResult {
    exports.increment()
    if exports.value == 1 { entered.signal(); _ = release.wait(timeout: .now() + 3) }
    return .success
  }
  func flush() -> ExportResult { .success }
  func shutdown() -> ExportResult { shutdowns.increment(); return .success }
  func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .cumulative }
}
