import XCTest
@testable import TeaQLCore

final class SmartListTests: XCTestCase {
  func testCollectionErgonomicsAndMetadata() {
    let facet = SmartList<TeaQLRecord>([["status": .string("OPEN")]])
    let rows = SmartList([1, 2]).withTotalCount(7).withFacet("status", facet)

    XCTAssertEqual(Array(rows), [1, 2])
    XCTAssertEqual(rows.first, 1)
    XCTAssertEqual(rows.totalCountOrCount, 7)
    XCTAssertEqual(rows.facet("status")?.count, 1)
    XCTAssertFalse(SmartList<Int>.empty.isLoaded)
  }
}
