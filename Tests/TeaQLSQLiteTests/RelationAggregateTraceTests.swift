import CSQLite
import Foundation
import Testing
@testable import TeaQLCore
import TeaQLSQLite

private func aggregateEntity(_ name: String, fields: [PropertyDescriptor]) -> EntityDescriptor {
  EntityDescriptor(name: name, table: "aggregate_" + name.lowercased(), properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ] + fields, auditMaskFields: ["name"])
}

private func aggregateDDL(_ path: String, _ sql: String) throws {
  var db: OpaquePointer?
  guard sqlite3_open(path, &db) == SQLITE_OK else { throw TeaQLError.execution("fixture open") }
  defer { sqlite3_close(db) }
  guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
    throw TeaQLError.execution("fixture DDL")
  }
}

// Native SQLite proof: a hydrated FK must still group by its declared target
// key (code, not id). Count/list composition must not alter ancestry or privacy.
private func verifyAggregateGraph(
  nested: Bool, logging: Bool, failure: Bool, repeatReference: Bool = false,
  hiddenReference: Bool = false
) async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-aggregate-\(UUID()).sqlite").path
  let service = try SQLiteDataService(path: path)
  let group = aggregateEntity("Group", fields: [])
  let parent = aggregateEntity("Parent", fields: [
    PropertyDescriptor(name: "group_id", type: .int),
    PropertyDescriptor(name: "code", type: .string),
  ])
  let child = aggregateEntity("Child", fields: [
    PropertyDescriptor(name: "parent_ref", type: .string),
  ])
  let event = aggregateEntity("Event", fields: [
    PropertyDescriptor(name: "child_id", type: .int),
    PropertyDescriptor(name: "name", type: .string),
  ])
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
    diagnosticSQLLogSink: sink, querySQLLogEnabled: logging)
  try await context.ensureSchema(RuntimeModule(name: "aggregate-trace", entities: [group, parent, child, event]))
  let seeds: [(EntityDescriptor, TeaQLRecord)] = [
    (group, ["id": .int(90)]),
    (parent, ["id": .int(1), "code": .string("CODE-A"), "group_id": .int(90)]),
    (parent, ["id": .int(2), "code": .string("CODE-B"), "group_id": .int(90)]),
    (child, ["id": .int(11), "parent_ref": .string("CODE-A")]),
    (child, ["id": .int(12), "parent_ref": .string("CODE-A")]),
    (event, ["id": .int(21), "child_id": .int(11), "name": .string("PRIVATE-AGGREGATE")]),
    (event, ["id": .int(22), "child_id": .int(11), "name": .string("public")]),
  ]
  for (entity, values) in seeds {
    _ = try await context.execute(Mutation(kind: .create, entity: entity, values: values,
      auditReason: "seed aggregate graph"))
  }
  await evidence.enableAll()
  let before = await sink.snapshot().count
  var events = SelectQuery(entity: event)
  events.filter = .equal("name", .string("PRIVATE-AGGREGATE"))
  var children = SelectQuery(entity: child)
  children.projection = ["id"]
  children.orderBy = [OrderBy("id", .ascending)]
  children.relationAggregate("events", foreignKey: "child_id", alias: "filtered_count", query: events)
  var parentReference = SelectQuery(entity: parent)
  parentReference.projection = ["code"]
  if hiddenReference { parentReference.filter = .equal("code", .string("not-visible")) }
  children.relationQuery("parent_ref", localKey: "parent_ref", foreignKey: "code",
    many: false, query: parentReference)
  if repeatReference {
    children.relationQuery("parent_again", localKey: "parent_ref", foreignKey: "code",
      many: false, query: parentReference)
  }
  var parents = SelectQuery(entity: parent)
  parents.projection = ["code"]
  parents.orderBy = [OrderBy("id", .ascending)]
  parents.relationQuery("children", localKey: "code", foreignKey: "parent_ref", query: children)
  var query = parents
  if nested {
    query = SelectQuery(entity: group)
    query.relationQuery("parents", localKey: "id", foreignKey: "group_id", query: parents)
  }
  query.limit = 2
  query.comment = "load PRIVATE-AGGREGATE graph"
  query.purpose = "prove count and hydrated membership"
  if failure { try aggregateDDL(path, "ALTER TABLE aggregate_event RENAME TO unavailable_event") }
  do {
    let result = try await context.execute(query)
    #expect(!failure)
    #expect(result.relationAttachmentKeys.isEmpty)
    var rows = result.records
    if nested {
      let root = try #require(rows.first)
      guard case .array(let values) = root["parents"] else { Issue.record("missing parents"); return }
      rows = values.compactMap { if case .object(let row) = $0 { return row }; return nil }
    }
    #expect(rows.count == 2)
    let first = try #require(rows.first)
    guard case .array(let values) = first["children"] else { Issue.record("missing children"); return }
    #expect(values.count == 2)
    let loaded = values.compactMap { if case .object(let row) = $0 { return row }; return nil }
    #expect(loaded.map { $0["filtered_count"] } == [.int(1), .int(0)])
    for row in loaded {
      #expect(Set(row.keys) == Set(["id", "version", "parent_ref", "filtered_count"]
        + (repeatReference ? ["parent_again"] : [])))
      if hiddenReference {
        #expect(row["parent_ref"] == .object(["code": .string("CODE-A")]))
        continue
      }
      guard case .object(let ref) = row["parent_ref"] else { Issue.record("missing hydrated FK"); continue }
      #expect(ref["code"] == .string("CODE-A"))
      #expect(ref["id"] == .int(1))
      if repeatReference { #expect(row["parent_again"] == row["parent_ref"]) }
    }
    #expect(rows.last?["children"] == .array([]))
  } catch let error as SQLiteError {
    #expect(failure)
    guard case .sqlite(let code, _, _) = error else { Issue.record("wrong original error"); return }
    #expect(code == 1)
  }
  if failure { try aggregateDDL(path, "ALTER TABLE unavailable_event RENAME TO aggregate_event") }
  let facts = await evidence.snapshot()
  #expect(facts.count == (nested ? 1 : 0) + (failure ? 3 : 4 + (repeatReference ? 1 : 0)))
  #expect(!facts.description.contains("PRIVATE-AGGREGATE"))
  let prefix = nested ? ["parents", "children"] : ["children"]
  let countFact = try #require(facts.first { $0.parameterizedSQL.uppercased().contains("COUNT(") })
  #expect(countFact.tracePath.filter { $0.kind == "relation" }.map(\.name) == prefix + ["events"])
  #expect(countFact.executionOutcome == (failure ? "failure" : "success"))
  if !failure {
    #expect(facts.last?.tracePath.filter { $0.kind == "relation" }.map(\.name)
      == prefix + [repeatReference ? "parent_again" : "parent_ref"])
  }
  for fact in facts {
    #expect(fact.purpose == query.purpose)
    #expect(fact.comment?.contains("PRIVATE-AGGREGATE") == false)
    #expect(fact.tracePath.first?.name == (nested ? "Group" : "Parent"))
    #expect(fact.tracePath.map(\.level) == Array(fact.tracePath.indices))
  }
  let logs = Array(await sink.snapshot().dropFirst(before))
  #expect(logs.count == (logging ? facts.count : 0))
  // Separate debug-process tests exercise explicit plaintext; safe telemetry is
  // always masked, regardless of the diagnostic setting.
  if !LogPrivacy.plaintextEnabled() { #expect(!logs.description.contains("PRIVATE-AGGREGATE")) }
  var independent = SelectQuery(entity: parent)
  independent.limit = 1; independent.comment = "independent PRIVATE-AGGREGATE"
  independent.purpose = "prove failure does not leak intent scope"
  #expect(try await context.execute(independent).records.count == 1)
  let last = try #require(await evidence.snapshot().last)
  #expect(last.comment == independent.comment)
  #expect(last.tracePath.filter { $0.kind == "relation" }.isEmpty)
}

@Test(arguments: [false, true], [false, true])
func swiftAggregateHydratedMembership(nested: Bool, logging: Bool) async throws {
  try await verifyAggregateGraph(nested: nested, logging: logging, failure: false)
}

@Test(arguments: [false, true])
func swiftAggregateFailureRecovery(nested: Bool) async throws {
  try await verifyAggregateGraph(nested: nested, logging: true, failure: true)
}

@Test(arguments: [false, true])
func swiftAggregateSiblingUsesOriginalMembership(nested: Bool) async throws {
  try await verifyAggregateGraph(nested: nested, logging: true, failure: false, repeatReference: true)
}

@Test(arguments: [false, true])
func swiftAggregateFilteredReferencePreservesMembership(nested: Bool) async throws {
  try await verifyAggregateGraph(nested: nested, logging: true, failure: false, hiddenReference: true)
}

@Test func swiftForwardIDReferenceKeepsIdentityButNotHiddenDetailOrNullIdentity() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-forward-null-\(UUID()).sqlite").path
  let service = try SQLiteDataService(path: path)
  let parent = aggregateEntity("Parent", fields: [PropertyDescriptor(name: "name", type: .string)])
  let child = aggregateEntity("Child", fields: [PropertyDescriptor(name: "parent_id", type: .int, nullable: true)])
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false)
  try await context.ensureSchema(RuntimeModule(name: "forward-null", entities: [parent, child]))
  for (entity, values) in [
    (parent, ["id": TeaQLValue.int(1), "name": .string("visible")]),
    (child, ["id": .int(1), "parent_id": .int(1)]),
    (child, ["id": .int(2), "parent_id": .null]),
  ] {
    _ = try await context.execute(Mutation(kind: .create, entity: entity, values: values,
      auditReason: "seed nullable ID reference"))
  }
  var query = SelectQuery(entity: child)
  query.projection = ["id"]; query.orderBy = [OrderBy("id", .ascending)]; query.limit = 2
  query.comment = "load filtered references"; query.purpose = "keep identity and loading boundaries distinct"
  #expect(try await context.execute(query).records[0]["parent"] == nil)
  var detail = SelectQuery(entity: parent)
  detail.filter = .equal("name", .string("absent"))
  query.relationQuery("parent", localKey: "parent_id", foreignKey: "id", many: false, query: detail)
  let result = try await context.execute(query)
  #expect(result.records[0]["parent"] == .object(["id": .int(1)]))
  #expect(result.records[1]["parent"] == .null)
  #expect(result.loadedRelations[0]?["parent"]?.records == [["id": .int(1)]])
  #expect(result.loadedRelations[1]?["parent"]?.records.isEmpty == true)
}
