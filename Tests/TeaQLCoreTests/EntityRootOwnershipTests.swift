import Foundation
import XCTest
@testable import TeaQLCore

final class EntityRootOwnershipTests: XCTestCase {
  func testLoadedVersionConflictPreservesPendingState() throws {
    let root = EntityRoot()
    let key = EntityKey(entity: "CustomerOrder", id: .int(1))
    try root.setOriginalVersion(key, version: 1)
    root.set(key, field: "name", value: .string("original pending"))
    XCTAssertThrowsError(try root.setOriginalVersion(key, version: 2))
    XCTAssertEqual(root.originalVersion(key), 1)
    XCTAssertEqual(root.change(key)["name"], .string("original pending"))
  }

  func testWholeImportRejectsConflictsBeforeAnyCopy() throws {
    let source = EntityRoot(), target = EntityRoot()
    let key = EntityKey(entity: "CustomerOrder", id: .int(1))
    let unrelated = EntityKey(entity: "OrderItem", id: .int(2))
    try source.setOriginalVersion(key, version: 2)
    try target.setOriginalVersion(key, version: 1)
    source.set(key, field: "name", value: .string("foreign pending"))
    source.set(unrelated, field: "name", value: .string("unreached"))
    source.markAsNew(unrelated)
    target.set(key, field: "name", value: .string("target pending"))
    XCTAssertThrowsError(try target.merge(from: source))
    XCTAssertEqual(target.originalVersion(key), 1)
    XCTAssertEqual(target.change(key)["name"], .string("target pending"))
    XCTAssertTrue(target.change(unrelated).isEmpty)
    XCTAssertFalse(target.isNew(unrelated))
    XCTAssertTrue(source.isNew(unrelated))
  }

  func testRekeyConflictPreservesBothKeys() throws {
    let root = EntityRoot()
    let old = EntityKey(entity: "CustomerOrder", id: .int(-1))
    let new = EntityKey(entity: "CustomerOrder", id: .int(1))
    try root.setOriginalVersion(old, version: 2)
    try root.setOriginalVersion(new, version: 1)
    root.markAsNew(old)
    root.set(old, field: "name", value: .string("old pending"))
    root.set(new, field: "name", value: .string("new pending"))
    XCTAssertThrowsError(try root.rekey(old, to: new))
    XCTAssertTrue(root.isNew(old))
    XCTAssertEqual(root.originalVersion(old), 2)
    XCTAssertEqual(root.originalVersion(new), 1)
    XCTAssertEqual(root.change(old)["name"], .string("old pending"))
    XCTAssertEqual(root.change(new)["name"], .string("new pending"))
  }

  func testScopedImportPreservesSourceAndExcludesUnreachedKeys() throws {
    let source = EntityRoot(), target = EntityRoot()
    let reached = EntityKey(entity: "OrderItem", id: .int(1))
    let unrelated = EntityKey(entity: "CustomerOrder", id: .int(1))
    try source.setOriginalVersion(reached, version: 3)
    try source.setOriginalVersion(unrelated, version: 9)
    source.set(reached, field: "name", value: .string("reached change"))
    source.set(unrelated, field: "description", value: .string("foreign root"))
    source.markAsNew(unrelated)
    source.setLocalAuditReason(reached, reason: "edit reached item")
    let scope = try TraceScopeToken(key: reached, reason: "edit reached item")
    source.setTraceChain(reached, chain: scope.recover())
    let before = source.snapshot()
    try target.mergeEntity(from: source, key: reached)
    XCTAssertEqual(target.change(reached)["name"], .string("reached change"))
    XCTAssertEqual(target.originalVersion(reached), 3)
    XCTAssertEqual(target.localAuditReason(reached), "edit reached item")
    XCTAssertEqual(target.traceChain(reached, fallback: scope), scope.recover())
    XCTAssertTrue(target.change(unrelated).isEmpty)
    XCTAssertNil(target.originalVersion(unrelated))
    XCTAssertFalse(target.isNew(unrelated))
    XCTAssertEqual(source.snapshot(), before)
    target.clearCommitted()
    XCTAssertEqual(source.snapshot(), before)
    XCTAssertEqual(source.localAuditReason(reached), "edit reached item")
  }

  func testLoadedIdentityAndAuditReasonAloneAreNotPendingMutation() throws {
    let root = EntityRoot()
    let key = EntityKey(entity: "Platform", id: .int(1))
    try root.setOriginalVersion(key, version: 1)
    root.setLocalAuditReason(key, reason: "readonly reference")
    root.setTraceChain(key, chain: try TraceScopeToken(key: key, reason: "readonly reference").recover())
    XCTAssertFalse(root.hasPending(key))
    root.set(key, field: "name", value: .string("modified"))
    XCTAssertTrue(root.hasPending(key))
    XCTAssertThrowsError(try root.acceptCommittedVersion(key, version: 2))
    XCTAssertEqual(root.originalVersion(key), 1)
    root.clearEntity(key)
    try root.acceptCommittedVersion(key, version: 2)
    XCTAssertFalse(root.hasPending(key))
    XCTAssertEqual(root.originalVersion(key), 2)
    XCTAssertThrowsError(try root.setOriginalVersion(key, version: 1))
  }

  func testScopedDeletedLifecycleDoesNotDrainSource() throws {
    let source = EntityRoot(), target = EntityRoot()
    let key = EntityKey(entity: "OrderItem", id: .int(2))
    try source.setOriginalVersion(key, version: 4)
    source.markAsDeleted(key)
    try target.mergeEntity(from: source, key: key)
    XCTAssertTrue(source.isDeleted(key))
    XCTAssertTrue(target.hasPending(key))
    XCTAssertTrue(target.isDeleted(key))
    XCTAssertEqual(target.originalVersion(key), 4)
    target.clearEntity(key)
    XCTAssertTrue(source.isDeleted(key))
  }

  func testConcurrentConflictingRegistrationHasExactlyOneWinner() throws {
    let root = EntityRoot()
    let key = EntityKey(entity: "CustomerOrder", id: .int(1))
    let results = RegistrationResults()
    let ready = DispatchSemaphore(value: 0), start = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    for version in [Int64(1), 2] {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        ready.signal(); start.wait()
        do { try root.setOriginalVersion(key, version: version); results.record(success: true) }
        catch { results.record(success: false) }
      }
    }
    XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    start.signal(); start.signal()
    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(results.counts().successes, 1)
    XCTAssertEqual(results.counts().failures, 1)
    XCTAssertTrue([Int64(1), 2].contains(try XCTUnwrap(root.originalVersion(key))))
  }
}

private final class RegistrationResults: @unchecked Sendable {
  private let lock = NSLock()
  private var successes = 0, failures = 0
  func record(success: Bool) {
    lock.withLock { if success { successes += 1 } else { failures += 1 } }
  }
  func counts() -> (successes: Int, failures: Int) { lock.withLock { (successes, failures) } }
}
