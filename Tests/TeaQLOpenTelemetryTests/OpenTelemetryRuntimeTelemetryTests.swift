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
    let telemetry = OpenTelemetryRuntimeTelemetry(tracer: tracer, meter: meter)

    _ = await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {
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
    XCTAssertTrue(metricExporter.names.contains("teaql.runtime.operation.duration"))
    XCTAssertTrue(metricExporter.names.contains("teaql.runtime.operation.count"))
  }
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
