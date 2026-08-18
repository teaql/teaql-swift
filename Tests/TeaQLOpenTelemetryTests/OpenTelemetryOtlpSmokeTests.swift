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
    let expectExportFailure = ProcessInfo.processInfo.environment["TEAQL_EXPECT_EXPORT_FAILURE"] == "1"
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
      .add(spanProcessor: BatchSpanProcessor(
        spanExporter: traceExporter, exportTimeout: 2,
        maxQueueSize: 64, maxExportBatchSize: 16))
      .build()
    let metricExporter = OtlpHttpMetricExporter(endpoint: URL(string: "\(base)/v1/metrics")!)
    let meterProvider = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: PeriodicMetricReaderBuilder(exporter: metricExporter)
        .setInterval(timeInterval: 60).build())
      .registerView(selector: InstrumentSelectorBuilder().build(), view: View.builder().build())
      .build()
    let logExporter = OtlpHttpLogExporter(endpoint: URL(string: "\(base)/v1/logs")!)
    let logProcessor = BatchLogRecordProcessor(
      logRecordExporter: logExporter, exportTimeout: 2,
      maxQueueSize: 64, maxExportBatchSize: 16)
    let loggerProvider = LoggerProviderBuilder()
      .with(resource: resource).with(processors: [logProcessor])
      .build()
    let telemetry = OpenTelemetryRuntimeTelemetry(
      tracer: tracerProvider.get(instrumentationName: "io.teaql.runtime"),
      meter: meterProvider.get(name: "io.teaql.runtime"),
      logger: loggerProvider.get(instrumentationScopeName: "io.teaql.runtime"))

    let operations: [(String, String, [String: RuntimeTelemetryValue])] = [
      ("query", "ConformanceProbe.list", ["teaql.entity.type": .string("ConformanceProbe")]),
      ("mutation", "ConformanceProbe.update", [
        "teaql.entity.type": .string("ConformanceProbe"),
        "teaql.mutation.kind": .string("update"),
      ]),
      ("relation_load", "ConformanceProbe.children", [
        "teaql.entity.type": .string("ConformanceProbe"),
        "teaql.relation.name": .string("children"),
      ]),
      ("provider", "sqlite.query", [
        "teaql.provider.kind": .string("sqlite"),
        "teaql.provider.operation": .string("query"),
      ]),
      ("cache", "local.get", ["teaql.cache.operation": .string("get")]),
      ("tfp", "client.query", ["teaql.tfp.role": .string("client")]),
      ("audit", "ConformanceProbe.audit", [
        "teaql.entity.type": .string("ConformanceProbe"),
        "teaql.mutation.kind": .string("update"),
        "teaql.audit.changed_field_count": .integer(1),
      ]),
    ]
    var completedOperations = 0
    for (family, name, baseAttributes) in operations {
      var attributes = baseAttributes
      attributes["teaql.entity.id"] = .string("must-not-export")
      _ = await telemetry.withOperation(RuntimeOperation(
        family: family, name: name, attributes: attributes
      ), completion: { _ in
        var completion: [String: RuntimeTelemetryValue] = [
          "teaql.result.cardinality": .integer(1)
        ]
        if family == "cache" { completion["teaql.cache.result"] = .string("hit") }
        return completion
      }) { 1 }
      completedOperations += 1
    }

    tracerProvider.forceFlush()
    let metricFlushed = meterProvider.forceFlush()
    let logFlushed = logProcessor.forceFlush(explicitTimeout: 2)
    if expectExportFailure {
      XCTAssertEqual(completedOperations, 7)
    } else {
      XCTAssertTrue(isSuccess(metricFlushed))
      XCTAssertTrue(isSuccess(logFlushed))
    }
  }
}

private func isSuccess(_ result: ExportResult) -> Bool {
  if case .success = result { return true }
  return false
}
