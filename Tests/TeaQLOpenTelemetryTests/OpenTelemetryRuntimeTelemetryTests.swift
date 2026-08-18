import XCTest
import InMemoryExporter
import OpenTelemetryApi
import OpenTelemetrySdk
import TeaQLCore
@testable import TeaQLOpenTelemetry

final class OpenTelemetryRuntimeTelemetryTests: XCTestCase {
  func testOfficialSdkExportsNestedRuntimeSpans() async throws {
    let exporter = InMemoryExporter()
    let provider = TracerProviderSdk(
      spanProcessors: [SimpleSpanProcessor(spanExporter: exporter)])
    let tracer = provider.get(instrumentationName: "io.teaql.runtime")
    let metricExporter = CapturingMetricExporter()
    let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
      .setInterval(timeInterval: 60).build()
    let meterProvider = MeterProviderSdk.builder()
      .registerMetricReader(reader: metricReader)
      .registerView(selector: InstrumentSelectorBuilder().build(), view: View.builder().build())
      .build()
    let meter = meterProvider.get(name: "io.teaql.runtime")
    let logExporter = CapturingLogExporter()
    let loggerProvider = LoggerProviderBuilder()
      .with(processors: [SimpleLogRecordProcessor(logRecordExporter: logExporter)])
      .build()
    let telemetry = OpenTelemetryRuntimeTelemetry(
      tracer: tracer, meter: meter,
      logger: loggerProvider.get(instrumentationScopeName: "io.teaql.runtime"))

    _ = await telemetry.withOperation(RuntimeOperation(
      family: "query", name: "School.list",
      attributes: ["teaql.entity.id": .integer(42)]
    ), completion: { _ in ["teaql.result.cardinality": .integer(1)] }) {
      await telemetry.withOperation(
        RuntimeOperation(family: "provider", name: "sqlite.query")
      ) { 1 }
    }
    provider.forceFlush()
    XCTAssertEqual(meterProvider.forceFlush(), .success)

    let spans = exporter.getFinishedSpanItems()
    XCTAssertEqual(spans.count, 2)
    let query = try XCTUnwrap(spans.first { $0.name == "teaql.query" })
    let providerSpan = try XCTUnwrap(spans.first { $0.name == "teaql.provider" })
    XCTAssertEqual(providerSpan.parentSpanId, query.spanId)
    XCTAssertEqual(
      query.attributes["teaql.result.cardinality"], AttributeValue.int(1))
    XCTAssertTrue(metricExporter.names.contains("teaql.runtime.operation.duration"))
    XCTAssertTrue(metricExporter.names.contains("teaql.runtime.operation.count"))
    let logs = logExporter.records
    XCTAssertEqual(logs.count, 2)
    let queryLog = try XCTUnwrap(logs.first {
      $0.attributes["teaql.operation.family"] == AttributeValue.string("query")
    })
    XCTAssertEqual(queryLog.body, AttributeValue.string("TeaQL runtime operation completed"))
    XCTAssertEqual(
      queryLog.attributes["teaql.operation.name"], AttributeValue.string("School.list"))
    XCTAssertNil(queryLog.attributes["teaql.entity.id"])
    XCTAssertEqual(queryLog.spanContext?.traceId, query.traceId)
    XCTAssertEqual(queryLog.spanContext?.spanId, query.spanId)
  }


  func testInjectsActiveW3cTraceContext() async throws {
    let exporter = InMemoryExporter()
    let provider = TracerProviderSdk(
      spanProcessors: [SimpleSpanProcessor(spanExporter: exporter)])
    let telemetry = OpenTelemetryRuntimeTelemetry(
      tracer: provider.get(instrumentationName: "io.teaql.runtime"),
      meter: MeterProviderSdk.builder().build().get(name: "io.teaql.runtime"))
    var carrier: [String: String] = [:]

    await telemetry.withOperation(RuntimeOperation(
      family: "tfp", name: "client.query",
      attributes: ["teaql.tfp.role": .string("client")]
    )) {
      telemetry.inject(&carrier)
    }

    provider.forceFlush()
    let span = try XCTUnwrap(exporter.getFinishedSpanItems().first)
    XCTAssertEqual(
      carrier["traceparent"], "00-\(span.traceId.hexString)-\(span.spanId.hexString)-01")
  }
}

private final class CapturingLogExporter: LogRecordExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var exported: [ReadableLogRecord] = []
  var records: [ReadableLogRecord] { lock.withLock { exported } }

  func export(
    logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?
  ) -> ExportResult {
    lock.withLock { exported.append(contentsOf: logRecords) }
    return .success
  }
  func shutdown(explicitTimeout: TimeInterval?) {}
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
}

private final class CapturingMetricExporter: MetricExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var exported: [MetricData] = []
  var names: Set<String> { lock.withLock { Set(exported.map(\.name)) } }

  func export(metrics: [MetricData]) -> ExportResult {
    lock.withLock { exported.append(contentsOf: metrics) }
    return .success
  }
  func flush() -> ExportResult { .success }
  func shutdown() -> ExportResult { .success }
  func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality {
    .cumulative
  }
}
