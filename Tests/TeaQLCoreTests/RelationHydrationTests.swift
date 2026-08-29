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
