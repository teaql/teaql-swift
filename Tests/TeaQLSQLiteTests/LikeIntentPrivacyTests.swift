import Foundation
import Testing
import TeaQLCore
import TeaQLSQL
import TeaQLSQLite

private let likeCanary = "PRIVATE-LIKE-OPERAND"
private let likeOperators = ["contains", "notContains", "startsWith", "notStartsWith", "endsWith", "notEndsWith"]

private func likePredicate(_ operation: String, field: String, operand: String) -> TeaQLExpression {
  switch operation {
  case "contains": return .contains(field, operand)
  case "notContains": return .notContains(field, operand)
  case "startsWith": return .startsWith(field, operand)
  case "notStartsWith": return .notStartsWith(field, operand)
  case "endsWith": return .endsWith(field, operand)
  default: return .notEndsWith(field, operand)
  }
}

private func likeEntity(_ name: String) -> EntityDescriptor {
  EntityDescriptor(name: name, table: "like_" + name.lowercased(), properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "parent_id", type: .int),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "publicName", type: .string),
  ], auditMaskFields: ["name"])
}

private final class LikePolicyCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var queries: [SelectQuery] = []
  func apply(_ query: SelectQuery) -> SelectQuery {
    lock.lock(); defer { lock.unlock() }
    queries.append(query); return query
  }
  func snapshot() -> [SelectQuery] {
    lock.lock(); defer { lock.unlock() }; return queries
  }
}

/// Captures the real provider's returned bindings without changing any request
/// or injecting metadata/trace frames. Used only for descendant execution proof.
private actor LikePhysicalCapture: QueryExecutor, QueryIntentProvenanceExecutor {
  let service: SQLiteDataService
  private var results: [QueryResult] = []
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    let result = try await service.execute(request)
    results.append(result); return result
  }
  func queryIntentProvenance(_ request: QueryRequest) async throws -> SQLExecutionMetadata {
    try await service.queryIntentProvenance(request)
  }
  func snapshot() -> [QueryResult] { results }
}

private func seedLike(_ service: SQLiteDataService, entity: EntityDescriptor, operand: String) async throws {
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  try await context.ensureSchema(RuntimeModule(name: "like-privacy", entities: [entity]))
  for (index, value) in [operand + "-tail", "head-" + operand, "unrelated"].enumerated() {
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(Int64(index + 1)), "parent_id": .int(1),
        "name": .string(value), "publicName": .string(value)], auditReason: "seed LIKE privacy"))
  }
}

@Test(arguments: likeOperators, [false, true])
func swiftLikeOriginalOperandUsesItsFieldPolicy(operation: String, logging: Bool) async throws {
  for field in ["name", "publicName"] {
    let service = try SQLiteDataService(path: ":memory:"), entity = likeEntity("Person")
    try await seedLike(service, entity: entity, operand: likeCanary)
    let evidence = SQLExecutionEvidenceStore(), diagnostics = TextDiagnosticSQLLogSink(writer: { _ in })
    let policy = LikePolicyCapture()
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { policy.apply($0) }, telemetrySink: evidence,
      diagnosticSQLLogSink: diagnostics, querySQLLogEnabled: logging)
    var query = SelectQuery(entity: entity)
    query.filter = likePredicate(operation, field: field, operand: likeCanary)
    query.orderBy = [OrderBy("id", .ascending)]; query.limit = 10
    query.comment = "load \(likeCanary)"; query.purpose = "inspect \(likeCanary)"
    let original = query
    let prefix = operation.lowercased().contains("startswith") ? "" : "%"
    let suffix = operation.lowercased().contains("endswith") ? "" : "%"
    let bound = TeaQLValue.string(prefix + likeCanary + suffix)
    let expected: [TeaQLValue]
    switch operation {
    case "contains": expected = [.int(1), .int(2)]
    case "notContains": expected = [.int(3)]
    case "startsWith": expected = [.int(1)]
    case "notStartsWith": expected = [.int(2), .int(3)]
    case "endsWith": expected = [.int(2)]
    default: expected = [.int(1), .int(3)]
    }
    let result = try await context.execute(query)
    #expect(result.records.compactMap { $0["id"] } == expected)
    let raw = try #require(result.metadata)
    #expect(raw.parameters == [bound, .int(10)])
    #expect(raw.parameterLogPolicies == [field == "name" ? .masked : .plain, .plain])
    #expect(raw.comment == query.comment && raw.purpose == query.purpose)
    #expect(try await context.count(query) == expected.count)
    #expect(try SQLiteCompiler().compileCount(query).parameters == [bound])
    #expect(query == original && policy.snapshot() == [original, original])
    let facts = await evidence.snapshot(), logs = await diagnostics.snapshot()
    #expect(facts.count == 2 && logs.count == (logging ? 2 : 0))
    for fact in facts {
      let visible = field == "name" ? "[REDACTED]" : likeCanary
      #expect(fact.comment == "load \(visible)")
      #expect(fact.purpose == "inspect \(visible)")
      #expect(fact.tracePath.map(\.name) == ["Person", "Person", "sqlite", "select"])
      #expect(fact.executionOutcome == "success")
    }
    if field == "name" {
      #expect(!facts.description.contains(likeCanary))
      #expect(!logs.description.contains(likeCanary))
    } else {
      #expect(facts[0].parameters == raw.parameters)
      if logging { #expect(logs.description.contains(likeCanary)) }
    }
    var independent = SelectQuery(entity: entity)
    independent.limit = 1; independent.comment = "independent \(likeCanary)"
    independent.purpose = "no inherited operand"
    #expect(try await context.execute(independent).records.count == 1)
    #expect(await evidence.snapshot().last?.comment == independent.comment)
  }
}

@Test(arguments: [false, true])
func swiftLikeFutureOperandMasksFirstRootSQL(logging: Bool) async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let parent = likeEntity("Parent"), child = likeEntity("Child")
  try await seedLike(service, entity: parent, operand: "public-parent")
  try await seedLike(service, entity: child, operand: likeCanary)
  let capture = LikePhysicalCapture(service), evidence = SQLExecutionEvidenceStore()
  let diagnostics = TextDiagnosticSQLLogSink(writer: { _ in }), policy = LikePolicyCapture()
  let context = UserContext(queryExecutor: capture, mutationExecutor: service,
    requestPolicy: RequestPolicy { policy.apply($0) }, telemetrySink: evidence,
    diagnosticSQLLogSink: diagnostics, querySQLLogEnabled: logging)
  var children = SelectQuery(entity: child)
  children.filter = .startsWith("name", likeCanary); children.limit = 10
  var query = SelectQuery(entity: parent)
  query.filter = .equal("id", .int(1)); query.limit = 1
  query.relationQuery("children", localKey: "id", foreignKey: "parent_id", query: children)
  query.comment = "load future \(likeCanary)"; query.purpose = "inspect future \(likeCanary)"
  let original = query
  let result = try await context.execute(query)
  guard case .array(let rows) = result.records.first?["children"], case .object(let row) = rows.first else {
    Issue.record("actual loaded child missing"); return
  }
  #expect(rows.count == 1 && row["name"] == .string(likeCanary + "-tail"))
  let raw = await capture.snapshot().compactMap(\.metadata)
  #expect(raw.count == 2)
  #expect(raw[0].parameters == [.int(1), .int(1)])
  #expect(raw[1].parameters.contains(.string(likeCanary + "%")))
  #expect(raw[1].parameterLogPolicies.first == .masked)
  #expect(raw.allSatisfy { $0.comment == original.comment && $0.purpose == original.purpose })
  #expect(query == original && policy.snapshot().allSatisfy {
    $0.comment == original.comment && $0.purpose == original.purpose
  })
  let facts = await evidence.snapshot(), logs = await diagnostics.snapshot()
  #expect(facts.count == 2 && logs.count == (logging ? 2 : 0))
  #expect(facts.map { $0.tracePath.filter { $0.kind == "relation" }.map(\.name) } == [[], ["children"]])
  for fact in facts {
    #expect(fact.comment == "load future [REDACTED]")
    #expect(fact.purpose == "inspect future [REDACTED]")
    #expect(fact.tracePath.first?.name == "Parent")
  }
  #expect(!facts.description.contains(likeCanary) && !logs.description.contains(likeCanary))
  var independent = SelectQuery(entity: parent)
  independent.limit = 1; independent.comment = "independent \(likeCanary)"; independent.purpose = "isolation"
  _ = try await context.execute(independent)
  #expect(await evidence.snapshot().last?.comment == independent.comment)
}

@Test(arguments: [false, true])
func swiftLikeLiteralWildcardsAreNotStripped(logging: Bool) async throws {
  let operand = "%LITERAL_WILDCARD%\\"
  let service = try SQLiteDataService(path: ":memory:"), entity = likeEntity("Literal")
  try await seedLike(service, entity: entity, operand: operand)
  for equal in [false, true] {
    let value = equal ? operand + "-tail" : operand
    let evidence = SQLExecutionEvidenceStore(), diagnostics = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
      diagnosticSQLLogSink: diagnostics, querySQLLogEnabled: logging)
    var query = SelectQuery(entity: entity)
    query.filter = equal ? .equal("name", .string(value)) : .startsWith("name", value)
    query.limit = 10; query.comment = "private \(value); public LITERAL_WILDCARD"
    query.purpose = "preserve exact operand"
    let original = query
    let result = try await context.execute(query)
    // The literal leading '%' is still a SQL wildcard; no escape semantics change.
    #expect(result.records.count == (equal ? 1 : 2))
    #expect(result.metadata?.parameters == [.string(equal ? value : value + "%"), .int(10)])
    #expect(await evidence.snapshot().first?.comment == "private [REDACTED]; public LITERAL_WILDCARD")
    let logs = await diagnostics.snapshot()
    #expect(logs.count == (logging ? 1 : 0))
    if logging {
      #expect(logs[0].contains("public LITERAL_WILDCARD"))
      #expect(!logs[0].contains(value))
    }
    #expect(query == original)
  }
}
