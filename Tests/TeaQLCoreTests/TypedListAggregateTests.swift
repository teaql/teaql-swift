import Foundation
import XCTest
@testable import TeaQLCore

final class TypedListAggregateTests: XCTestCase {
  func testScalarAliasesNeverHydrateAnEntityAndCountRemainsOptional() async throws {
    for scalar in [TeaQLValue.decimal(600), .null] {
      for counted in [false, true] {
        let executor = ScalarListExecutor(scalar: scalar)
        let context = UserContext(queryExecutor: executor, mutationExecutor: executor,
          requestPolicy: RequestPolicy { $0 })
        var query = query()
        query.aggregates = [QueryAggregate(.sum, field: "amount", alias: "sum")]
        if counted {
          query.aggregates.append(QueryAggregate(.count, field: "id", alias: "n"))
          query.pageCountOperation = QueryOperation("count", method: "countAs", alias: "n")
        }
        let result: SmartList<Int64> = try await context.executeTypedList(query, countRequested: counted) { _ in
          XCTFail("scalar alias reached entity hydration"); return 0
        }
        XCTAssertTrue(result.isLoaded); XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.aggregations["sum"], scalar)
        XCTAssertEqual(result.totalCount, counted ? 3 : nil)
        XCTAssertEqual(result.aggregations["n"], counted ? .int(3) : nil)
      }
    }
  }

  func testGroupedProjectionCannotCrossTheTypedEntityBoundary() async throws {
    let executor = ScalarListExecutor(scalar: .null)
    let context = UserContext(queryExecutor: executor, mutationExecutor: executor, requestPolicy: RequestPolicy { $0 })
    var query = query(); query.groupBy = ["amount"]
    do {
      let _: SmartList<Int64> = try await context.executeTypedList(query, countRequested: false) { _ in
        XCTFail("projection reached entity hydration"); return 0
      }
      XCTFail("grouped projection accepted as entities")
    } catch TeaQLError.unsupportedQueryCapability { }
  }

  private func query() -> SelectQuery {
    var query = SelectQuery(entity: EntityDescriptor(name: "Order", table: "orders", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "amount", type: .decimal)
    ]))
    query.comment = "sum matching orders"; query.purpose = "verify scalar metadata"
    return query
  }
}

private actor ScalarListExecutor: QueryExecutor, MutationExecutor {
  let scalar: TeaQLValue
  init(scalar: TeaQLValue) { self.scalar = scalar }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    QueryResult(records: [["sum": scalar]], backend: "stub")
  }
  func count(_ request: QueryRequest) async throws -> Int { 3 }
  func execute(_ request: MutationRequest) async throws -> MutationResult { MutationResult(affectedRows: 0) }
}
