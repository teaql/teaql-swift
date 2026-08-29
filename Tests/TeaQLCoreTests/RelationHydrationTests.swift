import XCTest
@testable import TeaQLCore

private let parentDescriptor = EntityDescriptor(
  name: "Parent", table: "parent",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "organization", type: .int),
  ])

private let childDescriptor = EntityDescriptor(
  name: "Child", table: "child",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "parent", type: .int),
  ])

final class RelationHydrationTests: XCTestCase {
  func testBatchesForwardAndReverseRelations() async throws {
    let context = UserContext(
      queryExecutor: RelationFixtureExecutor(),
      mutationExecutor: RejectingMutationExecutor(),
      requestPolicy: RequestPolicy { $0 })

    var organization = SelectQuery(entity: childDescriptor)
    organization.projection = ["displayName"]
    let children = SelectQuery(entity: childDescriptor)
    var parent = SelectQuery(entity: parentDescriptor)
    parent.comment = "Load parent graph"
    parent.purpose = "Verify batched relation hydration"
    parent.relationQuery(
      "organizationRecord", localKey: "organization", foreignKey: "id", many: false,
      query: organization)
    parent.relationQuery(
      "childList", localKey: "id", foreignKey: "parent", query: children)

    let records = try await context.execute(parent).records

    guard case .object(let organizationRecord) = records[0]["organizationRecord"] else {
      return XCTFail("forward relation was not hydrated")
    }
    XCTAssertEqual(organizationRecord["id"], .int(9))
    guard case .array(let childList) = records[0]["childList"] else {
      return XCTFail("reverse relation was not hydrated")
    }
    XCTAssertEqual(childList.count, 2)
  }

  func testBatchesRelationAggregatesAndAppliesEmptySemantics() async throws {
    let executor = RelationAggregateFixtureExecutor()
    let context = UserContext(
      queryExecutor: executor,
      mutationExecutor: RejectingMutationExecutor(),
      requestPolicy: RequestPolicy { $0 })
    var countChildren = SelectQuery(entity: childDescriptor)
    countChildren.aggregates = [QueryAggregate(.count, field: "id", alias: "recordCount")]
    var sumChildren = SelectQuery(entity: childDescriptor)
    sumChildren.aggregates = [QueryAggregate(.sum, field: "id", alias: "integerTotal")]
    var parent = SelectQuery(entity: parentDescriptor)
    parent.comment = "Load relation aggregates"
    parent.purpose = "Verify one batched child query per aggregate"
    parent.relationAggregate(
      "childList", foreignKey: "parent", alias: "recordCount", query: countChildren)
    parent.relationAggregate(
      "childList", foreignKey: "parent", alias: "integerTotal", query: sumChildren)

    let records = try await context.execute(parent).records

    XCTAssertEqual(records[0]["recordCount"], .int(2))
    XCTAssertEqual(records[0]["integerTotal"], .int(42))
    XCTAssertEqual(records[1]["recordCount"], .int(0))
    XCTAssertEqual(records[1]["integerTotal"], .null)
    let aggregateQueryCount = await executor.aggregateQueries()
    XCTAssertEqual(aggregateQueryCount, 2)
  }

  func testLimitedReverseRelationIsPartitionedPerParent() async throws {
    let executor = TopNRelationFixtureExecutor()
    let context = UserContext(
      queryExecutor: executor,
      mutationExecutor: RejectingMutationExecutor(),
      requestPolicy: RequestPolicy { $0 })
    var children = SelectQuery(entity: childDescriptor)
    children.orderBy = [OrderBy("id", .descending)]
    children.limit = 1
    children.topNProbeParentThreshold = 0
    var parent = SelectQuery(entity: parentDescriptor)
    parent.comment = "Load recent child per parent"
    parent.purpose = "Verify relation limit is partitioned"
    parent.relationQuery(
      "childList", localKey: "id", foreignKey: "parent", query: children)

    let records = try await context.execute(parent).records

    guard case .array(let first) = records[0]["childList"],
      case .array(let second) = records[1]["childList"]
    else { return XCTFail("limited relations were not hydrated") }
    func ids(_ values: [TeaQLValue]) -> [TeaQLValue] {
      values.compactMap { value in
        guard case .object(let record) = value else { return nil }
        return record["id"]
      }
    }
    XCTAssertEqual(ids(first), [TeaQLValue.int(12)])
    XCTAssertEqual(ids(second), [TeaQLValue.int(22)])
    let usedPartitionedLimit = await executor.usedPartitionedLimit()
    XCTAssertTrue(usedPartitionedLimit)
  }

  func testSQLitePolicyUsesBoundedProbesAtThresholdAndKeepsEmptyRelation() async throws {
    let executor = TopNRelationFixtureExecutor()
    let telemetry = TopNTelemetry()
    let context = UserContext(
      queryExecutor: executor, mutationExecutor: RejectingMutationExecutor(),
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: telemetry)
    var children = SelectQuery(entity: childDescriptor)
    children.orderBy = [OrderBy("name", .descending)]
    children.limit = 1
    children.topNProbeParentThreshold = 3
    var parent = SelectQuery(entity: parentDescriptor)
    parent.comment = "Load bounded child probes"
    parent.purpose = "Verify provider Top-N policy"
    parent.relationQuery("childList", localKey: "id", foreignKey: "parent", query: children)

    let records = try await context.execute(parent).records
    let repeated = try await context.execute(parent).records
    let childQueryCount = await executor.childQueryCount()
    XCTAssertEqual(childQueryCount, 6)
    XCTAssertEqual(records, repeated)
    guard case .array(let empty) = records[2]["childList"] else {
      return XCTFail("empty relation was not attached")
    }
    XCTAssertTrue(empty.isEmpty)
    let relationEvent = telemetry.events.first { $0.0.family == "relation_load" }
    XCTAssertEqual(relationEvent?.1["teaql.relation.selected_plan"], .string("bounded_probes"))
    XCTAssertEqual(relationEvent?.1["teaql.relation.parent_count"], .integer(3))
    XCTAssertEqual(relationEvent?.1["teaql.relation.probe_count"], .integer(3))
  }
}

private final class TopNTelemetry: RuntimeTelemetry, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [(RuntimeOperation, [String: RuntimeTelemetryValue])] = []
  var events: [(RuntimeOperation, [String: RuntimeTelemetryValue])] { lock.withLock { stored } }
  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    let result = try await body()
    lock.withLock { stored.append((operation, completion(result))) }
    return result
  }
  func withSynchronousOperation<Result>(
    _ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result
  ) rethrows -> Result { try body() }
  func flush() async {}
  func shutdown() async {}
}

private actor TopNRelationFixtureExecutor: QueryExecutor, RelationTopNPlanning {
  nonisolated let relationTopNPolicy: RelationTopNPolicy = .alwaysProbe
  private var partitioned = false
  private var childQueries = 0

  func usedPartitionedLimit() -> Bool { partitioned }
  func childQueryCount() -> Int { childQueries }

  func execute(_ query: SelectQuery) async throws -> QueryResult {
    if query.entity.name == "Parent" {
      return QueryResult(records: [["id": .int(1)], ["id": .int(2)], ["id": .int(3)]], backend: "fixture")
    }
    childQueries += 1
    if query.partitionBy == "parent" {
      guard query.limit == 1, query.orderBy == [OrderBy("id", .descending)] else {
        throw TeaQLError.execution("limited relation did not retain its window plan")
      }
      partitioned = true
      return QueryResult(
        records: [
          ["id": .int(12), "parent": .int(1)],
          ["id": .int(22), "parent": .int(2)],
        ], backend: "fixture")
    }
    guard case .equal("parent", let parentID) = query.filter, query.limit == 1,
      query.orderBy == [OrderBy("name", .descending), OrderBy("id", .ascending)]
    else { throw TeaQLError.execution("bounded probe did not retain filter/order/limit") }
    return QueryResult(
      records: parentID == .int(3) ? [] : [["id": .int(parentID == .int(1) ? 12 : 22), "parent": parentID]],
      backend: "fixture")
  }
}

private actor RelationAggregateFixtureExecutor: QueryExecutor {
  private var queries = 0

  func aggregateQueries() -> Int { queries }

  func execute(_ query: SelectQuery) async throws -> QueryResult {
    if query.entity.name == "Parent" {
      return QueryResult(records: [["id": .int(1)], ["id": .int(2)]], backend: "fixture")
    }
    queries += 1
    guard case .inList("parent", [.int(1), .int(2)]) = query.filter,
      query.groupBy == ["parent"], let aggregate = query.aggregates.first
    else {
      throw TeaQLError.execution("relation aggregate was not expressed as one grouped IN query")
    }
    return QueryResult(
      records: [["parent": .int(1), aggregate.alias: .int(aggregate.function == .count ? 2 : 42)]],
      backend: "fixture")
  }
}

private actor RelationFixtureExecutor: QueryExecutor {
  private var childQueries = 0

  func execute(_ query: SelectQuery) async throws -> QueryResult {
    if query.entity.name == "Parent" {
      return QueryResult(records: [["id": .int(1), "organization": .int(9)]], backend: "fixture")
    }
    childQueries += 1
    switch query.filter {
    case .inList("id", [.int(9)]):
      guard query.projection.contains("id") else {
        throw TeaQLError.execution("relation foreign key was dropped from child projection")
      }
      return QueryResult(records: [["id": .int(9)]], backend: "fixture")
    case .inList("parent", [.int(1)]):
      return QueryResult(
        records: [["id": .int(10), "parent": .int(1)], ["id": .int(11), "parent": .int(1)]],
        backend: "fixture")
    default:
      throw TeaQLError.execution("relation was not expressed as one batched IN query")
    }
  }
}

private struct RejectingMutationExecutor: MutationExecutor {
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    throw TeaQLError.execution("mutation is not part of this test")
  }
}
