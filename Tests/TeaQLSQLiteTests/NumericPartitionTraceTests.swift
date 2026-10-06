import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

private let numericOperands = ["%NUMERIC_FIRST_", "%NUMERIC_SECOND_"]

private final class NumericPolicyCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var queries: [SelectQuery] = []
  func apply(_ query: SelectQuery) -> SelectQuery {
    lock.withLock { queries.append(query) }; return query
  }
  func snapshot() -> [SelectQuery] { lock.withLock { queries } }
  func clear() { lock.withLock { queries.removeAll() } }
}

/// Observes real SQLite results/bindings and preserves its existing probe policy.
/// Provenance compilation is counted separately from physical query execution.
private actor NumericPhysicalCapture: QueryExecutor, QueryIntentProvenanceExecutor, RelationTopNPlanning {
  let service: SQLiteDataService
  nonisolated var relationTopNPolicy: RelationTopNPolicy { service.relationTopNPolicy }
  private var results: [QueryResult] = []
  private var executions = 0, provenanceCompilations = 0
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    executions += 1
    let result = try await service.execute(request)
    results.append(result); return result
  }
  func queryIntentProvenance(_ request: QueryRequest) async throws -> SQLExecutionMetadata {
    provenanceCompilations += 1
    return try await service.queryIntentProvenance(request)
  }
  func snapshot() -> (raw: [SQLExecutionMetadata], executions: Int, compilations: Int) {
    (results.compactMap(\.metadata), executions, provenanceCompilations)
  }
  func clear() { results.removeAll(); executions = 0; provenanceCompilations = 0 }
}

private actor NumericDiagnostics: DiagnosticSQLLogSink {
  private var facts: [SQLExecutionMetadata] = []
  func write(_ metadata: SQLExecutionMetadata) { facts.append(metadata) }
  func snapshot() -> [SQLExecutionMetadata] { facts }
  func clear() { facts.removeAll() }
}

private struct NumericFixture {
  let service: SQLiteDataService, parent: EntityDescriptor, item: EntityDescriptor
  static func make() async throws -> Self {
    let parent = EntityDescriptor(name: "NumericParent", table: "numeric_parent", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])
    let item = EntityDescriptor(name: "NumericItem", table: "numeric_item", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "parent_id", type: .int),
      PropertyDescriptor(name: "bucket", type: .int), // Not a model relation.
      PropertyDescriptor(name: "name", type: .string),
      PropertyDescriptor(name: "publicName", type: .string),
    ], auditMaskFields: ["name"])
    let service = try SQLiteDataService(path: ":memory:")
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(RuntimeModule(name: "numeric-partition", entities: [parent, item]))
    for id in [Int64(1), 2] {
      _ = try await context.execute(Mutation(kind: .create, entity: parent,
        values: ["id": .int(id)], auditReason: "seed numeric partition parent"))
    }
    for (index, operand) in numericOperands.enumerated() {
      for (id, owner, bucket) in [(Int64(11), Int64(1), Int64(10)), (12, 1, 10), (21, 2, 20)] {
        let actualID = id + Int64(index * 20), value = operand + "value-\(id)"
        _ = try await context.execute(Mutation(kind: .create, entity: item, values: [
          "id": .int(actualID), "parent_id": .int(owner), "bucket": .int(bucket),
          "name": .string(value), "publicName": .string(value),
        ], auditReason: "seed numeric partition item"))
      }
    }
    return Self(service: service, parent: parent, item: item)
  }
}

private func numericQuery(_ entity: EntityDescriptor, field: String, operand: String, unrelated: String) -> SelectQuery {
  var query = SelectQuery(entity: entity)
  query.filter = .startsWith(field, operand)
  query.comment = "load \(operand); unrelated \(unrelated)"
  query.purpose = "count \(operand); unrelated \(unrelated)"
  return query
}

private func assertNumericPath(_ fact: SQLExecutionMetadata, root: String, relations: [String]) {
  let kinds: [String] = ["operation", "request"] + relations.map { _ in "relation" } + ["provider", "sql"]
  let names: [String] = [root, root] + relations + ["sqlite", "select"]
  #expect(fact.tracePath.map(\.kind) == kinds)
  #expect(fact.tracePath.map(\.name) == names)
  #expect(fact.tracePath.map(\.level) == Array(fact.tracePath.indices))
  #expect(!fact.tracePath.contains { $0.kind == "relation" && ["bucket", "parent_id"].contains($0.name) })
  #expect(fact.executionOutcome == "success" && fact.operation == .select)
}

private func assertNumericPrivacy(_ fact: SQLExecutionMetadata, original: SelectQuery, operand: String, marked: Bool) {
  #expect(fact.comment == (marked ? original.comment?.replacingOccurrences(of: operand, with: "[REDACTED]") : original.comment))
  #expect(fact.purpose == (marked ? original.purpose?.replacingOccurrences(of: operand, with: "[REDACTED]") : original.purpose))
  if marked { #expect(!String(describing: fact).contains(operand)) }
}

@Test(arguments: ["name", "publicName"], [false, true])
func swiftNumericGroupingAndPartitionDoNotInventRelationEdges(field: String, logging: Bool) async throws {
  let fixture = try await NumericFixture.make(), evidence = SQLExecutionEvidenceStore()
  let capture = NumericPhysicalCapture(fixture.service), diagnostics = NumericDiagnostics(), policy = NumericPolicyCapture()
  let context = UserContext(queryExecutor: capture, mutationExecutor: fixture.service,
    requestPolicy: RequestPolicy { policy.apply($0) }, telemetrySink: evidence,
    diagnosticSQLLogSink: diagnostics, querySQLLogEnabled: logging)
  for (index, operand) in numericOperands.enumerated() {
    var grouped = numericQuery(fixture.item, field: field, operand: operand, unrelated: numericOperands[1 - index])
    grouped.groupBy = ["bucket"]; grouped.aggregates = [QueryAggregate(.count, field: "*", alias: "rowCount")]
    grouped.orderBy = [OrderBy("bucket", .ascending)]; grouped.limit = 10
    let original = grouped
    await evidence.enableAll(); await diagnostics.clear(); await capture.clear(); policy.clear()
    let result = try await context.execute(grouped)
    let expectedGroups: [TeaQLRecord] = [["bucket": .int(10), "rowCount": .int(2)], ["bucket": .int(20), "rowCount": .int(1)]]
    #expect(result.records == expectedGroups)
    let rawGroup = try #require(result.metadata)
    #expect(rawGroup.parameterizedSQL.contains("GROUP BY \"bucket\""))
    #expect(rawGroup.parameters == [.string(operand + "%"), .int(10)])

    var window = numericQuery(fixture.item, field: field, operand: operand, unrelated: numericOperands[1 - index])
    window.projection = ["id", "version", "bucket", field]
    window.partitionBy = "bucket"; window.offset = 1; window.limit = 1
    window.orderBy = [OrderBy("id", .ascending)]
    let originalWindow = window
    let partitioned = try await context.execute(window)
    #expect(partitioned.records.count == 1 && partitioned.records[0]["id"] == .int(12 + Int64(index * 20)))
    #expect(partitioned.records[0]["bucket"] == .int(10))
    let rawWindow = try #require(partitioned.metadata)
    #expect(rawWindow.parameterizedSQL.contains("ROW_NUMBER() OVER (PARTITION BY \"bucket\""))
    #expect(rawWindow.parameters == [.string(operand + "%"), .int(1), .int(2)])
    #expect(rawWindow.parameterLogPolicies == [field == "name" ? .masked : .plain, .plain, .plain])
    #expect(grouped == original && window == originalWindow && original.tracePath.isEmpty && window.tracePath.isEmpty)
    #expect(policy.snapshot() == [original, originalWindow])
    let raw = await capture.snapshot(), facts = await evidence.snapshot(), logs = await diagnostics.snapshot()
    #expect(raw.executions == 2 && raw.raw.count == 2 && facts.count == 2 && logs.count == (logging ? 2 : 0))
    for value in raw.raw {
      #expect(value.comment == original.comment && value.purpose == original.purpose)
      assertNumericPath(value, root: "NumericItem", relations: [])
    }
    for fact in facts + logs {
      assertNumericPath(fact, root: "NumericItem", relations: [])
      assertNumericPrivacy(fact, original: original, operand: operand, marked: field == "name")
    }
    print("NUMERIC_ROOT field=\(field) logging=\(logging) current=\(operand) counts=2,1 windowID=\(12 + index * 20) rawBindings=\(raw.raw.map(\.parameters)) safeComments=\(facts.map(\.comment)) paths=\(facts.map { $0.tracePath.map(\.name) })")
  }
  var independent = SelectQuery(entity: fixture.parent)
  independent.limit = 1; independent.comment = "independent " + numericOperands.joined(separator: " ")
  independent.purpose = "no inherited numeric partition or redaction"
  #expect(try await context.execute(independent).records.count == 1)
  let last = try #require(await evidence.snapshot().last)
  #expect(last.comment == independent.comment && last.purpose == independent.purpose)
  assertNumericPath(last, root: "NumericParent", relations: [])
}

@Test(arguments: ["name", "publicName"], [false, true])
func swiftNumericLoadedGroupingKeepsOnlyTheActualRelationEdge(field: String, logging: Bool) async throws {
  let fixture = try await NumericFixture.make(), capture = NumericPhysicalCapture(fixture.service)
  let evidence = SQLExecutionEvidenceStore(), diagnostics = NumericDiagnostics(), policy = NumericPolicyCapture()
  let context = UserContext(queryExecutor: capture, mutationExecutor: fixture.service,
    requestPolicy: RequestPolicy { policy.apply($0) }, telemetrySink: evidence,
    diagnosticSQLLogSink: diagnostics, querySQLLogEnabled: logging)
  for (index, operand) in numericOperands.enumerated() {
    var child = SelectQuery(entity: fixture.item)
    child.filter = .startsWith(field, operand); child.groupBy = ["parent_id", "bucket"]
    child.aggregates = [QueryAggregate(.count, field: "*", alias: "rowCount")]; child.limit = 10
    var query = SelectQuery(entity: fixture.parent)
    query.limit = 2; query.orderBy = [OrderBy("id", .ascending)]
    query.relationQuery("items", localKey: "id", foreignKey: "parent_id", query: child)
    query.comment = "load future \(operand); unrelated \(numericOperands[1 - index])"
    query.purpose = "group future \(operand); unrelated \(numericOperands[1 - index])"
    let original = query
    await capture.clear(); await evidence.enableAll(); await diagnostics.clear(); policy.clear()
    let result = try await context.execute(query)
    #expect(result.records.count == 2)
    for (offset, parent) in result.records.enumerated() {
      let expected: TeaQLRecord = ["parent_id": .int(Int64(offset + 1)), "bucket": .int(Int64((offset + 1) * 10)),
        "rowCount": .int(offset == 0 ? 2 : 1)]
      #expect(parent["items"] == .array([.object(expected)]))
    }
    let raw = await capture.snapshot(), facts = await evidence.snapshot(), logs = await diagnostics.snapshot()
    #expect(raw.executions == 3 && raw.raw.count == 3 && facts.count == 3 && logs.count == (logging ? 3 : 0))
    #expect(raw.raw[0].parameters == [.int(2)])
    for (offset, value) in raw.raw.dropFirst().enumerated() {
      #expect(value.parameters == [.string(operand + "%"), .int(Int64(offset + 1)), .int(10)])
      #expect(value.parameterizedSQL.contains("GROUP BY \"parent_id\", \"bucket\""))
      #expect(!value.parameterizedSQL.contains("PARTITION BY")) // Real SQLite bounded probes, not window aggregation.
    }
    #expect(query == original && query.tracePath.isEmpty && child.tracePath.isEmpty)
    #expect(policy.snapshot().first == original && policy.snapshot().count == 3)
    #expect(policy.snapshot().allSatisfy { $0.comment == original.comment && $0.purpose == original.purpose })
    for (offset, value) in raw.raw.enumerated() {
      #expect(value.comment == original.comment && value.purpose == original.purpose)
      assertNumericPath(value, root: "NumericParent", relations: offset == 0 ? [] : ["items"])
    }
    for (offset, fact) in facts.enumerated() {
      assertNumericPath(fact, root: "NumericParent", relations: offset == 0 ? [] : ["items"])
      assertNumericPrivacy(fact, original: original, operand: operand, marked: field == "name")
    }
    for fact in logs { assertNumericPrivacy(fact, original: original, operand: operand, marked: field == "name") }
    print("NUMERIC_LOADED field=\(field) logging=\(logging) current=\(operand) counts=2,1 rawBindings=\(raw.raw.map(\.parameters)) safeComments=\(facts.map(\.comment)) paths=\(facts.map { $0.tracePath.map(\.name) })")
  }
  var independent = SelectQuery(entity: fixture.parent)
  independent.limit = 1; independent.comment = "independent " + numericOperands.joined(separator: " ")
  independent.purpose = "no inherited descendant scope"
  #expect(try await context.execute(independent).records.count == 1)
  let last = try #require(await evidence.snapshot().last)
  #expect(last.comment == independent.comment)
  assertNumericPath(last, root: "NumericParent", relations: [])
}

@Test(arguments: [false, true])
func swiftNumericGroupedBoundedPartitionRemainsExplicitlyUnsupported(logging: Bool) async throws {
  let fixture = try await NumericFixture.make(), capture = NumericPhysicalCapture(fixture.service)
  let evidence = SQLExecutionEvidenceStore(), diagnostics = NumericDiagnostics(), policy = NumericPolicyCapture()
  let context = UserContext(queryExecutor: capture, mutationExecutor: fixture.service,
    requestPolicy: RequestPolicy { policy.apply($0) }, telemetrySink: evidence,
    diagnosticSQLLogSink: diagnostics, querySQLLogEnabled: logging)
  var valid = numericQuery(fixture.item, field: "name", operand: numericOperands[0], unrelated: numericOperands[1])
  valid.partitionBy = "bucket"; valid.limit = 1; valid.orderBy = [OrderBy("id", .ascending)]
  let expectedIDs: Set<TeaQLValue> = [.int(11), .int(21)]
  let before = try await context.execute(valid)
  #expect(Set(before.records.compactMap { $0["id"] }) == expectedIDs)
  for shape in ["group", "aggregate", "both"] {
    var unsupported = valid
    if shape != "aggregate" { unsupported.groupBy = ["bucket"] }
    if shape != "group" { unsupported.aggregates = [QueryAggregate(.count, field: "*", alias: "rowCount")] }
    let original = unsupported
    await capture.clear(); await evidence.enableAll(); await diagnostics.clear(); policy.clear()
    do {
      _ = try await context.execute(unsupported)
      Issue.record("unsupported aggregate/group window was silently accepted")
    } catch let error as TeaQLError {
      #expect(error == .unsupportedQueryCapability("Per-parent relation limits cannot be combined with aggregate/group queries"))
    }
    let rejected = await capture.snapshot()
    #expect(rejected.executions == 0 && rejected.raw.isEmpty && rejected.compilations == 1)
    #expect(await evidence.snapshot().isEmpty)
    #expect(await diagnostics.snapshot().isEmpty)
    #expect(unsupported == original && policy.snapshot() == [original])
    let result = try await context.execute(valid)
    #expect(Set(result.records.compactMap { $0["id"] }) == expectedIDs)
    let raw = try #require(result.metadata), fact = try #require(await evidence.snapshot().last)
    #expect(raw.parameters == [.string(numericOperands[0] + "%"), .int(0), .int(1)])
    assertNumericPath(fact, root: "NumericItem", relations: [])
    assertNumericPrivacy(fact, original: valid, operand: numericOperands[0], marked: true)
    #expect(await diagnostics.snapshot().count == (logging ? 1 : 0))
    print("NUMERIC_UNSUPPORTED logging=\(logging) shape=\(shape) typedRejection=true executeCalls=0 provenanceCompiles=1 recoveredIDs=11,21")
  }
}
