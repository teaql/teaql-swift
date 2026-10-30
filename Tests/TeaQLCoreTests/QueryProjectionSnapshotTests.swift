import Foundation
import XCTest
@testable import TeaQLCore

final class QueryProjectionSnapshotTests: XCTestCase {
  func testMissingNullZeroAndModeledFieldsAreDistinct() throws {
    let snapshot = QueryProjectionSnapshot(record: [
      "id": .int(7), "childList": .array([]), "zero": .int(0), "null": .null,
    ], excluding: ["id", "childList"])
    XCTAssertTrue(snapshot.contains("zero"))
    XCTAssertTrue(snapshot.contains("null"))
    XCTAssertEqual(try snapshot.get("zero"), .int(0))
    XCTAssertEqual(try snapshot.get("null"), .null)
    for alias in ["id", "childList", "missing"] {
      XCTAssertFalse(snapshot.contains(alias))
      XCTAssertThrowsError(try snapshot.get(alias)) {
        XCTAssertEqual($0 as? QueryProjectionNotLoaded, QueryProjectionNotLoaded(alias: alias))
      }
    }
  }

  func testInputAndReturnedNestedValuesCannotMutateSnapshot() throws {
    var source: TeaQLRecord = ["details": .object(["values": .array([.int(1)])])]
    let snapshot = QueryProjectionSnapshot(record: source)
    source["details"] = .null
    guard case .object(var output) = try snapshot.get("details") else { return XCTFail("missing object") }
    output["values"] = .array([.int(999)])
    XCTAssertEqual(try snapshot.get("details"), .object(["values": .array([.int(1)])]))
  }

  private func encodable(_ value: Any) throws -> any Encodable {
    try XCTUnwrap(value as? any Encodable, "Query-derived properties must be serializable")
  }

  private func encoded(_ snapshot: QueryProjectionSnapshot) throws -> Data {
    try JSONEncoder().encode(encodable(snapshot))
  }

  func testJSONRetainsPresentNullZeroFalseAndEmptyString() throws {
    let snapshot = QueryProjectionSnapshot(record: ["_sum": .null, "_count": .int(0),
      "_enabled": .bool(false), "_label": .string("")])
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(snapshot)) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["_sum", "_count", "_enabled", "_label"])
    XCTAssertTrue(json["_sum"] is NSNull)
    XCTAssertEqual((json["_count"] as? NSNumber)?.int64Value, 0)
    XCTAssertEqual(json["_enabled"] as? Bool, false)
    XCTAssertEqual(json["_label"] as? String, "")
    XCTAssertTrue(snapshot.contains("_sum")); XCTAssertEqual(snapshot.value("_sum"), .null)
  }

  func testJSONDoesNotInventMissingOrExcludedProperties() throws {
    let snapshot = QueryProjectionSnapshot(record: ["id": .int(1), "_count": .int(0)], excluding: ["id"])
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(snapshot)) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["_count"])
    XCTAssertFalse(snapshot.contains("missing")); XCTAssertNil(snapshot.value("missing"))
    let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(QueryProjectionSnapshot())) as? [String: Any])
    XCTAssertTrue(empty.isEmpty)
  }

  func testJSONPreservesNativeExactNumbersRatherThanRoutingThroughDouble() throws {
    let decimal = Decimal(string: "123456789012.34567890123456789", locale: Locale(identifier: "en_US_POSIX"))!
    let snapshot = QueryProjectionSnapshot(record: ["_long": .int(Int64.max), "_unsigned": .uint(UInt64.max), "_decimal": .decimal(decimal)])
    let bytes = try encoded(snapshot), text = String(decoding: bytes, as: UTF8.self)
    XCTAssertTrue(text.contains("9223372036854775807")); XCTAssertTrue(text.contains("18446744073709551615"))
    XCTAssertTrue(text.contains("123456789012.34567890123456789"))
    let decoded = try JSONDecoder().decode(TeaQLRecord.self, from: bytes)
    XCTAssertEqual(decoded["_long"], .int(Int64.max)); XCTAssertEqual(decoded["_unsigned"], .uint(UInt64.max))
    XCTAssertEqual(decoded["_decimal"], .decimal(decimal))
  }

  func testJSONPreservesNestedObjectsAndLiteralAliasPunctuation() throws {
    let alias = "_a.b/~\"中文", value = TeaQLValue.object(["items": .array([.null, .int(0), .string("é")])])
    let snapshot = QueryProjectionSnapshot(record: [alias: value])
    let decoded = try JSONDecoder().decode(TeaQLRecord.self, from: encoded(snapshot))
    XCTAssertEqual(decoded, [alias: value]); XCTAssertEqual(snapshot.value(alias), value)
  }

  func testJSONCanMergeWithModeledFieldsWithoutAProjectionWrapper() throws {
    let snapshot = QueryProjectionSnapshot(record: ["_count": .int(0), "_sum": .null])
    struct Owner: Encodable {
      let projection: any Encodable
      enum Keys: String, CodingKey { case id, name }
      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Int64(7), forKey: .id); try container.encode("owner", forKey: .name)
        try projection.encode(to: encoder)
      }
    }
    let bytes = try JSONEncoder().encode(Owner(projection: encodable(snapshot)))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    XCTAssertEqual(Set(json.keys), ["id", "name", "_count", "_sum"])
    XCTAssertEqual(json["name"] as? String, "owner"); XCTAssertTrue(json["_sum"] is NSNull)
    XCTAssertEqual(snapshot.value("_count"), .int(0))
    let emptyBytes = try JSONEncoder().encode(Owner(projection: encodable(QueryProjectionSnapshot())))
    let emptyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyBytes) as? [String: Any])
    XCTAssertEqual(Set(emptyJSON.keys), ["id", "name"])
    XCTAssertEqual(emptyJSON["name"] as? String, "owner")
  }
}
