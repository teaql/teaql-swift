import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import TeaQLCore
import XCTest
@testable import TeaQLStandardTelemetry

final class OwnedSDKTests: XCTestCase {
  private func telemetry(_ capture: SDKCapture) throws -> StandardTelemetry {
    try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-sdk-test",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: capture, metricExporter: capture, logExporter: capture)
  }

  func testAllRequestsRecordedWithThreeSignalsAndGlobalSDKUntouched() async throws {
    let global = OpenTelemetry.instance.tracerProvider as AnyObject
    let capture = SDKCapture(), telemetry = try telemetry(capture)
    XCTAssertTrue((OpenTelemetry.instance.tracerProvider as AnyObject) === global)
    for _ in 0..<100 {
      let result = await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list"),
        completion: { _ in ["teaql.result.cardinality": .integer(1)] }) { 42 }
      XCTAssertEqual(result, 42)
    }
    await telemetry.flush()
    let spans = capture.spans
    XCTAssertEqual(spans.count, 100)
    XCTAssertTrue(spans.allSatisfy { $0.traceFlags.sampled })
    XCTAssertTrue(spans.allSatisfy { $0.resource.attributes["service.name"] == .string("swift-sdk-test") })
    XCTAssertEqual(capture.logs.count, 100)
    let spanIDs = Set(spans.map(\.spanId))
    XCTAssertTrue(capture.logs.allSatisfy { $0.spanContext.map { spanIDs.contains($0.spanId) } == true })
    XCTAssertTrue(capture.metricNames.contains("teaql.runtime.operation.duration"))
    XCTAssertTrue(capture.metricNames.contains("teaql.runtime.operation.count"))
    await telemetry.shutdown()
    XCTAssertTrue(telemetry.isShutdown)
    XCTAssertTrue((OpenTelemetry.instance.tracerProvider as AnyObject) === global)
    let before = capture.spans.count
    let result = await telemetry.withOperation(RuntimeOperation(family: "query", name: "after-close")) { 7 }
    XCTAssertEqual(result, 7)
    XCTAssertEqual(capture.spans.count, before)
  }

  func testConcurrentNestedOperationsKeepTheirActualParentsAndRestoreContext() async throws {
    let capture = SDKCapture(), telemetry = try telemetry(capture)
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<20 {
        group.addTask {
          await telemetry.withOperation(RuntimeOperation(family: "query", name: "query-\(index)")) {
            await Task.yield()
            await telemetry.withOperation(RuntimeOperation(family: "provider", name: "provider-\(index)")) {
              await Task.yield()
            }
          }
        }
      }
    }
    var carrier: [String: String] = [:]
    telemetry.inject(&carrier)
    XCTAssertNil(carrier["traceparent"])
    await telemetry.flush()
    XCTAssertEqual(capture.spans.count, 40)
    for index in 0..<20 {
      let query = try XCTUnwrap(capture.spans.first { $0.attributes["teaql.operation.name"] == .string("query-\(index)") })
      let child = try XCTUnwrap(capture.spans.first { $0.attributes["teaql.operation.name"] == .string("provider-\(index)") })
      XCTAssertEqual(child.parentSpanId, query.spanId)
      XCTAssertEqual(child.traceId, query.traceId)
    }
    await telemetry.shutdown()
  }

  func testFailuresPreserveBusinessErrorButNeverExportItsMessage() async throws {
    let capture = SDKCapture(), telemetry = try telemetry(capture)
    do {
      _ = try await telemetry.withOperation(RuntimeOperation(family: "provider", name: "sqlite.query")) { () async throws -> Int in
        throw DriverError()
      }
      XCTFail("business failure must propagate")
    } catch { XCTAssertTrue(error is DriverError) }
    await telemetry.flush()
    let span = try XCTUnwrap(capture.spans.first)
    XCTAssertEqual(span.attributes["teaql.operation.name"], .string("sqlite.query"))
    let log = try XCTUnwrap(capture.logs.first)
    XCTAssertEqual(log.attributes["teaql.operation.outcome"], .string("failure"))
    let exported = "\(span.attributes) \(span.events) \(span.status) \(log.attributes) \(String(describing: log.body))"
    XCTAssertFalse(exported.contains("SECRET-CANARY"))
    await telemetry.shutdown()
  }
}

private struct DriverError: LocalizedError {
  var errorDescription: String? { "password=SECRET-CANARY" }
}

final class SDKCapture: SpanExporter, LogRecordExporter, MetricExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var savedSpans: [SpanData] = []
  private var savedLogs: [ReadableLogRecord] = []
  private var savedMetrics: [MetricData] = []
  var spans: [SpanData] { lock.withLock { savedSpans } }
  var logs: [ReadableLogRecord] { lock.withLock { savedLogs } }
  var metricNames: Set<String> { lock.withLock { Set(savedMetrics.map(\.name)) } }
  var metricRecordCount: Int { lock.withLock { savedMetrics.count } }
  func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    lock.withLock { savedSpans.append(contentsOf: spans) }; return .success
  }
  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func shutdown(explicitTimeout: TimeInterval?) {}
  func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock { savedLogs.append(contentsOf: logRecords) }; return .success
  }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
  func export(metrics: [MetricData]) -> ExportResult {
    lock.withLock { savedMetrics.append(contentsOf: metrics) }; return .success
  }
  func flush() -> ExportResult { .success }
  func shutdown() -> ExportResult { .success }
  func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .cumulative }
}
