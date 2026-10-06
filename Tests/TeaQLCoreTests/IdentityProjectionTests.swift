import XCTest
@testable import TeaQLCore

final class IdentityProjectionTests: XCTestCase {
  private let entity = EntityDescriptor(name: "Invoice", table: "invoice", properties: [
    PropertyDescriptor(name: "rowId", type: .int, isID: true),
    PropertyDescriptor(name: "revision", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "platform", type: .int),
  ])

  func testPartialEntityProjectionPreservesTypedIdentityAndRelationKey() throws {
    var query = SelectQuery(entity: entity)
    query.projection = ["name"]; query.comment = "read invoice"; query.purpose = "render partial view"
    query.relationQuery("platformEntity", localKey: "platform", foreignKey: "rowId", many: false, query: SelectQuery(entity: entity))
    let validated = try query.validatedForExecution()
    XCTAssertEqual(validated.projection, ["name", "rowId", "revision", "platform"])
    XCTAssertEqual(try validated.validatedForExecution().projection, validated.projection)
    XCTAssertEqual(query.projection, ["name"])
  }

  func testAllFieldsAndAggregateProjectionAreNotNarrowedOrExpanded() throws {
    var query = SelectQuery(entity: entity)
    query.comment = "read invoice"; query.purpose = "verify projection contracts"
    XCTAssertTrue(try query.validatedForExecution().projection.isEmpty)
    query.projection = ["name"]; query.groupBy = ["name"]
    query.aggregates = [QueryAggregate(.count, field: "rowId", alias: "total")]
    XCTAssertEqual(try query.validatedForExecution().projection, ["name"])
  }
}
