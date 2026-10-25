import Foundation
import TeaQLCore
import TeaQLSQLite
import XCTest

final class EmptyAggregateTests: XCTestCase {
  func testNullSumRealZeroRelatedBucketsAndJSON() async throws {
    let bucket = EntityDescriptor(name: "Bucket", table: "ea_bucket", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true)])
    let entry = EntityDescriptor(name: "Entry", table: "ea_entry", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "bucket", type: .int), PropertyDescriptor(name: "amount", type: .int, nullable: true)])
    let service = try SQLiteDataService(path: ":memory:")
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(RuntimeModule(name: "empty aggregates", entities: [bucket, entry]))
    for id: Int64 in 1...4 {
      _ = try await context.execute(Mutation(kind: .create, entity: bucket,
        values: ["id": .int(id)], auditReason: "seed aggregate bucket"))
    }
    for (id, owner, amount): (Int64, Int64, TeaQLValue) in [
      (1,1,.int(4)),(2,1,.int(-4)),(3,2,.null),(4,2,.null),
      (5,3,.null),(6,3,.int(2)),(7,3,.int(-1)),(8,3,.null)] {
      _ = try await context.execute(Mutation(kind: .create, entity: entry,
        values: ["id": .int(id), "bucket": .int(owner), "amount": amount], auditReason: "seed aggregate contribution"))
    }
    func bounded(_ entity: EntityDescriptor) -> SelectQuery {
      var query = SelectQuery(entity: entity)
      query.limit = 10; query.comment = "inspect empty aggregates"; query.purpose = "verify EA-01 through EA-08"
      return query
    }
    for (owner, rowCount, values, sum): (Int64?, Int64, Int64, TeaQLValue) in [
      (4,0,0,.null), (2,2,0,.null), (3,4,2,.int(1)), (1,2,2,.int(0)), (nil,8,4,.int(1))] {
      var query = bounded(entry)
      query.aggregates = [QueryAggregate(.count, field: "id", alias: "rows"),
        QueryAggregate(.count, field: "amount", alias: "values"), QueryAggregate(.sum, field: "amount", alias: "total")]
      if let owner { query.filter = .equal("bucket", .int(owner)) }
      let original = query
      let result = try await context.execute(query)
      XCTAssertEqual(query, original)
      XCTAssertEqual(result.records.count, 1)
      let row = try XCTUnwrap(result.records.first)
      XCTAssertEqual(row["rows"], .int(rowCount)); XCTAssertEqual(row["values"], .int(values))
      XCTAssertEqual(row["total"], sum)
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
      XCTAssertNotNil(json["total"])
      if sum == .null { XCTAssertTrue(json["total"] is NSNull) }
      let explicitDefault = row["total"]?.int64Value ?? 0
      XCTAssertEqual(explicitDefault, sum.int64Value ?? 0); XCTAssertEqual(row["total"], sum)
    }
    var grouped = bounded(entry)
    grouped.filter = .equal("bucket", .int(4)); grouped.groupBy = ["bucket"]
    grouped.aggregates = [QueryAggregate(.sum, field: "amount", alias: "total")]
    let groups = try await context.execute(grouped)
    XCTAssertTrue(groups.records.isEmpty)
    var count = bounded(entry), sum = bounded(entry)
    count.aggregates = [QueryAggregate(.count, field: "id", alias: "count")]
    sum.aggregates = [QueryAggregate(.sum, field: "amount", alias: "sum")]
    var parents = bounded(bucket)
    parents.orderBy = [OrderBy("id", .ascending)]
    parents.relationAggregate("entries", foreignKey: "bucket", alias: "entryCount", query: count)
    parents.relationAggregate("entries", foreignKey: "bucket", alias: "entryTotal", query: sum)
    func assertBuckets(_ rows: [[String: TeaQLValue]]) {
      XCTAssertEqual(rows.count, 4)
      XCTAssertEqual(rows.map { $0["entryCount"] }, [.int(2),.int(2),.int(4),.int(0)])
      XCTAssertEqual(rows.map { $0["entryTotal"] }, [.int(0),.null,.int(1),.null])
    }
    let related = try await context.execute(parents)
    assertBuckets(related.records)
    var choices = bounded(bucket)
    choices.orderBy = [OrderBy("id", .ascending)]
    choices.aggregates = [QueryAggregate(.count, field: "id", alias: "entryCount")]
    choices.relationAggregate("entries", foreignKey: "bucket", alias: "entryTotal", query: sum)
    var outer = bounded(entry)
    outer.facets = [FacetRequest(name: "buckets", relationName: "bucket", query: choices)]
    let result = try await context.execute(outer)
    assertBuckets(try XCTUnwrap(result.facets["buckets"]).map { $0 })
    print("EMPTY_AGGREGATES_PASS swift sqlite EA-01..08")
  }
}
