import XCTest
@testable import TeaQLCore

final class EntityRootTests: XCTestCase {
  func testTracksFinalValuesVersionsAndLifecycle() {
    let root = EntityRoot()
    let order = EntityKey(entity: "Order", id: .int(10))
    let line = EntityKey(entity: "OrderLine", id: .int(20))
    root.setOriginalVersion(order, version: 3)
    root.set(order, field: "status", value: .string("pending"))
    root.set(order, field: "status", value: .string("confirmed"))
    root.set(line, field: "quantity", value: .int(2))
    root.markAsNew(line)
    XCTAssertEqual(root.snapshot()[order]?["status"], .string("confirmed"))
    XCTAssertEqual(root.originalVersion(order), 3)
    XCTAssertTrue(root.isNew(line))
    root.markAsDeleted(line)
    XCTAssertTrue(root.isDeleted(line))
    XCTAssertNil(root.snapshot()[line])
    root.clearCommitted()
    XCTAssertTrue(root.snapshot().isEmpty)
    XCTAssertFalse(root.isNew(line))
    XCTAssertFalse(root.isDeleted(line))
  }
}
