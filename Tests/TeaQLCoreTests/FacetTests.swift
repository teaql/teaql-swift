import XCTest
@testable import TeaQLCore

private let facetSchool = EntityDescriptor(
  name: "School", table: "school",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "schoolType", type: .int),
  ])

private let facetSchoolType = EntityDescriptor(
  name: "SchoolType", table: "school_type",
  properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])

final class FacetTests: XCTestCase {
  func testFacetCountsAndIncludeAllChoice() async throws {
    let context = UserContext(
      queryExecutor: FacetFixtureExecutor(), mutationExecutor: FacetRejectingMutationExecutor(),
      requestPolicy: RequestPolicy { $0 })
    var nested = SelectQuery(entity: facetSchoolType)
    nested.projection = ["id", "code"]

    var all = SelectQuery(entity: facetSchool)
    all.comment = "load school type facet"
    all.purpose = "verify include-all facet semantics"
    all.facets = [FacetRequest(name: "types", relationName: "schoolType", query: nested)]
    let allFacet = try await context.execute(all).facets["types"]!
    XCTAssertEqual(allFacet.count, 3)
    XCTAssertEqual(allFacet[0]["count"], .int(2))
    XCTAssertEqual(allFacet[1]["count"], .int(0))

    var matched = all
    matched.facets = [FacetRequest(
      name: "types", relationName: "schoolType", query: nested,
      includeAllFacets: false)]
    let matchedFacet = try await context.execute(matched).facets["types"]!
    XCTAssertEqual(matchedFacet.count, 1)
    XCTAssertEqual(matchedFacet[0]["id"], .int(1001))
  }
}

private struct FacetFixtureExecutor: QueryExecutor {
  func execute(_ query: SelectQuery) async throws -> QueryResult {
    switch query.entity.name {
    case "School":
      return QueryResult(records: [
        ["id": .int(1), "schoolType": .int(1001)],
        ["id": .int(2), "schoolType": .int(1001)],
      ], backend: "fixture")
    case "SchoolType":
      return QueryResult(records: [
        ["id": .int(1001), "code": .string("PRIMARY")],
        ["id": .int(1002), "code": .string("SECONDARY")],
        ["id": .int(1003), "code": .string("VOCATIONAL")],
      ], backend: "fixture")
    default: throw TeaQLError.execution("unexpected fixture entity")
    }
  }
}

private struct FacetRejectingMutationExecutor: MutationExecutor {
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    throw TeaQLError.execution("mutation is not part of this test")
  }
}
