import Foundation
import XCTest
@testable import TeaQLCore

final class QueryRequestTreeTests: XCTestCase {
  private let school = EntityDescriptor(name: "School", table: "school", properties: [])
  private let type = EntityDescriptor(name: "SchoolType", table: "school_type", properties: [])

  func testNativeOperationsAndReusableAttachmentsHaveIndependentParents() throws {
    var child = SelectQuery(entity: type); child.comment = "load visible types"
    func parent(_ comment: String) throws -> QueryRequest {
      var query = SelectQuery(entity: school); query.comment = comment; query.purpose = "render schools"
      query.relationQuery("schoolTypeEntity", localKey: "schoolType", foreignKey: "id", many: false,
        query: child, operation: QueryOperation("relation", method: "selectSchoolTypeWith"))
      return try QueryRequest(query: query)
    }
    let first = try parent("first page"), second = try parent("second page")
    let left = try XCTUnwrap(first.query.relations[0].query.makeQuery().requestScope)
    let right = try XCTUnwrap(second.query.relations[0].query.makeQuery().requestScope)
    XCTAssertTrue(left.root === first.scope); XCTAssertTrue(right.root === second.scope)
    XCTAssertFalse(left === right)
    XCTAssertEqual(left.recover().map(\.comment), ["render schools", "first page", "selectSchoolTypeWith(...)", "load visible types"])
    XCTAssertNil(child.requestScope)
    XCTAssertEqual(child.comment, "load visible types")
    var clone = first.query; clone.comment = "untrusted replacement"; clone.limit = 3
    XCTAssertEqual(first.withQuery(clone).intent.comment, "first page")
    XCTAssertTrue(first.withQuery(clone).scope === first.scope)
    XCTAssertThrowsError(try first.withQuery(second.query).bindingTree())
  }

  func testMissingChildDefaultsButExplicitBlankAndMissingRootReject() throws {
    var query = SelectQuery(entity: school); query.comment = "load schools"; query.purpose = "render schools"
    var child = SelectQuery(entity: type)
    query.relationQuery("schoolType", localKey: "schoolType", foreignKey: "id", many: false, query: child,
      operation: QueryOperation("relation", method: "selectSchoolTypeWith"))
    let request = try QueryRequest(query: query)
    XCTAssertEqual(request.query.relations[0].query.comment, "load SchoolType")
    for blank in ["", " \t", "\u{0085}"] {
      child.comment = blank; query.relations = []
      query.relationQuery("schoolType", localKey: "schoolType", foreignKey: "id", many: false, query: child)
      XCTAssertThrowsError(try QueryRequest(query: query))
    }
    query.comment = nil
    XCTAssertThrowsError(try QueryRequest(query: query))
  }

  func testUnrelatedInvocationRejectsEvenWithIdenticalIntent() throws {
    var query = SelectQuery(entity: school); query.comment = "same comment"; query.purpose = "same purpose"
    let first = try QueryRequest(query: query), second = try QueryRequest(query: query)
    XCTAssertThrowsError(try first.withQuery(second.query).bindingTree())
    let ownCopy = try first.withQuery(first.query).bindingTree()
    XCTAssertTrue(try ownCopy.withQuery(first.query).bindingTree().scope === first.scope)
    XCTAssertThrowsError(try ownCopy.withQuery(second.query).bindingTree())
  }

  func testFacetBranchesShareOperationAndHeadersAreNotWireFields() throws {
    var aggregate = SelectQuery(entity: school)
    aggregate.aggregates = [QueryAggregate(.sum, field: "capacity", alias: "sumCapacity")]
    var child = SelectQuery(entity: type); child.comment = "load types"
    child.relationAggregate("schools", foreignKey: "schoolType", alias: "sumCapacity", query: aggregate)
    var query = SelectQuery(entity: school); query.comment = "what: load schools"; query.purpose = "why: render schools"
    query.pageCountOperation = QueryOperation("count", method: "countAs", alias: "a\"\\\n")
    query.facets = [FacetRequest(name: "types", relationName: "schoolType", query: child,
      operation: QueryOperation("facet", method: "facetBySchoolTypeAs", alias: "types", relation: "schoolType"))]
    let request = try QueryRequest(query: query)
    let value = try XCTUnwrap(request.query.facets[0].query.requestScope)
    let sum = try XCTUnwrap(request.query.facets[0].query.makeQuery().relationAggregates[0].query.requestScope)
    XCTAssertTrue(value.parent === sum.parent)
    XCTAssertEqual(sum.comment, "aggregate schoolType")
    XCTAssertEqual(value.recover().map(\.comment), ["why: render schools", "what: load schools", "facetBySchoolTypeAs(\"types\")", "load types"])
    XCTAssertEqual(query.pageCountOperation?.comment, "countAs(\"a\\\"\\\\\\n\")")
    let json = String(decoding: try JSONEncoder().encode(request.query), as: UTF8.self)
    XCTAssertFalse(json.contains("requestScope")); XCTAssertFalse(json.contains("pageCountOperation"))
    XCTAssertFalse(json.contains("facetBySchoolTypeAs"))
    let decoded = try JSONDecoder().decode(SelectQuery.self, from: Data(json.utf8))
    XCTAssertNil(decoded.requestScope); XCTAssertNil(decoded.pageCountOperation)
  }

  func testFacetAggregateExplicitCommentIsPreservedAndBlankIsRejected() throws {
    for comment in ["sum visible capacity", "", " \t", "\u{0085}"] {
      var aggregate = SelectQuery(entity: school)
      aggregate.comment = comment
      aggregate.aggregates = [QueryAggregate(.sum, field: "capacity", alias: "sumCapacity")]
      var child = SelectQuery(entity: type); child.comment = "load types"
      child.relationAggregate("schools", foreignKey: "schoolType", alias: "sumCapacity", query: aggregate)
      var query = SelectQuery(entity: school); query.comment = "load schools"; query.purpose = "render schools"
      query.facets = [FacetRequest(name: "types", relationName: "schoolType", query: child,
        operation: QueryOperation("facet", method: "facetBySchoolTypeAs", alias: "types", relation: "schoolType"))]
      if comment == "sum visible capacity" {
        let request = try QueryRequest(query: query)
        let scope = try XCTUnwrap(request.query.facets[0].query.makeQuery().relationAggregates[0].query.requestScope)
        XCTAssertEqual(scope.recover().map(\.comment), ["render schools", "load schools",
          "facetBySchoolTypeAs(\"types\")", "aggregate schoolType", "sum visible capacity"])
        XCTAssertEqual(scope.comment, comment)
      } else {
        XCTAssertThrowsError(try QueryRequest(query: query)) { error in
          XCTAssertEqual((error as? RequestIntentError)?.field, "comment")
        }
      }
    }
  }
}
