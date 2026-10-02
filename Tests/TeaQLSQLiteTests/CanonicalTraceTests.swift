import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

/// Native provider proof, deliberately distinct from generated Q/E acceptance.
@Test(arguments: [false, true])
func swiftNativeThreeRelationPathsRemainCanonical(deepestFailure: Bool) async throws {
  func descriptor(_ name: String, _ table: String, _ foreignKey: String? = nil) -> EntityDescriptor {
    var properties = [PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true)]
    if let foreignKey { properties.append(PropertyDescriptor(name: foreignKey, type: .int)) }
    return EntityDescriptor(name: name, table: table, properties: properties)
  }
  let region = descriptor("TraceRegion", "trace_region")
  let organization = descriptor("TraceOrganization", "trace_organization", "regionId")
  let platform = descriptor("TracePlatform", "trace_platform", "organizationId")
  let order = descriptor("CustomerOrder", "trace_order", "platformId")
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-native-trace-\(UUID()).sqlite").path
  let service = try SQLiteDataService(path: path)
  let evidence = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "trace-native",
    entities: deepestFailure ? [order, platform, organization] : [order, platform, organization, region]))
  for (entity, key) in [(order, "platformId"), (platform, "organizationId"), (organization, "regionId")] {
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(1), key: .int(1)], auditReason: "seed native trace fixture"))
  }
  if !deepestFailure {
    _ = try await context.execute(Mutation(kind: .create, entity: region,
      values: ["id": .int(1)], auditReason: "seed native trace leaf"))
  }
  await evidence.enableAll()
  var regionQuery = SelectQuery(entity: region); regionQuery.limit = 2
  var organizationQuery = SelectQuery(entity: organization); organizationQuery.limit = 2
  organizationQuery.relationQuery("region", localKey: "regionId", foreignKey: "id", many: false, query: regionQuery)
  var platformQuery = SelectQuery(entity: platform); platformQuery.limit = 2
  platformQuery.relationQuery("organization", localKey: "organizationId", foreignKey: "id", many: false, query: organizationQuery)
  var query = SelectQuery(entity: order); query.limit = 2
  query.comment = "what: inspect the native order graph"; query.purpose = "why: verify real relation routing"
  query.relationQuery("platform", localKey: "platformId", foreignKey: "id", many: false, query: platformQuery)
  do {
    let result = try await context.execute(query)
    #expect(!deepestFailure)
    #expect(result.records.count == 1)
  } catch is SQLiteError {
    #expect(deepestFailure)
  }
  let entries = await evidence.snapshot()
  #expect(entries.count == 4)
  for (depth, entry) in entries.enumerated() {
    #expect(entry.tracePath.map(\.kind) == ["operation", "request"]
      + Array(repeating: "relation", count: depth) + ["provider", "sql"])
    #expect(entry.tracePath.prefix(2).map(\.name) == ["CustomerOrder", "CustomerOrder"])
    #expect(entry.tracePath.first?.comment == "query")
    #expect(entry.tracePath.filter { $0.kind == "relation" }.map(\.name)
      == Array(["platform", "organization", "region"].prefix(depth)))
    #expect(entry.tracePath.filter { $0.kind == "relation" }.map(\.comment)
      == Array(["CustomerOrder.platform", "TracePlatform.organization", "TraceOrganization.region"].prefix(depth)))
    #expect(entry.tracePath.filter { ["request", "provider", "sql"].contains($0.kind) }
      .allSatisfy { $0.comment.isEmpty && $0.purpose.isEmpty })
    #expect(entry.comment == query.comment && entry.purpose == query.purpose)
    #expect(entry.executionOutcome == (deepestFailure && depth == 3 ? "failure" : "success"))
  }
  #expect(query.tracePath.isEmpty)
  #expect(platformQuery.tracePath.isEmpty && organizationQuery.tracePath.isEmpty && regionQuery.tracePath.isEmpty)
}

@Test
func swiftUnusedChildBindingsProtectParentWithoutChildSQL() async throws {
  let root = EntityDescriptor(name: "EmptyParent", table: "empty_parent", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let child = EntityDescriptor(name: "AbsentChild", table: "absent_child", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "parentId", type: .int),
    PropertyDescriptor(name: "name", type: .string),
  ], auditMaskFields: ["name"])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-unused-trace-\(UUID()).sqlite").path
  let service = try SQLiteDataService(path: path)
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  try await context.ensureSchema(RuntimeModule(name: "unused-trace", entities: [root]))
  var nested = SelectQuery(entity: child)
  nested.filter = .equal("name", .string("CHILD-PRIVATE-CANARY"))
  var query = SelectQuery(entity: root); query.limit = 2
  query.comment = "what: inspect CHILD-PRIVATE-CANARY"; query.purpose = "why: verify a declared unused child"
  query.relationAggregate("children", foreignKey: "parentId", alias: "count", query: nested)
  let original = query
  let result = try await context.execute(query)
  #expect(result.records.isEmpty)
  let entries = await evidence.snapshot()
  #expect(entries.count == 1)
  #expect(entries.first?.tracePath.filter { $0.kind == "relation" }.isEmpty == true)
  #expect(!entries.description.contains("CHILD-PRIVATE-CANARY"))
  #expect(!(await sink.snapshot()).joined().contains("CHILD-PRIVATE-CANARY"))
  #expect(query == original && nested.tracePath.isEmpty)
}
