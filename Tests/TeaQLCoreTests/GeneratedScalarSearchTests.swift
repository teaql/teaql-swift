import Foundation
import TeaQLCore
import XCTest

final class GeneratedScalarSearchTests: XCTestCase {
  private var models: [String: GeneratedSearchModel] { [
    "Invoice": GeneratedSearchModel(model: SearchModel(fields: [
      "reference_code": "string", "referenceCode": "string", "amount": "decimal", "active": "boolean",
      "customer": "integer", "date": "date", "created": "timestamp", "ratio": "number", "payload": "unsupported"
    ], relations: ["customer": "Customer"]), queryFields: [
      "reference_code": "referenceCode", "referenceCode": "referenceCode", "amount": "amount", "active": "active",
      "customer": "customerId", "date": "date", "created": "created", "ratio": "ratio", "payload": "payload"
    ]),
    "Customer": GeneratedSearchModel(model: SearchModel(fields: ["name": "string"]), queryFields: ["name": "name"])
  ] }
  private func base() -> SelectQuery {
    var query = SelectQuery(entity: EntityDescriptor(name: "Invoice", table: "invoice", properties: []))
    query.filter = .equal("scope", .int(7))
    query.orderBy = [OrderBy("id", .ascending)]
    query.limit = 10
    return query
  }

  func testAllSiblingsAndAliasesPreserveOriginalScopeAndControls() throws {
    let original = base()
    var warnings: [DynamicSearchWarning] = []
    let result = try DynamicSearch.mergeGeneratedScalar(original, source:
      #"{"filter":{"referenceCode":{"$contains":"KEEP"},"amount":{"$gte":"100.50"},"active":true,"removed":"SECRET"},"orderBy":[{"field":"reference_code","direction":"desc"}]}"#,
      models: models, warn: { warnings.append($0) })
    XCTAssertEqual(result.query.filter, .and([
      .and([.and([.equal("scope", .int(7)), .equal("active", .bool(true))]),
        .greaterThanOrEqual("amount", .decimal(Decimal(string: "100.50")!))]), .contains("referenceCode", "KEEP")]))
    XCTAssertEqual(result.query.orderBy, [OrderBy("id", .ascending), OrderBy("referenceCode", .descending)])
    XCTAssertEqual(result.query.limit, 10)
    XCTAssertEqual(original.filter, .equal("scope", .int(7)))
    XCTAssertEqual(original.orderBy.count, 1)
    XCTAssertEqual(result.warnings, warnings)
    XCTAssertEqual(warnings.count, 1)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(warnings), as: UTF8.self).contains("SECRET"))
  }

  func testInvalidInputRejectsBeforeWarningEmissionAndLeavesOriginalUnchanged() {
    for source in [
      #"{"filter":{"reference_code":"KEEP","customer.name":"Ada","removed":"secret"}}"#,
      #"{"orderBy":[{"field":"customer.name","direction":"asc"}]}"#,
      #"{"filter":{"active":"true"}}"#, #"{"filter":{"amount":"NaN"}}"#,
      #"{"filter":{"payload":null}}"#, #"{"orderBy":[{"field":"payload","direction":"asc"}]}"#,
      #"{"filter":{"reference_code":{"$contains":null}}}"#,
      #"{"filter":{"created":{"$gt":null}}}"#, #"{"tenant":99}"#
    ] {
      let original = base()
      var warnings: [DynamicSearchWarning] = []
      XCTAssertThrowsError(try DynamicSearch.mergeGeneratedScalar(original, source: source,
        models: models, warn: { warnings.append($0) }), source)
      XCTAssertEqual(original.filter, .equal("scope", .int(7)))
      XCTAssertEqual(original.orderBy.count, 1)
      XCTAssertTrue(warnings.isEmpty)
    }
  }

  func testNativeNumericDateReferenceMembershipAndNullBindings() throws {
    for (source, expected) in [
      (#"{"filter":{"date":"2026-10-11"}}"#, TeaQLExpression.equal("date", .calendarDate("2026-10-11"))),
      (#"{"filter":{"created":1791676800000}}"#, .equal("created", .timestamp(1791676800000))),
      (#"{"filter":{"ratio":{"$lt":1.25}}}"#, .lessThan("ratio", .double(1.25))),
      (#"{"filter":{"customer":{"$in":[1,2]}}}"#, .inList("customerId", [.int(1), .int(2)])),
      (#"{"filter":{"customer":{"$notIn":[1]}}}"#, .notInList("customerId", [.int(1)])),
      (#"{"filter":{"referenceCode":null}}"#, .isNull("referenceCode")),
      (#"{"filter":{"reference_code":{"$ne":null}}}"#, .isNotNull("referenceCode")),
      (#"{"filter":{"amount":{"$lte":1e2}}}"#, .lessThanOrEqual("amount", .decimal(100))),
      (#"{"filter":{"customer":{"$gt":1}}}"#, .greaterThan("customerId", .int(1))),
      (#"{"filter":{"referenceCode":{"$ne":"DROP"}}}"#, .notEqual("referenceCode", .string("DROP")))
    ] {
      var query = base(); query.filter = nil
      let result = try DynamicSearch.mergeGeneratedScalar(query, source: source, models: models)
      XCTAssertEqual(result.query.filter, expected, source)
    }
  }

  func testCalendarDateOperatorsPreserveCanonicalGregorianTextAndTypedNull() throws {
    for day in ["0001-01-01", "1582-10-10", "2000-02-29", "2024-02-29", "9999-12-31"] {
      let expected: [(String, TeaQLExpression)] = [
        ("$eq", .equal("date", .calendarDate(day))), ("$ne", .notEqual("date", .calendarDate(day))),
        ("$gt", .greaterThan("date", .calendarDate(day))), ("$gte", .greaterThanOrEqual("date", .calendarDate(day))),
        ("$lt", .lessThan("date", .calendarDate(day))), ("$lte", .lessThanOrEqual("date", .calendarDate(day))),
        ("$in", .inList("date", [.calendarDate(day)])), ("$notIn", .notInList("date", [.calendarDate(day)])),
      ]
      for (operation, expression) in expected {
        let value = ["$in", "$notIn"].contains(operation) ? "[\"\(day)\"]" : "\"\(day)\""
        let original = base()
        let result = try DynamicSearch.mergeGeneratedScalar(original,
          source: "{\"filter\":{\"date\":{\"\(operation)\":\(value)}}}", models: models)
        XCTAssertEqual(result.query.filter, .and([.equal("scope", .int(7)), expression]))
        XCTAssertEqual(original.filter, .equal("scope", .int(7)))
      }
    }
    for invalid in ["0000-01-01", "1900-02-29", "2024-02-30", "2024-2-29", "2024-02-29T00:00:00Z"] {
      var warnings: [DynamicSearchWarning] = []
      XCTAssertThrowsError(try DynamicSearch.mergeGeneratedScalar(base(),
        source: "{\"filter\":{\"date\":\"\(invalid)\",\"removed\":\"SECRET-CANARY\"}}",
        models: models, warn: { warnings.append($0) }))
      XCTAssertTrue(warnings.isEmpty)
    }
    // The local UI contract still rejects unsafe JSON numbers and context controls.
    for source in [#"{"filter":{"customer":9007199254740992}}"#, #"{"tenant":7}"#] {
      XCTAssertThrowsError(try DynamicSearch.mergeGeneratedScalar(base(), source: source, models: models))
    }
  }
}
