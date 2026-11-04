import Foundation
import TeaQLCore
import TeaQLSQLite
import XCTest

final class GroupingAliasBoundaryTests: XCTestCase {
  private let entity = EntityDescriptor(name: "AliasBoundary", table: "alias_boundary", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "active", column: "is_active", type: .bool),
  ])

  func testBuilderUsesCopyOnWriteAndPreservesGroupAliasesAcrossSnapshots() throws {
    var query = SelectQuery(entity: entity)
    query.groupBy = ["active"]
    query.groupBy("active", as: "bucket")
    XCTAssertEqual(query.groupBy, ["active"])
    var copy = query
    copy.groupBy("active", as: "other")
    XCTAssertEqual(query.groupByAliases, ["active": "bucket"])
    XCTAssertEqual(copy.groupByAliases, ["active": "other"])
    XCTAssertNotEqual(query, copy)
    let snapshot = RelationQueryPlan(query)
    query.groupBy("active", as: "changedAfterSnapshot")
    XCTAssertEqual(snapshot.makeQuery().groupByAliases, ["active": "bucket"])
    let restored = try JSONDecoder().decode(RelationQueryPlan.self, from: JSONEncoder().encode(snapshot))
    XCTAssertEqual(restored.makeQuery(), snapshot.makeQuery())
  }

  func testCallerAliasPunctuationIsQuotedDataAndCannotChangeTheStatement() async throws {
    let service = try SQLiteDataService(path: ":memory:")
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(RuntimeModule(name: "literal aliases", entities: [entity]))
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(1), "active": .bool(true)], auditReason: "seed alias safety vector"))
    for alias in ["a\"b", "has space", "x); DROP TABLE alias_boundary;--", "分组"] {
      var query = SelectQuery(entity: entity)
      query.groupBy("active", as: alias)
      query.aggregates = [QueryAggregate(.count, field: "*", alias: "count with \"quotes\"")]
      query.limit = 10; query.comment = "inspect literal alias data"; query.purpose = "prove identifiers cannot become SQL"
      let rows = try await context.execute(query).records
      XCTAssertEqual(rows, [[alias: .bool(true), "count with \"quotes\"": .int(1)]])
    }
    var query = SelectQuery(entity: entity)
    query.limit = 1; query.comment = "verify alias source survived"; query.purpose = "check query immutability"
    let rows = try await context.execute(query).records
    XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["version"], .int(1))
  }
}
