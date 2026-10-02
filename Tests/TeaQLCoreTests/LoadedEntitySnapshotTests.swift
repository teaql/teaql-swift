import XCTest
@testable import TeaQLCore

final class LoadedEntitySnapshotTests: XCTestCase {
  func testEquivalentProviderValuesShareReferenceButNotWritableStorage() {
    let pool = LoadedEntitySnapshots()
    let key = EntityKey(entity: "Platform", id: .int(1))
    var providerRecord: TeaQLRecord = ["id": .int(1), "version": .int(1), "name": .string("original")]
    let first = pool.capture(key: key, version: 1, record: providerRecord)
    let second = pool.capture(key: key, version: 1, record: providerRecord)
    XCTAssertTrue(first === second)
    providerRecord["name"] = .string("changed provider buffer")
    var externalCopy = first.record
    externalCopy["name"] = .string("changed consumer buffer")
    XCTAssertEqual(first.record["name"], .string("original"))
    XCTAssertEqual(second.record, first.record)
  }

  func testTypesVersionsProjectionsAndQueriesDoNotAlias() {
    let pool = LoadedEntitySnapshots()
    let key = EntityKey(entity: "Platform", id: .int(1))
    let record: TeaQLRecord = ["id": .int(1), "version": .int(1)]
    let first = pool.capture(key: key, version: 1, record: record)
    let otherType = pool.capture(key: EntityKey(entity: "Payment", id: .int(1)), version: 1, record: record)
    let otherVersion = pool.capture(key: key, version: 2, record: record)
    let otherProjection = pool.capture(key: key, version: 1, record: record.merging(["name": .string("more")]) { _, new in new })
    let otherQuery = LoadedEntitySnapshots().capture(key: key, version: 1, record: record)
    XCTAssertFalse(first === otherType)
    XCTAssertFalse(first === otherVersion)
    XCTAssertFalse(first === otherProjection)
    XCTAssertFalse(first === otherQuery)
  }
}
