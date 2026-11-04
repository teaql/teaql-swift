import Foundation
import TeaQLCore
import TeaQLSQL
import TeaQLSQLite
import XCTest

final class GroupingAliasTests: XCTestCase {
  private let entity = EntityDescriptor(name: "GroupingRecord", table: "grouping_record", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "active", column: "is_active", type: .bool),
    PropertyDescriptor(name: "requiredInteger", modelName: "required_integer", column: "required_integer", type: .int),
    PropertyDescriptor(name: "requiredLong", column: "required_long", type: .int),
    PropertyDescriptor(name: "requiredDecimal", column: "required_decimal", type: .decimal),
    PropertyDescriptor(name: "occurredAt", column: "occurred_at", type: .timestamp),
    PropertyDescriptor(name: "owner", column: "owner_id", type: .int, nullable: true),
  ])

  private func query(_ groups: [String], aliases: [String: String] = [:], aggregates: [QueryAggregate] = []) throws -> SelectQuery {
    var query = SelectQuery(entity: entity)
    query.groupBy = groups; query.aggregates = aggregates; query.limit = 10
    query.comment = "inspect grouping result aliases"; query.purpose = "verify result names and native value domains"
    // This is a native AST compatibility test, not a replacement Q API. Encoding
    // the new optional field also lets the unchanged pre-fix runtime execute the
    // same test and fail on actual semantics rather than a missing Swift symbol.
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
    if !aliases.isEmpty { json["groupByAliases"] = aliases }
    return try JSONDecoder().decode(SelectQuery.self, from: JSONSerialization.data(withJSONObject: json))
  }

  private func seeded() async throws -> UserContext {
    let service = try SQLiteDataService(path: ":memory:")
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(RuntimeModule(name: "grouping aliases", entities: [entity]))
    let exact = try XCTUnwrap(Decimal(string: "12345678901234567890.123456789", locale: Locale(identifier: "en_US_POSIX")))
    for id: Int64 in 1...4 {
      _ = try await context.execute(Mutation(kind: .create, entity: entity, values: [
        "id": .int(id), "active": .bool(id != 1), "required_integer": .int(id),
        "requiredLong": .int(9_007_199_254_740_993), "requiredDecimal": .decimal(exact),
        "occurredAt": .timestamp(1_787_995_800_000), "owner": id == 4 ? .null : .int(id < 3 ? 1 : 2),
      ], auditReason: "seed exact grouping contributions"))
    }
    return context
  }

  func testBooleanNamedGroupsAndCountsRetainDifferentValueDomains() async throws {
    let context = try await seeded()
    let q = try query(["active"], aliases: ["active": "bucket"], aggregates: [
      QueryAggregate(.count, field: "*", alias: "hits"), QueryAggregate(.sum, field: "requiredInteger", alias: "total"),
    ])
    let rows = try await context.execute(q).records
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows.contains(["bucket": .bool(false), "hits": .int(1), "total": .int(1)]))
    XCTAssertTrue(rows.contains(["bucket": .bool(true), "hits": .int(3), "total": .int(9)]))
    XCTAssertTrue(rows.allSatisfy { $0["id"] == nil && $0["version"] == nil && $0["active"] == nil })

    let shadow = try query(["active"], aliases: ["active": "required_long"], aggregates: [QueryAggregate(.count, field: "*", alias: "active")])
    let shadowRows = try await context.execute(shadow).records
    XCTAssertTrue(shadowRows.contains(["required_long": .bool(false), "active": .int(1)]))
    XCTAssertTrue(shadowRows.contains(["required_long": .bool(true), "active": .int(3)]))
    let physicalShadow = try query(["requiredInteger"], aliases: ["requiredInteger": "owner_id"], aggregates: [QueryAggregate(.count, field: "*", alias: "is_active")])
    let physicalRows = try await context.execute(physicalShadow).records
    XCTAssertTrue(physicalRows.contains(["owner_id": .int(4), "is_active": .int(1)]))
  }

  func testGroupOnlyNullableAndMultipleGroupsUseExactlySelectedAliases() async throws {
    let context = try await seeded()
    for (field, alias, expected) in [
      ("active", "bucket", [.bool(false), .bool(true)]),
      ("owner", "parent", [.null, .int(1), .int(2)]),
    ] as [(String, String, [TeaQLValue])] {
      let rows = try await context.execute(query([field], aliases: [field: alias])).records
      XCTAssertEqual(rows.count, expected.count)
      for value in expected { XCTAssertTrue(rows.contains([alias: value])) }
    }
    let grouped = try query(["owner", "active"], aliases: ["owner": "parent", "active": "bucket"],
      aggregates: [QueryAggregate(.count, field: "*", alias: "hits")])
    let rows = try await context.execute(grouped).records
    XCTAssertEqual(rows.count, 4)
    XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["parent", "bucket", "hits"] })
    var empty = grouped; empty.filter = .equal("id", .int(999))
    let emptyRows = try await context.execute(empty).records
    XCTAssertTrue(emptyRows.isEmpty)
  }

  func testExactLongDecimalAndTimestampGroupsDoNotLoseTypes() async throws {
    let context = try await seeded()
    let exact = try XCTUnwrap(Decimal(string: "12345678901234567890.123456789", locale: Locale(identifier: "en_US_POSIX")))
    for (field, expected): (String, TeaQLValue) in [
      ("requiredLong", .int(9_007_199_254_740_993)), ("requiredDecimal", .decimal(exact)),
      ("occurredAt", .timestamp(1_787_995_800_000)),
    ] {
      let q = try query([field], aliases: [field: "key"], aggregates: [QueryAggregate(.count, field: "*", alias: "hits")])
      let rows = try await context.execute(q).records
      XCTAssertEqual(rows, [["key": expected, "hits": .int(4)]])
    }
    let q = try query([], aggregates: [QueryAggregate(.min, field: "requiredDecimal", alias: "active"),
      QueryAggregate(.min, field: "requiredLong", alias: "occurredAt"), QueryAggregate(.count, field: "*", alias: "required_decimal")])
    let rows = try await context.execute(q).records
    XCTAssertEqual(rows, [["active": .decimal(exact), "occurredAt": .int(9_007_199_254_740_993), "required_decimal": .int(4)]])
  }

  func testDuplicateAndInvalidAliasesFailInCompilerBeforeSQLite() throws {
    let compiler = SQLiteCompiler()
    let duplicates = [
      try query(["active"], aliases: ["active": "same"], aggregates: [QueryAggregate(.count, field: "*", alias: "same")]),
      try query(["active", "owner"], aliases: ["active": "same", "owner": "same"]),
      try query([], aggregates: [QueryAggregate(.count, field: "*", alias: "same"), QueryAggregate(.sum, field: "requiredInteger", alias: "same")]),
    ]
    for q in duplicates { XCTAssertThrowsError(try compiler.compile(q)) }
    for alias in ["", "\"already quoted\"", "bad\0alias"] {
      XCTAssertThrowsError(try compiler.compile(query(["active"], aliases: ["active": alias])))
    }
    XCTAssertThrowsError(try compiler.compile(query(["active"], aliases: ["owner": "orphan"])))
  }

  func testAliasedSnapshotsAndJSONKeepSemanticsWithoutBreakingLegacyQueries() throws {
    let plain = try query(["active"]), aliased = try query(["active"], aliases: ["active": "bucket"])
    XCTAssertNotEqual(plain, aliased); XCTAssertEqual(Set([plain, aliased]).count, 2)
    let snapshot = RelationQueryPlan(aliased)
    let restored = try JSONDecoder().decode(RelationQueryPlan.self, from: JSONEncoder().encode(snapshot)).makeQuery()
    XCTAssertEqual(restored, aliased)
    for q in [aliased, snapshot.makeQuery(), restored] {
      let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as? [String: Any])
      XCTAssertEqual(json["groupByAliases"] as? [String: String], ["active": "bucket"])
      XCTAssertTrue(try SQLiteCompiler().compile(q).sql.contains("\"is_active\" AS \"bucket\""))
    }
    let legacyBytes = try JSONEncoder().encode(plain)
    let legacy = try JSONDecoder().decode(SelectQuery.self, from: legacyBytes)
    XCTAssertEqual(legacy, plain)
    XCTAssertTrue(try SQLiteCompiler().compile(legacy).sql.contains("\"is_active\" AS \"active\""))
  }
}
