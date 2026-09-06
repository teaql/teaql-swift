import Foundation
import TeaQLCore
import TeaQLSQLite
import Testing

@Test func dynamicSearchPreservesOuterAndRelatedTenantScopes() async throws {
  let platform = EntityDescriptor(name: "Platform", table: "search_platform", properties: [
    .init(name: "id", type: .int, isID: true), .init(name: "version", type: .int, isVersion: true),
    .init(name: "tenant_id", type: .int), .init(name: "name", type: .string)
  ])
  let school = EntityDescriptor(name: "School", table: "search_school", properties: [
    .init(name: "id", type: .int, isID: true), .init(name: "version", type: .int, isVersion: true),
    .init(name: "tenant_id", type: .int), .init(name: "platform_id", type: .int), .init(name: "name", type: .string)
  ])
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-search-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "search", entities: [platform, school]))
  for (id, tenant) in [(1, 7), (2, 8)] {
    _ = try await service.execute(Mutation(kind: .create, entity: platform, id: .int(Int64(id)),
      values: ["tenant_id": .int(Int64(tenant)), "name": .string("Campus")], auditReason: "seed search platform"))
  }
  for (id, tenant, parent, name) in [
    (1, 7, 1, "School"), (2, 7, 1, "School"), (3, 7, 1, "School"),
    (4, 8, 1, "School"), (5, 7, 2, "School"), (6, 7, 1, "Other")
  ] {
    _ = try await service.execute(Mutation(kind: .create, entity: school, id: .int(Int64(id)),
      values: ["tenant_id": .int(Int64(tenant)), "platform_id": .int(Int64(parent)), "name": .string(name)],
      auditReason: "seed search isolation counterexample"))
  }
  let models: [String: SearchModel] = [
    "School": .init(fields: ["name": "string", "id": "integer"], relations: ["platform": "Platform"]),
    "Platform": .init(fields: ["name": "string"])
  ]
  var base = SelectQuery(entity: school)
  base.projection = ["id", "name"]
  base.filter = .equal("tenant_id", .int(7))
  base.orderBy = [OrderBy("id", .descending)]
  base.limit = 2
  base.hardLimit = 2
  base.comment = "what: search tenant schools"
  base.purpose = "why: schema drift isolation regression"
  var warnings: [DynamicSearchWarning] = []
  let result = try DynamicSearch.merge(base, source:
    #"{"filter":{"name":"School","platform.name":"Campus","old_name":"secret","old_relation.name":"secret","platform.old_name":"secret"},"orderBy":[{"field":"removed","direction":"asc"},{"field":"name","direction":"asc"}]}"#,
    models: models, filterBinding: { filter in
      switch filter.fieldPath {
      case "name": return .equal("name", filter.value)
      case "platform.name":
        var nested = SelectQuery(entity: platform)
        nested.filter = .and([.equal("tenant_id", .int(7)), .equal("name", filter.value)])
        return .inSubquery("platform_id", RelationQueryPlan(nested), "id")
      default: throw DynamicSearchError.invalid("Unbound trusted field")
      }
    }, orderBinding: { OrderBy($0.fieldPath, $0.direction) }, warn: { warnings.append($0) })
  let rows = try await context.execute(result.query).records
  #expect(rows.map { $0["id"]?.int64Value } == [3, 2])
  #expect(warnings.count == 4)
  #expect(result.query.hardLimit == 2)
  #expect(base.filter == .equal("tenant_id", .int(7)))
  #expect(base.orderBy.count == 1)
}
