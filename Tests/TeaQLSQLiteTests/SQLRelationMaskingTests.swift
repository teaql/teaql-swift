import CSQLite
import Foundation
import Testing
@testable import TeaQLCore
import TeaQLSQLite

private func relationDDL(_ path: String, _ sql: String) throws {
  var db: OpaquePointer?
  guard sqlite3_open(path, &db) == SQLITE_OK else { throw TeaQLError.execution("fixture open failed") }
  defer { sqlite3_close(db) }
  guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
    throw TeaQLError.execution("fixture DDL failed")
  }
}

private func relationEntity(_ name: String, fields: [String]) -> EntityDescriptor {
  EntityDescriptor(name: name, table: name.lowercased() + "_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ] + fields.map { PropertyDescriptor(name: $0, type: $0.hasSuffix("_id") ? .int : .string) },
  auditMaskFields: ["name"])
}

private actor RelationLogCapture: DiagnosticSQLLogSink {
  let text = TextDiagnosticSQLLogSink(writer: { _ in })
  var entries: [SQLExecutionMetadata] = []
  func write(_ metadata: SQLExecutionMetadata) async {
    entries.append(metadata)
    await text.write(metadata)
  }
  func snapshot() async -> [String] { await text.snapshot() }
  func metadata() -> [SQLExecutionMetadata] { entries }
}

@Test(arguments: ["batch", "probe", "window", "aggregate", "forward"], [false, true])
func derivedRelationMasksAncestorIntent(shape: String, failure: Bool) async throws {
  // Debug is selected by a separate process invocation, never process-wide
  // environment mutation while Swift Testing runs other cases concurrently.
  let debug = LogPrivacy.plaintextEnabled()
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-relation-\(UUID()).sqlite").path
  let service = try SQLiteDataService(path: path)
  let customer = relationEntity("Customer", fields: ["name", "password"])
  let order = relationEntity("Order", fields: ["customer_id", "name"])
  let line = relationEntity("Line", fields: ["order_id"])
  let evidence = SQLExecutionEvidenceStore()
  let sink = RelationLogCapture()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  try await context.ensureSchema(RuntimeModule(name: "relation-mask", entities: [customer, order, line]))
  for (entity, values) in [
    (customer, ["id": TeaQLValue.int(1), "name": .string("Riverside"), "password": .string("PASSWORD-CANARY")]),
    (order, ["id": .int(1), "customer_id": .int(1), "name": .string("Lakeside")]),
    (line, ["id": .int(1), "order_id": .int(1)]),
  ] {
    _ = try await context.execute(Mutation(kind: .create, entity: entity, values: values, auditReason: "what: seed relation fixture"))
  }
  await evidence.enableAll()
  let before = await sink.snapshot().count
  var child = SelectQuery(entity: order)
  child.projection = ["id", "name"]
  if shape == "probe" { child.limit = 1; child.topNProbeParentThreshold = 32 }
  if shape == "window" { child.limit = 1; child.topNProbeParentThreshold = 0 }
  if shape == "nested" {
    child.filter = .equal("name", .string("Lakeside"))
    var grandchild = SelectQuery(entity: line)
    grandchild.projection = ["id"]; grandchild.limit = 2
    child.relationQuery("lines", localKey: "id", foreignKey: "order_id", query: grandchild)
  }
  var query = SelectQuery(entity: customer)
  query.filter = .and([.equal("name", .string("Riverside")), .equal("password", .string("PASSWORD-CANARY"))])
  query.limit = 1
  query.comment = "what: load Riverside PASSWORD-CANARY Lakeside graph"
  query.purpose = "why: verify derived query intent"
  if shape == "aggregate" {
    query.relationAggregate("orders", foreignKey: "customer_id", alias: "count", query: child)
  } else {
    query.relationQuery("orders", localKey: "id", foreignKey: "customer_id", many: shape != "forward", query: child)
  }
  let failedTable = shape == "nested" ? "line_data" : "order_data"
  if failure { try relationDDL(path, "ALTER TABLE \(failedTable) RENAME TO unavailable") }
  do {
    let result = try await context.execute(query)
    #expect(!failure)
    #expect(result.records.count == 1)
    #expect(result.metadata?.parameters.contains(.string("PASSWORD-CANARY")) == true)
    #expect(result.records.first?["name"] == .string("Riverside"))
    if shape == "aggregate" { #expect(result.records.first?["count"] == .int(1)) }
    else if shape == "forward" {
      guard case .object(let row) = result.records.first?["orders"] else { Issue.record("missing forward graph"); return }
      #expect(row["id"] == .int(1))
    } else {
      guard case .array(let children) = result.records.first?["orders"],
        case .object(let row) = children.first else { Issue.record("missing child graph"); return }
      #expect(children.count == 1); #expect(row["id"] == .int(1))
      if shape == "nested" {
        guard case .array(let lines) = row["lines"], case .object(let first) = lines.first else { Issue.record("missing nested graph"); return }
        #expect(lines.count == 1); #expect(first["id"] == .int(1))
      }
    }
  } catch let error as SQLiteError {
    #expect(failure)
    guard case .sqlite(let code, _, _) = error else { Issue.record("wrong original error"); return }
    #expect(code == 1)
  }
  if failure { try relationDDL(path, "ALTER TABLE unavailable RENAME TO \(failedTable)") }
  let entries = await evidence.snapshot()
  #expect(entries.count == (shape == "nested" ? 3 : 2))
  let entry = try #require(entries.last)
  #expect(entry.executionOutcome == (failure ? "failure" : "success"))
  #expect(entry.comment?.hasPrefix("what: load") == true)
  #expect(entry.purpose == "why: verify derived query intent")
  #expect(!entries.description.contains("Riverside"))
  #expect(!entries.description.contains("PASSWORD-CANARY"))
  if shape == "nested" {
    #expect(entries.allSatisfy { $0.comment?.contains("Lakeside") == false })
    #expect(entry.comment?.contains("Lakeside") == false)
  }
  let text = await sink.snapshot().dropFirst(before).joined(separator: "\n")
  #expect(!text.contains("PASSWORD-CANARY"))
  #expect(text.contains("Riverside") == debug)
  if shape == "nested" { #expect(text.contains("Lakeside") == debug) }
  #expect(text.contains(debug ? "EXPLICIT OPT-IN" : "SAFE"))
  // SQLite binds FK + limit; a window also binds its lower rank bound.
  #expect(entry.parameters.count == (shape == "window" ? 3 : 2))
  let retained = try #require(await sink.metadata().last)
  #expect(!LogPrivacy.project(retained, allowPlaintext: false).comment!.contains("Riverside"))
  #expect(!(await sink.metadata().description).contains("PASSWORD-CANARY"))
  if shape == "batch" { #expect(entry.parameterizedSQL.contains(" IN (")) }
  if shape == "window" { #expect(entry.parameterizedSQL.contains("ROW_NUMBER() OVER")) }
  if shape == "probe" { #expect(!entry.parameterizedSQL.contains(" IN (") && !entry.parameterizedSQL.contains("ROW_NUMBER")) }
  var independent = SelectQuery(entity: customer)
  independent.limit = 1; independent.comment = "what: independent Riverside"; independent.purpose = "why: isolation"
  let restored = try await context.execute(independent)
  #expect(restored.records.first?["password"] == .string("PASSWORD-CANARY"))
  #expect(await evidence.snapshot().last?.comment == "what: independent Riverside")
}

// Nested plans now execute; inspect every parent/descendant destination, not just
// the final child, because root prose may mention a child's private binding.
@Test(arguments: [false, true])
func nestedRelationMaskingCapability(failure: Bool) async throws {
  try await derivedRelationMasksAncestorIntent(shape: "nested", failure: failure)
}
