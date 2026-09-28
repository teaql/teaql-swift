import Foundation
@testable import TeaQLCore
import XCTest

final class DynamicSearchTests: XCTestCase {
  private var models: [String: SearchModel] { [
    "School": .init(fields: ["id": "integer", "name": "string", "active": "boolean",
      "amount": "decimal", "established_date": "date", "create_time": "timestamp", "capacity": "number"],
      relations: ["platform": "Platform"]),
    "Platform": .init(fields: ["id": "integer", "name": "string"])
  ] }

  func testWholeUnknownClausesWarnWithoutValues() throws {
    var warnings: [DynamicSearchWarning] = []
    let result = try DynamicSearch.normalize(#"{"filter":{"name":"School","old_name":"secret","platform.old_name":"secret","missing.name":"secret","platform.name":"Campus"},"orderBy":[{"field":"gone","direction":"asc"},{"field":"id","direction":"desc"}]}"#,
      entity: "School", models: models, warn: { warnings.append($0) })
    XCTAssertEqual(result.filters.map(\.fieldPath), ["name", "platform.name"])
    XCTAssertEqual(result.orders.map(\.fieldPath), ["id"])
    XCTAssertEqual(warnings.count, 4)
    XCTAssertEqual(Set(warnings.map(\.fieldPath)), ["old_name", "platform.old_name", "missing.name", "gone"])
    XCTAssertTrue(warnings.allSatisfy { $0.code == "DYNAMIC_SEARCH_UNKNOWN_FIELD" })
    let json = String(decoding: try JSONEncoder().encode(warnings), as: UTF8.self)
    XCTAssertFalse(json.contains("secret"))
    XCTAssertTrue(json.contains("fieldPath"))
  }

  func testDefaultLogProjectionOmitsUntrustedFieldPath() throws {
    let path = "CLIENT_SECRET_FIELD_PATH_91"
    let result = try DynamicSearch.normalize(
      #"{"filter":{"CLIENT_SECRET_FIELD_PATH_91":"SECRET_VALUE_99"}}"#,
      entity: "School", models: models, warn: { _ in })
    let warning = try XCTUnwrap(result.warnings.first)
    XCTAssertEqual(warning.fieldPath, path)
    let json = String(decoding: try JSONEncoder().encode(warning.defaultLogProjection()), as: UTF8.self)
    XCTAssertTrue(json.contains("DYNAMIC_SEARCH_UNKNOWN_FIELD"))
    XCTAssertTrue(json.contains("<omitted>"))
    XCTAssertFalse(json.contains(path))
    XCTAssertFalse(json.contains("SECRET_VALUE_99"))
  }

  func testInvalidInputIsFatal() {
    let inputs = ["[]", "{} {}", #"{"tenant":2}"#, #"{"filter":{"id":true}}"#,
      #"{"filter":{"id":1.2}}"#, #"{"filter":{"capacity":1e999}}"#,
      #"{"filter":{"established_date":"2026-02-30"}}"#,
      #"{"filter":{"gone":{"$wat":1}}}"#, #"{"filter":{"name":{"$in":1}}}"#,
      #"{"filter":{"constructor":1}}"#, #"{"filter":{"platform..name":1}}"#,
      #"{"orderBy":[{"field":"id","direction":"bad"}]}"#]
    for input in inputs {
      var warnings: [DynamicSearchWarning] = []
      XCTAssertThrowsError(try DynamicSearch.normalize(input, entity: "School", models: models,
        warn: { warnings.append($0) }), input)
      XCTAssertTrue(warnings.isEmpty)
    }
  }

  func testTypedValuesAndDecimalDigitsAreRetained() throws {
    let result = try DynamicSearch.normalize(#"{"filter":{"id":1.0,"active":true,"amount":"12345678901234567890.123456789","established_date":"2024-02-29","create_time":1700000000000,"name":null}}"#,
      entity: "School", models: models)
    XCTAssertEqual(result.filters.count, 6)
    XCTAssertEqual(result.filters.first { $0.fieldPath == "amount" }?.value, .string("12345678901234567890.123456789"))
    XCTAssertEqual(result.filters.first { $0.fieldPath == "active" }?.value, .bool(true))
  }

  func testLimitsAndBrokenTrustedMetadataFail() throws {
    XCTAssertThrowsError(try DynamicSearch.normalize(#"{"filter":{"name":"x","gone":1}}"#,
      entity: "School", models: models, maxClauses: 1))
    let input = "{\"filter\":{\"id\":{\"$in\":[" + Array(repeating: "1", count: 1001).joined(separator: ",") + "]}}}"
    XCTAssertThrowsError(try DynamicSearch.normalize(input, entity: "School", models: models))
    var broken = models
    broken.removeValue(forKey: "Platform")
    XCTAssertThrowsError(try DynamicSearch.normalize(#"{"filter":{"platform.name":"x"}}"#,
      entity: "School", models: broken))
  }

  func testMergeRetainsBaseAndLateFailureEmitsNoWarnings() throws {
    var base = SelectQuery(entity: EntityDescriptor(name: "School", table: "school", properties: []))
    base.filter = .equal("tenant_id", .int(7))
    base.orderBy = [OrderBy("id", .descending)]
    base.limit = 2
    base.hardLimit = 3
    base.comment = "what: search schools"
    base.purpose = "why: tenant page"
    var warnings: [DynamicSearchWarning] = []
    let source = #"{"filter":{"gone":"secret","name":"School"},"orderBy":[{"field":"name","direction":"asc"}]}"#
    let result = try DynamicSearch.merge(base, source: source, models: models,
      filterBinding: { .equal($0.fieldPath, $0.value) }, orderBinding: { OrderBy($0.fieldPath, $0.direction) },
      warn: { warnings.append($0) })
    XCTAssertEqual(base.filter, .equal("tenant_id", .int(7)))
    XCTAssertEqual(result.query.filter, .and([base.filter!, .equal("name", .string("School"))]))
    XCTAssertEqual(result.query.orderBy.map(\.field), ["id", "name"])
    XCTAssertEqual(base.orderBy.count, 1)
    XCTAssertEqual(result.query.limit, 2)
    XCTAssertEqual(result.query.hardLimit, 3)
    XCTAssertEqual(result.query.purpose, base.purpose)
    XCTAssertEqual(warnings.count, 1)
    warnings = []
    XCTAssertThrowsError(try DynamicSearch.merge(base, source: source, models: models,
      filterBinding: { _ in throw DynamicSearchError.invalid("binding") },
      orderBinding: { OrderBy($0.fieldPath, $0.direction) }, warn: { warnings.append($0) }))
    XCTAssertThrowsError(try DynamicSearch.normalize(#"{"filter":{"gone":1,"id":"bad"}}"#,
      entity: "School", models: models, warn: { warnings.append($0) }))
    XCTAssertTrue(warnings.isEmpty)
  }
}
