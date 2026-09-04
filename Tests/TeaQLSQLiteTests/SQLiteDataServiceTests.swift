import Foundation
import TeaQLCore
import TeaQLTestSupport
import Testing

@testable import TeaQLSQLite

private let order = EntityDescriptor(
  name: "CustomerOrder", table: "customer_order",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "orderNumber", column: "order_number", type: .string),
    PropertyDescriptor(name: "orderDate", column: "order_date", type: .date),
    PropertyDescriptor(name: "tenantID", column: "tenant_id", type: .int),
  ])

@Test func topNRelationPlansAreEquivalentAndCanonicalIndexIsIdempotent() async throws {
  let parent = EntityDescriptor(name: "TopNParent", table: "topn_parent", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let child = EntityDescriptor(name: "TopNChild", table: "topn_child", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "parentId", column: "parent_id", type: .int),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "state", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-topn-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  let module = RuntimeModule(name: "topn", entities: [parent, child])
  try await context.ensureSchema(module)
  try await context.ensureSchema(module)
  for id in 1...3 {
    _ = try await service.execute(Mutation(kind: .create, entity: parent, id: .int(Int64(id)),
      values: [:], auditReason: "seed Top-N parent"))
  }
  for parentID in 1...2 {
    for index in 1...4 {
      _ = try await service.execute(Mutation(kind: .create, entity: child,
        id: .int(Int64(parentID * 100 + index)), values: [
          "parentId": .int(Int64(parentID)), "name": .string("same"), "state": .string("visible"),
        ], auditReason: "seed Top-N child"))
    }
  }
  _ = try await service.execute(Mutation(kind: .create, entity: child, id: .int(9999),
    values: ["parentId": .int(1), "name": .string("same"), "state": .string("hidden")],
    auditReason: "seed excluded Top-N child"))

  func query(_ threshold: Int?) -> SelectQuery {
    var nested = SelectQuery(entity: child)
    nested.projection = ["id", "name"]
    nested.filter = .and([.equal("state", .string("visible")), .greaterThan("version", .int(0))])
    nested.orderBy = [OrderBy("name", .descending)]
    nested.limit = 3
    nested.topNProbeParentThreshold = threshold
    var root = SelectQuery(entity: parent)
    root.orderBy = [OrderBy("id", .ascending)]
    root.comment = "load Top-N child relation"
    root.purpose = "verify probe and window equivalence"
    root.relationQuery("children", localKey: "id", foreignKey: "parentId", query: nested)
    return root
  }
  func ids(_ rows: [TeaQLRecord]) -> [[Int64]] {
    rows.map { row in
      guard case .array(let children) = row["children"] else { return [] }
      return children.compactMap { value in
        guard case .object(let child) = value else { return nil }
        return child["id"]?.int64Value
      }
    }
  }
  let probes = try await context.execute(query(nil)).records
  let window = try await context.execute(query(0)).records
  #expect(ids(probes) == ids(window))
  #expect(ids(probes).map(\.count) == [3, 3, 0])
  #expect(ids(try await context.execute(query(3)).records) == ids(probes))
  #expect(ids(try await context.execute(query(2)).records) == ids(probes))

  let schema = EntityDescriptor(name: "SQLiteSchema", table: "sqlite_master", properties: [
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "sql", type: .string, nullable: true),
  ])
  var indexQuery = SelectQuery(entity: schema)
  indexQuery.filter = .equal("name", .string("idx_topn_child_parent_id_id_desc"))
  indexQuery.comment = "inspect canonical Top-N relation index"
  indexQuery.purpose = "verify idempotent schema ensure"
  #expect(try await service.execute(indexQuery).records.count == 1)
}

@Test func continuousPageUsesIdSeekWithoutDuplicateOrMissingRows() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-continuous-page-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(
    queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "continuous-page", entities: [order]))
  for id in 1...5 {
    _ = try await service.execute(Mutation(
      kind: .create, entity: order, id: .int(Int64(id)),
      values: [
        "orderNumber": .string("ORDER-\(id)"), "orderDate": .calendarDate("2026-08-29"),
        "tenantID": .int(1),
      ],
      auditReason: "seed continuous page order"))
  }
  func page(_ offset: Int) async throws -> [Int64] {
    var query = SelectQuery(entity: order)
    query.projection = ["id", "orderNumber"]
    query.orderBy = [OrderBy("id", .descending)]
    query.offset = offset
    query.limit = 2
    query.continuousPage = ContinuousPageFetchOptions(namespace: "orders", ttlSeconds: 60)
    query.comment = "load continuous order page"
    query.purpose = "verify cursor seek semantics"
    return try await context.execute(query).records.compactMap { $0["id"]?.int64Value }
  }
  let first = try await page(0)
  #expect(first == [5, 4])
  #expect(await context.continuousPageObservation().plan == "OFFSET_FALLBACK:FIRST_PAGE")
  let second = try await page(2)
  #expect(second == [3, 2])
  #expect(Set(first).isDisjoint(with: second))
  #expect(await context.continuousPageObservation().plan == "CURSOR_SEEK")

  var missing = SelectQuery(entity: order)
  missing.orderBy = [OrderBy("id", .descending)]
  missing.offset = 4
  missing.limit = 2
  missing.continuousPage = ContinuousPageFetchOptions(namespace: "missing", ttlSeconds: 60)
  missing.comment = "load page without checkpoint"
  missing.purpose = "verify explicit cache miss fallback"
  #expect(try await context.execute(missing).records.compactMap { $0["id"]?.int64Value } == [1])
  #expect(await context.continuousPageObservation().plan == "OFFSET_FALLBACK:CACHE_MISS")
}

@Test func completeScalarFixtureIncludingNullableBooleanExecutesOnSQLite() async throws {
  let descriptor = EntityDescriptor(name: "QueryRecord", table: "query_record_scalar", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "requiredText", column: "required_text", type: .string),
    PropertyDescriptor(name: "optionalText", column: "optional_text", type: .string, nullable: true),
    PropertyDescriptor(name: "requiredInteger", column: "required_integer", type: .int),
    PropertyDescriptor(name: "optionalLong", column: "optional_long", type: .int, nullable: true),
    PropertyDescriptor(name: "requiredDecimal", column: "required_decimal", type: .decimal),
    PropertyDescriptor(name: "requiredFloat", column: "required_float", type: .double),
    PropertyDescriptor(name: "requiredDouble", column: "required_double", type: .double),
    PropertyDescriptor(name: "requiredDate", column: "required_date", type: .date),
    PropertyDescriptor(name: "requiredTime", column: "required_time", type: .int),
    PropertyDescriptor(name: "requiredTimestamp", column: "required_timestamp", type: .timestamp),
    PropertyDescriptor(name: "active", type: .bool),
    PropertyDescriptor(name: "reviewed", type: .bool, nullable: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-complete-query-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let queryContext = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await queryContext.ensureSchema(RuntimeModule(name: "complete-query", entities: [descriptor]))
  let rows: [(Int64, String, TeaQLValue, Int64, TeaQLValue, Decimal, Double, Double, String, Int64, Int64, Bool, TeaQLValue)] = [
    (1, "Alpha", .string("optional"), 42, .int(42_000_000_000), Decimal(string: "42.125")!, 42.5, 42.75, "2026-08-29", 34_200_000, 1_777_632_600_000, true, .bool(false)),
    (2, "Beta", .null, 7, .null, Decimal(string: "7.500")!, 7.5, 7.75, "2026-08-30", 36_000_000, 1_777_720_400_000, false, .null),
    (3, "Gamma", .string("tail"), 99, .int(99_000_000_000), Decimal(string: "99.875")!, 99.5, 99.75, "2026-08-31", 37_800_000, 1_777_808_200_000, true, .bool(true)),
  ]
  for row in rows {
    _ = try await service.execute(Mutation(kind: .create, entity: descriptor, id: .int(row.0), values: [
      "requiredText": .string(row.1), "optionalText": row.2,
      "requiredInteger": .int(row.3), "optionalLong": row.4,
      "requiredDecimal": .decimal(row.5), "requiredFloat": .double(row.6),
      "requiredDouble": .double(row.7), "requiredDate": .calendarDate(row.8),
      "requiredTime": .int(row.9), "requiredTimestamp": .timestamp(row.10),
      "active": .bool(row.11), "reviewed": row.12,
    ], auditReason: "seed complete query scalar fixture"))
  }
  func ids(_ expression: TeaQLExpression) async throws -> [Int64] {
    var query = SelectQuery(entity: descriptor)
    query.projection = ["id"]
    query.filter = expression
    query.orderBy = [OrderBy("id", .ascending)]
    query.comment = "execute complete scalar predicate"
    query.purpose = "retain Query conformance evidence"
    let records = try await queryContext.execute(query).records
    print("relation fixture rows", records)
    return records.compactMap { $0["id"]?.int64Value }
  }
  #expect(try await ids(.equal("requiredText", .string("Alpha"))) == [1])
  #expect(try await ids(.notEqual("requiredText", .string("Alpha"))) == [2, 3])
  #expect(try await ids(.inList("requiredText", [.string("Alpha"), .string("Gamma")])) == [1, 3])
  #expect(try await ids(.startsWith("requiredText", "Al")) == [1])
  #expect(try await ids(.endsWith("requiredText", "ma")) == [3])
  #expect(try await ids(.contains("requiredText", "et")) == [2])
  #expect(try await ids(.between("requiredInteger", .int(40), .int(100))) == [1, 3])
  #expect(try await ids(.greaterThan("requiredDecimal", .decimal(50))) == [3])
  #expect(try await ids(.lessThanOrEqual("requiredFloat", .double(7.5))) == [2])
  #expect(try await ids(.greaterThanOrEqual("requiredDouble", .double(99.75))) == [3])
  #expect(try await ids(.between("requiredDate", .calendarDate("2026-08-30"), .calendarDate("2026-08-31"))) == [2, 3])
  #expect(try await ids(.greaterThan("requiredTime", .int(36_000_000))) == [3])
  #expect(try await ids(.lessThan("requiredTimestamp", .timestamp(1_777_750_000_000))) == [1, 2])
  #expect(try await ids(.isNull("optionalText")) == [2])
  #expect(try await ids(.isNotNull("optionalLong")) == [1, 3])
  #expect(try await ids(.equal("active", .bool(false))) == [2])
  #expect(try await ids(.equal("reviewed", .bool(true))) == [3])
  #expect(try await ids(.equal("reviewed", .bool(false))) == [1])
  #expect(try await ids(.isNull("reviewed")) == [2])

  var grouped = SelectQuery(entity: descriptor)
  grouped.groupBy = ["active"]
  grouped.aggregates = [
    QueryAggregate(.count, field: "*", alias: "rowCount"),
    QueryAggregate(.sum, field: "requiredInteger", alias: "integerTotal"),
    QueryAggregate(.min, field: "requiredInteger", alias: "minimumInteger"),
    QueryAggregate(.max, field: "requiredInteger", alias: "maximumInteger"),
    QueryAggregate(.avg, field: "requiredInteger", alias: "averageInteger"),
  ]
  grouped.orderBy = [OrderBy("active", .ascending)]
  grouped.comment = "Group complete scalar rows"
  grouped.purpose = "Verify portable aggregate semantics"
  let aggregateRows = try await queryContext.execute(grouped).records
  #expect(aggregateRows.count == 2)
  #expect(aggregateRows[0]["active"]?.boolValue == false)
  #expect(aggregateRows[0]["rowCount"]?.int64Value == 1)
  #expect(aggregateRows[0]["integerTotal"]?.int64Value == 7)
  #expect(aggregateRows[1]["active"]?.boolValue == true)
  #expect(aggregateRows[1]["rowCount"]?.int64Value == 2)
  #expect(aggregateRows[1]["integerTotal"]?.int64Value == 141)
  #expect(aggregateRows[1]["minimumInteger"]?.int64Value == 42)
  #expect(aggregateRows[1]["maximumInteger"]?.int64Value == 99)
}

@Test func relationSubqueriesExecutePositiveAndNegativePredicatesOnSQLite() async throws {
  let group = EntityDescriptor(name: "QueryGroup", table: "query_group_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let record = EntityDescriptor(name: "QueryRecord", table: "query_record_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "queryGroup", column: "query_group", type: .int, nullable: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-subquery-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let queryContext = UserContext(
    queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await queryContext.ensureSchema(RuntimeModule(
    name: "relation-subquery", entities: [group, record]))
  for (id, name) in [(1, "Core"), (2, "Other"), (3, "Empty")] {
    _ = try await service.execute(Mutation(
      kind: .create, entity: group, id: .int(Int64(id)),
      values: ["name": .string(name)], auditReason: "seed query group"))
  }
  for (id, groupID, name) in [(11, 1, "included"), (12, 2, "excluded")] {
    _ = try await service.execute(Mutation(
      kind: .create, entity: record, id: .int(Int64(id)),
      values: ["queryGroup": .int(Int64(groupID)), "name": .string(name)],
      auditReason: "seed query record"))
  }
  _ = try await service.execute(Mutation(
    kind: .create, entity: record, id: .int(13),
    values: ["queryGroup": .null, "name": .string("orphan")],
    auditReason: "seed orphan query record"))
  var child = SelectQuery(entity: group)
  child.filter = .equal("name", .string("Core"))
  var included = SelectQuery(entity: record)
  included.filter = .inSubquery("queryGroup", RelationQueryPlan(child), "id")
  included.comment = "select records in core group"
  included.purpose = "verify positive relation predicate"
  var excluded = SelectQuery(entity: record)
  excluded.filter = .notInSubquery("queryGroup", RelationQueryPlan(child), "id")
  excluded.comment = "exclude records in core group"
  excluded.purpose = "verify negative relation predicate"

  #expect(try await queryContext.execute(included).records.first?["name"] == .string("included"))
  #expect(try await queryContext.execute(excluded).records.first?["name"] == .string("excluded"))

  func names(_ entity: EntityDescriptor, _ filter: TeaQLExpression) async throws -> [String] {
    var query = SelectQuery(entity: entity)
    query.filter = filter
    query.orderBy = [OrderBy("id", .ascending)]
    query.comment = "execute complete relation predicate"
    query.purpose = "retain complete relation fixture evidence"
    return try await queryContext.execute(query).records.compactMap { $0["name"]?.stringValue }
  }
  #expect(try await names(record, .isNotNull("queryGroup")) == ["included", "excluded"])
  #expect(try await names(record, .isNull("queryGroup")) == ["orphan"])
  #expect(try await names(record, .inSubquery("queryGroup", RelationQueryPlan(child), "id")) == ["included"])
  #expect(try await names(record, .notInSubquery("queryGroup", RelationQueryPlan(child), "id")) == ["excluded"])
  let allRecords = SelectQuery(entity: record)
  #expect(try await names(group, .inSubquery("id", RelationQueryPlan(allRecords), "queryGroup")) == ["Core", "Other"])
  #expect(try await names(group, .notInSubquery("id", RelationQueryPlan(allRecords), "queryGroup")) == ["Empty"])
}

@Test func ensureSchemaRegistersSoundexAndExecutesPhoneticQuery() async throws {
  let person = EntityDescriptor(name: "SoundexPerson", table: "soundex_person", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-soundex-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let soundexContext = UserContext(
    queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  let module = RuntimeModule(name: "soundex", entities: [person])
  try await soundexContext.ensureSchema(module)
  try await soundexContext.ensureSchema(module)
  for name in ["Robert", "Rupert", "Alice"] {
    _ = try await service.execute(Mutation(kind: .create, entity: person,
      values: ["name": .string(name)], auditReason: "seed soundex person"))
  }
  var query = SelectQuery(entity: person)
  query.filter = .soundingLike("name", "Robert")
  query.orderBy = [OrderBy("id", .ascending)]
  query.comment = "find phonetic names"
  query.purpose = "verify ensureSchema soundex registration"
  let rows = try await soundexContext.execute(query).records
  #expect(rows.compactMap { $0["name"]?.stringValue } == ["Robert", "Rupert"])
}

@Test func relationFacetUsesOuterFilterAndIncludeAllOnSQLite() async throws {
  let school = EntityDescriptor(name: "FacetSchool", table: "facet_school", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "schoolType", column: "school_type", type: .int),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let schoolType = EntityDescriptor(name: "FacetSchoolType", table: "facet_school_type", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "code", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-facet-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let facetContext = UserContext(
    queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await facetContext.ensureSchema(RuntimeModule(name: "facet", entities: [school, schoolType]))
  for (id, code) in [(1001, "PRIMARY"), (1002, "SECONDARY"), (1003, "VOCATIONAL")] {
    _ = try await service.execute(Mutation(kind: .create, entity: schoolType,
      values: ["id": .int(Int64(id)), "code": .string(code)], auditReason: "seed facet type"))
  }
  for (id, name, type) in [(1, "Riverside", 1001), (2, "Riverside Annex", 1001), (3, "Other", 1002)] {
    _ = try await service.execute(Mutation(kind: .create, entity: school, id: .int(Int64(id)),
      values: ["name": .string(name), "schoolType": .int(Int64(type))], auditReason: "seed facet school"))
  }
  var nested = SelectQuery(entity: schoolType)
  nested.projection = ["id", "code"]
  var outer = SelectQuery(entity: school)
  outer.filter = .contains("name", "Riverside")
  outer.comment = "facet filtered schools"
  outer.purpose = "verify SQLite facet semantics"
  outer.facets = [FacetRequest(name: "types", relationName: "schoolType", query: nested)]
  let all = try await facetContext.execute(outer).facets["types"]!
  #expect(all.count == 3)
  #expect(all.first { $0["id"]?.int64Value == 1001 }?["count"]?.int64Value == 2)
  #expect(all.first { $0["id"]?.int64Value == 1002 }?["count"]?.int64Value == 0)
  outer.facets = [FacetRequest(name: "types", relationName: "schoolType", query: nested,
    includeAllFacets: false)]
  let matched = try await facetContext.execute(outer).facets["types"]!
  #expect(matched.count == 1)
  #expect(matched.first?["id"]?.int64Value == 1001)
}

@Test func mutationAcceptsCanonicalModelKeysForCreateAndUpdate() async throws {
  let descriptor = EntityDescriptor(
    name: "School", table: "school_data",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "schoolType", modelName: "school_type", column: "school_type", type: .int),
      PropertyDescriptor(name: "studentCapacity", modelName: "student_capacity", column: "student_capacity", type: .string),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-model-keys-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "scalar-storage", entities: [descriptor]))
  let created = try await service.execute(Mutation(
    kind: .create, entity: descriptor,
    values: ["school_type": .int(1001), "student_capacity": .string("800")],
    auditReason: "create using KSML keys"))
  let id = created.persistedRecord?["id"] ?? .null
  #expect(created.persistedRecord?["schoolType"] == .int(1001))
  #expect(created.persistedRecord?["studentCapacity"] == .string("800"))
  let updated = try await service.execute(Mutation(
    kind: .update, entity: descriptor, id: id,
    values: ["student_capacity": .string("900")], expectedVersion: 1,
    auditReason: "update using KSML keys"))
  #expect(updated.persistedRecord?["studentCapacity"] == .string("900"))
}

private struct SavedWidget: TeaQLEntity, TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(
    name: "SavedWidget", table: "saved_widget",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "name", type: .string),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])

  var id: Int64 = 0
  var name = ""
  var version: Int64 = 0
  var teaqlEntityRoot = EntityRoot()
  var teaqlEntityKey: EntityKey { EntityKey(entity: "SavedWidget", id: .int(id)) }
  private enum CodingKeys: String, CodingKey { case id, name, version }

  mutating func markForDeletion() {
    teaqlEntityRoot.markAsDeleted(teaqlEntityKey)
  }

  mutating func updateName(_ value: String) {
    name = value
    teaqlEntityRoot.set(teaqlEntityKey, field: "name", value: .string(value))
  }

  static func from(record: TeaQLRecord) throws -> Self {
    Self(
      id: record["id"]?.int64Value ?? 0,
      name: record["name"]?.stringValue ?? "",
      version: record["version"]?.int64Value ?? 0)
  }

  func toRecord() -> TeaQLRecord {
    ["id": .int(id), "name": .string(name), "version": .int(version)]
  }
}

@Test func auditedCreatePreservesExplicitIDWhenVersionIsNew() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-explicit-id-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "saved-widget", entities: [SavedWidget.descriptor]))
  let saved = try await AuditedEntity(
    entity: SavedWidget(id: 1001, name: "Primary", version: 0),
    reason: "seed model-defined constant").save(context(service))
  #expect(saved.id == 1001)
  #expect(saved.version == 1)
}

@Test func generatedBootstrapRunsAfterDDLThroughTypedMutation() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-school-bootstrap-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let audit = RecordingAuditSink()
  let module = RuntimeModule(
    name: "generated-bootstrap", entities: [SavedWidget.descriptor],
    generatedBootstrap: { context in
      let bootstrap = context._generatedBootstrapContext(
        activeRoot: ContextEntityRef(entity: "SavedWidget", id: .int(1001)))
      #expect(try bootstrap.requireActiveRoot("SavedWidget").id == .int(1001))
      var query = SelectQuery(entity: SavedWidget.descriptor)
      query.filter = TeaQLExpression.equal("id", .int(1001))
      query.comment = "find generated bootstrap fixture"
      query.purpose = "ensure idempotent typed bootstrap"
      if try await bootstrap.execute(query).records.isEmpty {
        _ = try await SavedWidget(id: 1001, name: "Primary", version: 0)
          .auditAs("create model constant SavedWidget.Primary").save(bootstrap)
      }
    })
  var runtime = TeaQLRuntime()
  try runtime.install(module)
  let caller = UserContext(
    runtime: runtime, actor: "application", queryExecutor: service,
    mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, auditSink: audit)
  try await caller.ensureSchema(module)
  try await caller.ensureSchema(module)

  var query = SelectQuery(entity: SavedWidget.descriptor)
  query.comment = "verify generated bootstrap rows"
  query.purpose = "prove provider is DDL-only"
  let records = try await caller.execute(query).records
  #expect(records.count == 1)
  #expect(records[0]["id"] == .int(1001))
  #expect(records[0]["name"] == .string("Primary"))
  let events = await audit.events()
  #expect(events.count == 1)
  #expect(events[0].entityID == .int(1001))
  #expect(events[0].actor == "teaql-generated-bootstrap")
  #expect(events[0].category == "runtime-bootstrap")
  let rowAudit = try await service.auditEvents()
  #expect(rowAudit.first?["entityID"] == .string("1001"))
  #expect(rowAudit.first?["category"] == .string("runtime-bootstrap"))
  let created = try await SavedWidget(name: "next", version: 0)
    .auditAs("verify generated bootstrap ID floor").save(caller)
  #expect(created.id == 1002)
}

private func context(
  _ service: SQLiteDataService,
  auditSink: (any AuditSink)? = nil,
  telemetrySink: (any RuntimeTelemetrySink)? = nil,
  diagnosticSQLLogSink: (any DiagnosticSQLLogSink)? = nil
) -> UserContext
{
  UserContext(
    actor: "tester",
    queryExecutor: service,
    mutationExecutor: service,
    requestPolicy: RequestPolicy { query in
      var query = query
      let tenant = TeaQLExpression.equal("tenantID", .int(7))
      query.filter = query.filter.map { .and([tenant, $0]) } ?? tenant
      return query
    },
    auditSink: auditSink,
    telemetrySink: telemetrySink,
    diagnosticSQLLogSink: diagnosticSQLLogSink
  )
}

@Test func sqliteIDSpaceIsSharedAcrossRuntimeInstances() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-id-space-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let first = try SQLiteDataService(path: path)
  let second = try SQLiteDataService(path: path)
  try await context(first).ensureSchema(RuntimeModule(name: "saved-widget-first", entities: [SavedWidget.descriptor]))

  let initial = try await first.execute(Mutation(
    kind: .create, entity: SavedWidget.descriptor,
    values: ["name": .string("first")], auditReason: "allocate first ID"))
  let continued = try await second.execute(Mutation(
    kind: .create, entity: SavedWidget.descriptor,
    values: ["name": .string("second")], auditReason: "allocate next ID"))
  #expect(initial.generatedValues["id"] == .int(1))
  #expect(continued.generatedValues["id"] == .int(2))
  try await first.ensureIDFloor(typeName: "SeededWidget", floor: 1001)
  let seededDescriptor = EntityDescriptor(
    name: "SeededWidget", table: "seeded_widget",
    properties: SavedWidget.descriptor.properties)
  try await context(first).ensureSchema(RuntimeModule(name: "seeded-widget", entities: [seededDescriptor]))
  let seeded = try await second.execute(Mutation(
    kind: .create, entity: seededDescriptor,
    values: ["name": .string("after seed")], auditReason: "verify bootstrap floor"))
  #expect(seeded.generatedValues["id"] == .int(1002))

  let ids = try await withThrowingTaskGroup(of: Int64.self) { group in
    for index in 0..<20 {
      let service = index.isMultiple(of: 2) ? first : second
      group.addTask {
        let result = try await service.execute(Mutation(
          kind: .create, entity: SavedWidget.descriptor,
          values: ["name": .string("widget-\(index)")],
          auditReason: "verify concurrent ID allocation"))
        return result.generatedValues["id"]?.int64Value ?? -1
      }
    }
    var values: [Int64] = []
    for try await value in group { values.append(value) }
    return values.sorted()
  }
  #expect(ids == Array(3...22))
}

@Test func auditedLifecycleReturnsAuthoritativeTypedEntity() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-save-result-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "saved-widget-delete", entities: [SavedWidget.descriptor]))
  let context = context(service)

  var widget = SavedWidget(name: "created")
  let created = try await widget.auditAs("create widget").save(context)
  #expect(created.id > 0)
  #expect(created.version == 1)
  #expect(created.name == "created")
  #expect(widget.id == 0)

  widget = created
  widget.updateName("updated")
  let updated = try await widget.auditAs("update widget").save(context)
  #expect(updated.id == created.id)
  #expect(updated.version == 2)
  #expect(updated.name == "updated")

  var deletion = updated
  deletion.markForDeletion()
  let deleted = try await deletion.auditAs("delete widget").save(context)
  #expect(deleted.id == created.id)
  #expect(deleted.version == -3)
  #expect(deleted.name == "updated")
}

@Test func sqliteCapturesParameterizedSafeExecutionEvidence() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-evidence-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "order-relations", entities: [order]))
  let evidence = SQLExecutionEvidenceStore()
  let context = context(service, telemetrySink: evidence)

  _ = try await context.execute(
    Mutation(
      kind: .create, entity: order,
      values: [
        "id": .int(100), "version": .int(1),
        "orderNumber": .string("secret-customer-value"),
        "orderDate": .date(Date()), "tenantID": .int(7),
      ], auditReason: "Seed SQL evidence"))
  var query = SelectQuery(entity: order)
  query.filter = .equal("orderNumber", .string("secret-customer-value"))
  query.comment = "Read SQL evidence fixture"
  query.purpose = "Prove parameterized execution"
  query.tracePath = [
    TraceNode(entity: "Organization", comment: query.comment!, purpose: query.purpose!, level: 2, kind: "relation", name: "Order.organization"),
    TraceNode(entity: "Region", comment: query.comment!, purpose: query.purpose!, level: 3, kind: "relation", name: "Organization.region"),
    TraceNode(entity: "Country", comment: query.comment!, purpose: query.purpose!, level: 4, kind: "relation", name: "Region.country"),
  ]
  _ = try await context.execute(query)

  let entries = await evidence.snapshot()
  #expect(entries.contains { $0.operation == .insert })
  #expect(entries.contains { $0.operation == .select })
  #expect(entries.allSatisfy { !$0.parameterizedSQL.contains("secret-customer-value") })
  #expect(entries.contains { !$0.parameters.isEmpty })
  #expect(entries.contains { $0.debugSQL.contains("'secret-customer-value'") })
  #expect(entries.contains { $0.resultCount != nil })
  #expect(entries.contains { $0.affectedRows != nil })
  let selectEntry = try #require(entries.first { $0.operation == .select })
  #expect(selectEntry.comment == "Read SQL evidence fixture")
  #expect(selectEntry.purpose == "Prove parameterized execution")
  #expect(selectEntry.tracePath.map(\.kind) == [
    "operation", "request", "relation", "relation", "relation", "provider", "sql"
  ])
  let insertEntry = try #require(entries.first { $0.operation == .insert })
  #expect(insertEntry.auditReason == "Seed SQL evidence")

  await evidence.enableSelect()
  #expect(await evidence.snapshot().isEmpty)
  await evidence.enableMutation()
  #expect(await evidence.snapshot().isEmpty)
  await evidence.disable()
  #expect(await evidence.snapshot().isEmpty)
}

@Test func sqliteDiagnosticSQLLogDefaultsOnAndIsValueBearing() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-diagnostic-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "diagnostic", entities: [order]))
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let enabled = context(service, diagnosticSQLLogSink: sink)
  #expect(enabled.querySQLLogEnabled)
  #expect(enabled.mutationSQLLogEnabled)
  _ = try await enabled.execute(Mutation(
    kind: .create, entity: order,
    values: ["id": .int(101), "version": .int(1),
      "orderNumber": .string("O'Brien 学校"), "orderDate": .date(Date()), "tenantID": .int(7)],
    auditReason: "diagnostic SQL fixture"))
  var query = SelectQuery(entity: order)
  query.filter = .equal("orderNumber", .string("O'Brien 学校"))
  query.comment = "what: diagnostic copy paste"
  query.purpose = "why: operator reproduction"
  _ = try await enabled.execute(query)
  let lines = await sink.snapshot()
  #expect(lines.contains { $0.contains("[select]") && $0.contains("O''Brien 学校") })

  var disabled = context(service, diagnosticSQLLogSink: sink)
  disabled.querySQLLogEnabled = false
  #expect(disabled.mutationSQLLogEnabled)
  _ = try await disabled.execute(query)
  #expect(await sink.snapshot().count == lines.count)
}

@Test func sqliteTemporalPreparedAndDebugSQLShareStorageSemantics() async throws {
  let temporal = EntityDescriptor(
    name: "TemporalFixture", table: "temporal_fixture",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "calendarDate", column: "calendar_date", type: .date),
      PropertyDescriptor(name: "localDateTime", column: "local_date_time", type: .localDateTime),
      PropertyDescriptor(name: "instant", column: "instant_ms", type: .timestamp),
      PropertyDescriptor(name: "tenantID", column: "tenant_id", type: .int),
    ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-temporal-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "temporal", entities: [temporal]))
  let evidence = SQLExecutionEvidenceStore()
  let context = context(service, telemetrySink: evidence)

  _ = try await context.execute(Mutation(
    kind: .create, entity: temporal,
    values: [
      "id": .int(1), "version": .int(1), "calendarDate": .calendarDate("2024-02-29"),
      "localDateTime": .localDateTime("2026-08-19 09:30:00.123"),
      "instant": .timestamp(1_787_110_200_123), "tenantID": .int(7),
    ], auditReason: "verify temporal SQLite storage"))
  var query = SelectQuery(entity: temporal)
  query.filter = .equal("id", .int(1))
  query.comment = "Read temporal fixture"
  query.purpose = "Verify temporal round trip"
  let result = try await context.execute(query)

  #expect(result.records[0]["calendarDate"] == .calendarDate("2024-02-29"))
  #expect(result.records[0]["localDateTime"] == .localDateTime("2026-08-19 09:30:00.123"))
  #expect(result.records[0]["instant"] == .timestamp(1_787_110_200_123))
  let entries = await evidence.snapshot()
  #expect(entries.contains { $0.debugSQL.contains("'2024-02-29'") })
  #expect(entries.contains { $0.debugSQL.contains("1787110200123") })
}

@Test func sqliteCountsThePolicyFilteredSetWithoutPagination() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-count-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "order-comments", entities: [order]))
  for id in 1...3 {
    _ = try await service.execute(
      Mutation(
        kind: .create, entity: order,
        values: [
          "id": .int(Int64(id)), "version": .int(1), "orderNumber": .string("A-\(id)"),
          "orderDate": .date(Date()), "tenantID": .int(id == 3 ? 8 : 7),
        ], auditReason: "Seed count fixture"))
  }
  var query = SelectQuery(entity: order)
  query.offset = 1
  query.limit = 1
  query.comment = "List tenant orders"
  query.purpose = "Verify exact filtered total"
  let context = context(service)
  #expect(try await context.execute(query).records.count == 1)
  #expect(try await context.count(query) == 2)
}

@Test func sqliteCreatesSchemaQueriesAuditsAndRejectsStaleVersion() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "order-sql-evidence", entities: [order]))
  let appAudit = RecordingAuditSink()
  let context = context(service, auditSink: appAudit)

  _ = try await context.execute(
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(100), "version": .int(1), "orderNumber": .string("A-100"),
        "orderDate": .date(Date(timeIntervalSince1970: 1_700_000_000)), "tenantID": .int(7),
      ],
      auditReason: "Create order fixture"
    ))
  _ = try await context.execute(
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(200), "version": .int(1), "orderNumber": .string("OTHER"),
        "orderDate": .date(Date(timeIntervalSince1970: 1_700_000_000)), "tenantID": .int(8),
      ],
      auditReason: "Create isolated tenant fixture"
    ))

  var query = SelectQuery(entity: order)
  query.comment = "Search tenant orders"
  query.purpose = "Verify tenant isolation"
  let result = try await context.execute(query)
  #expect(result.records.count == 1)
  #expect(result.records[0]["id"] == .int(100))
  #expect(result.records[0]["orderDate"]?.dateValue != nil)

  _ = try await context.execute(
    Mutation(
      kind: .update,
      entity: order,
      id: .int(100),
      values: ["orderNumber": .string("A-101")],
      expectedVersion: 1,
      auditReason: "Correct order number"
    ))
  await #expect(
    throws: TeaQLError.optimisticLock(entity: "CustomerOrder", id: .int(100), expectedVersion: 1)
  ) {
    try await context.execute(
      Mutation(
        kind: .update,
        entity: order,
        id: .int(100),
        values: ["orderNumber": .string("STALE")],
        expectedVersion: 1,
        auditReason: "Attempt stale update"
      ))
  }

  let deleted = try await context.execute(
    Mutation(
      kind: .delete,
      entity: order,
      id: .int(100),
      expectedVersion: 2,
      auditReason: "Soft delete order"
    ))
  #expect(deleted.generatedValues["version"] == .int(-3))
  var activeQuery = SelectQuery(entity: order)
  activeQuery.filter = .greaterThanOrEqual("version", .int(1))
  activeQuery.comment = "Read active order"
  activeQuery.purpose = "Verify soft-deleted row is hidden"
  #expect(try await context.execute(activeQuery).records.isEmpty)
  var deletedQuery = SelectQuery(entity: order)
  deletedQuery.filter = .lessThanOrEqual("version", .int(-1))
  deletedQuery.comment = "Read deleted order"
  deletedQuery.purpose = "Verify soft-deleted row is retained"
  let deletedRows = try await context.execute(deletedQuery).records
  #expect(deletedRows.count == 1)
  #expect(deletedRows[0]["version"] == .int(-3))
  await #expect(
    throws: TeaQLError.optimisticLock(entity: "CustomerOrder", id: .int(100), expectedVersion: 2)
  ) {
    try await context.execute(
      Mutation(
        kind: .delete,
        entity: order,
        id: .int(100),
        expectedVersion: 2,
        auditReason: "Attempt stale delete"
      ))
  }
  let audit = try await service.auditEvents()
  #expect(audit.count == 4)
  #expect(audit.last?["reason"] == .string("Soft delete order"))
  #expect(await appAudit.events().count == 4)

  _ = try await service.transaction([
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(300), "version": .int(1), "orderNumber": .string("B-300"),
        "orderDate": .date(Date()), "tenantID": .int(7),
      ],
      auditReason: "Create first transaction order"
    ),
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(301), "version": .int(1), "orderNumber": .string("B-301"),
        "orderDate": .date(Date()), "tenantID": .int(7),
      ],
      auditReason: "Create second transaction order"
    ),
  ])
  var transactionQuery = SelectQuery(entity: order)
  transactionQuery.filter = .inList("id", [.int(300), .int(301)])
  transactionQuery.comment = "Read transaction records"
  transactionQuery.purpose = "Verify atomic batch persistence"
  #expect(try await context.execute(transactionQuery).records.count == 2)

  await #expect(throws: (any Error).self) {
    try await service.transaction([
      Mutation(
        kind: .create,
        entity: order,
        values: [
          "id": .int(400), "version": .int(1), "orderNumber": .string("ROLLBACK"),
          "orderDate": .date(Date()), "tenantID": .int(7),
        ],
        auditReason: "Begin rollback test"
      ),
      Mutation(
        kind: .create,
        entity: order,
        values: [
          "id": .int(300), "version": .int(1), "orderNumber": .string("DUPLICATE"),
          "orderDate": .date(Date()), "tenantID": .int(7),
        ],
        auditReason: "Trigger rollback test"
      ),
    ])
  }
  var rollbackQuery = SelectQuery(entity: order)
  rollbackQuery.filter = .equal("id", .int(400))
  rollbackQuery.comment = "Read rolled-back record"
  rollbackQuery.purpose = "Verify failed batch rollback"
  #expect(try await context.execute(rollbackQuery).records.isEmpty)
}
