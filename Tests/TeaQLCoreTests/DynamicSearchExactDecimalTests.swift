import Foundation
import TeaQLCore
import XCTest

final class DynamicSearchExactDecimalTests: XCTestCase {
  private let overprecision = "12345678901234567890123456789012345678901234567890123456789"
  private var models: [String: GeneratedSearchModel] { [
    "Invoice": .init(model: .init(fields: ["amount": "decimal", "total_amount": "decimal",
      "name": "string", "ratio": "number", "count": "integer"]),
      queryFields: ["amount": "amount", "total_amount": "amount", "name": "name", "ratio": "ratio", "count": "count"])
  ] }
  private var base: SelectQuery {
    var query = SelectQuery(entity: .init(name: "Invoice", table: "invoice", properties: []))
    query.filter = .equal("scope", .int(7)); query.limit = 10
    query.comment = "Load scoped invoices"; query.purpose = "Verify exact monetary predicates"
    return query
  }

  func testOverprecisionStringAndNumericOperandsRejectAtomically() throws {
    let values = [overprecision, "-" + overprecision, "0." + overprecision]
    for text in values {
      for literal in [text, "\"\(text)\""] {
        for field in ["amount", "total_amount"] {
          for operation in ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$notIn"] {
            let operand = ["$in", "$notIn"].contains(operation) ? "[0.1,\(literal)]" : literal
            let source = "{\"filter\":{\"\(field)\":{\"\(operation)\":\(operand)},\"removed\":\"SECRET-CANARY\"}}"
            let original = base
            var warnings: [DynamicSearchWarning] = []
            XCTAssertThrowsError(try DynamicSearch.mergeGeneratedScalar(original, source: source,
              models: models, warn: { warnings.append($0) }), "\(field) \(operation) \(literal)") { error in
                guard case DynamicSearchError.invalid = error else { return XCTFail("Wrong error type: \(error)") }
                XCTAssertFalse(String(describing: error).contains(text))
              }
            XCTAssertTrue(warnings.isEmpty)
            XCTAssertEqual(original.filter, .equal("scope", .int(7)))
            XCTAssertEqual(original.limit, 10)
          }
        }
      }
    }
  }

  func testExactNumbersScalesAndLargePowersPreserveDecimalCarrier() throws {
    let power = "1" + String(repeating: "0", count: 80)
    let cases: [(String, String)] = [
      ("0.1", "0.1"), ("3.5000", "3.5"), ("1e2", "100"), ("-1.25e-2", "-0.0125"),
      ("18446744073709551615", "18446744073709551615"),
      ("12345678901234567890123456789012345678", "12345678901234567890123456789012345678"),
      (power, power), ("\"" + power + "\"", power), ("\"+003.5000\"", "3.5"), ("-0.000", "0"),
    ]
    for (literal, expected) in cases {
      let result = try DynamicSearch.mergeGeneratedScalar(base,
        source: "{\"filter\":{\"amount\":\(literal)}}", models: models)
      XCTAssertEqual(result.query.filter, .and([.equal("scope", .int(7)),
        .equal("amount", .decimal(try XCTUnwrap(Decimal(string: expected))))]), literal)
    }
    let result = try DynamicSearch.mergeGeneratedScalar(base,
      source: #"{"filter":{"total_amount":{"$in":[null,0.1,"3.5000",1e2]}}}"#, models: models)
    XCTAssertEqual(result.query.filter, .and([.equal("scope", .int(7)), .inList("amount", [
      .null, .decimal(Decimal(string: "0.1")!), .decimal(Decimal(string: "3.5")!), .decimal(100)])]))
  }

  func testUnknownValuesEscapedTokensAndNonDecimalProfilesRemainIndependent() throws {
    var warnings: [DynamicSearchWarning] = []
    let result = try DynamicSearch.mergeGeneratedScalar(base,
      source: "{\"filter\":{\"removed\":\(overprecision),\"\\u0061mount\":{\"$e\\u0071\":0.1},\"name\":\"quote \\\" number 123.456 \\\\ end\",\"ratio\":1.25}}",
      models: models, warn: { warnings.append($0) })
    XCTAssertEqual(warnings.count, 1)
    XCTAssertEqual(result.query.limit, 10)
    XCTAssertEqual(result.query.comment, base.comment)
    XCTAssertEqual(result.query.purpose, base.purpose)
    XCTAssertFalse(String(describing: result.query.filter).contains(overprecision))
    for source in [#"{"filter":{"amount":"1e2"}}"#, #"{"filter":{"amount":"NaN"}}"#,
      #"{"filter":{"amount":"1.2tail"}}"#, #"{"filter":{"amount":true}}"#,
      #"{"filter":{"count":9007199254740992}}"#, #"{"tenant":7}"#, #"{"filter":{"amount":01}}"#] {
      XCTAssertThrowsError(try DynamicSearch.mergeGeneratedScalar(base, source: source, models: models))
    }
  }
}
