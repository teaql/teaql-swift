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
}
