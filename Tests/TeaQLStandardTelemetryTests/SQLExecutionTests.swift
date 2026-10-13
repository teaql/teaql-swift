import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import TeaQLCore
import TeaQLSQLite
import XCTest
@testable import TeaQLStandardTelemetry

final class SQLExecutionTests: XCTestCase {
  func testActualStatementsCarrySafeDiagnosticsEvenWhenOrdinarySQLLoggingIsOff() async throws {
    let capture = SDKCapture()
    let telemetry = try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-sql-test",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: capture, metricExporter: capture, logExporter: capture)
    let provider = try SQLiteDataService(path: ":memory:")
    let evidence = SQLExecutionEvidenceStore()
    let descriptor = EntityDescriptor(name: "School", table: "telemetry_school", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
    ], auditMaskFields: ["name"])
    let text = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
      diagnosticSQLLogSink: text, querySQLLogEnabled: false, mutationSQLLogEnabled: false,
      runtimeTelemetry: telemetry)
    try await context.ensureSchema(RuntimeModule(name: "sql telemetry", entities: [descriptor]))
    _ = try await context.execute(Mutation(kind: .create, entity: descriptor,
      values: ["id": .int(1), "name": .string("SQL-SECRET-CANARY")],
      auditReason: "create SQL-SECRET-CANARY school"))
    _ = try await context.execute(Mutation(kind: .update, entity: descriptor, id: .int(1),
      values: ["name": .string("SQL-SECRET-CANARY")], expectedVersion: 1,
      auditReason: "update SQL-SECRET-CANARY school"))
    var query = SelectQuery(entity: descriptor)
    query.limit = 10; query.filter = .equal("name", .string("SQL-SECRET-CANARY"))
    query.comment = "load SQL-SECRET-CANARY school"; query.purpose = "render school"
    let result = try await context.execute(query)
    XCTAssertEqual(result.records.count, 1)
    let count = try await context.count(query)
    XCTAssertEqual(count, 1)
    var missing = SelectQuery(entity: EntityDescriptor(name: "Absent", table: "absent_table", properties: descriptor.properties))
    missing.limit = 1; missing.comment = "verify failed query"; missing.purpose = "exercise failure diagnostics"
    do { _ = try await context.execute(missing); XCTFail("absent table must fail") }
    catch is SQLiteError { }
    await telemetry.flush()

    let sqlLogs = capture.logs.filter { $0.body == .string("TeaQL SQL execution") }
    let physical = capture.spans.filter { $0.attributes["teaql.provider.execution"] == .string("statement") }
    XCTAssertEqual(sqlLogs.count, 7)
    XCTAssertEqual(physical.count, 7)
    XCTAssertEqual(Set(sqlLogs.compactMap { $0.spanContext?.spanId }).count, 7)
    for log in sqlLogs {
      let span = try XCTUnwrap(physical.first { $0.spanId == log.spanContext?.spanId })
      XCTAssertEqual(span.traceId, log.spanContext?.traceId)
      let attributes = "\(log.attributes)"
      XCTAssertFalse(attributes.contains("SQL-SECRET-CANARY"))
      XCTAssertFalse(attributes.contains("entityID"))
      XCTAssertNotNil(log.attributes["teaql.sql.debug"])
      XCTAssertNotNil(log.attributes["teaql.trace_chain"])
    }
    for writeName in ["sqlite.insert", "sqlite.update"] {
      let write = try XCTUnwrap(physical.first { $0.attributes["teaql.operation.name"] == .string(writeName) })
      let read = try XCTUnwrap(physical.first { $0.attributes["teaql.operation.name"] == .string("sqlite.readback") && $0.parentSpanId == write.parentSpanId })
      XCTAssertNotEqual(write.spanId, read.spanId)
      XCTAssertEqual(write.traceId, read.traceId)
    }
    XCTAssertTrue(sqlLogs.contains { $0.attributes["teaql.sql.outcome"] == .string("failure") })
    let lines = await text.snapshot()
    XCTAssertTrue(lines.isEmpty)
    let retained = await evidence.snapshot()
    XCTAssertEqual(retained.count, 7)
    await telemetry.shutdown()
  }
}
