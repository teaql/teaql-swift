import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk
import TeaQLCore
import XCTest
@testable import TeaQLOpenTelemetry

final class OpenTelemetryOtlpSmokeTests: XCTestCase {
  func testExportsQueryTraceMetricAndLogThroughOtlpHttp() async throws {
    guard let serviceName = ProcessInfo.processInfo.environment["TEAQL_OTLP_SERVICE_NAME"] else {
      throw XCTSkip("TEAQL_OTLP_SERVICE_NAME is not set")
    }
    let base = ProcessInfo.processInfo.environment["OTEL_EXPORTER_OTLP_ENDPOINT"]
      ?? "http://localhost:4318"
    let runID = String(serviceName.split(separator: "-").last!)
    let resource = Resource(attributes: [
      "service.name": .string(serviceName),
      "service.instance.id": .string(runID),
      "teaql.runtime.language": .string("swift"),
      "teaql.conformance.run_id": .string(runID),
    ])

    let traceExporter = OtlpHttpTraceExporter(endpoint: URL(string: "\(base)/v1/traces")!)
    let tracerProvider = TracerProviderBuilder()
      .with(resource: resource)
      .add(spanProcessor: SimpleSpanProcessor(spanExporter: traceExporter))
      .build()
    let metricExporter = OtlpHttpMetricExporter(endpoint: URL(string: "\(base)/v1/metrics")!)
    let meterProvider = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: PeriodicMetricReaderBuilder(exporter: metricExporter)
        .setInterval(timeInterval: 60).build())
      .registerView(selector: InstrumentSelectorBuilder().build(), view: View.builder().build())
      .build()
    let logExporter = OtlpHttpLogExporter(endpoint: URL(string: "\(base)/v1/logs")!)
    let loggerProvider = LoggerProviderBuilder()
      .with(resource: resource)
      .with(processors: [SimpleLogRecordProcessor(logRecordExporter: logExporter)])
      .build()
    let telemetry = OpenTelemetryRuntimeTelemetry(
      tracer: tracerProvider.get(instrumentationName: "io.teaql.runtime"),
      meter: meterProvider.get(name: "io.teaql.runtime"),
      logger: loggerProvider.get(instrumentationScopeName: "io.teaql.runtime"))

    _ = await telemetry.withOperation(RuntimeOperation(
      family: "query", name: "ConformanceProbe.list",
      attributes: [
        "teaql.entity.type": .string("ConformanceProbe"),
        "teaql.entity.id": .string("must-not-export"),
        "teaql.result.cardinality": .integer(1),
      ]
    )) { 1 }

    tracerProvider.forceFlush()
    XCTAssertEqual(meterProvider.forceFlush(), .success)
  }
}
