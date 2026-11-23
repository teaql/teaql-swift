import XCTest
@testable import TeaQLCore

private struct ReadOnlyIdentityEntity: TeaQLEntity {
  let id: Int64
  let version: Int64
  static let descriptor = EntityDescriptor(name: "ReadOnlyIdentityEntity", table: "read_only_identity", properties: [])
  static func from(record: TeaQLRecord) throws -> Self { Self(id: 7, version: 2) }
  func toRecord() -> TeaQLRecord { ["id": .int(id), "version": .int(version)] }
}

final class ReadOnlyIdentityTests: XCTestCase {
  func testRuntimeAcceptsReadOnlySystemFields() throws {
    let entity = try ReadOnlyIdentityEntity.from(record: [:])
    func systemValues<T: TeaQLEntity>(_ entity: T) -> (Int64, Int64) { (entity.id, entity.version) }
    let values = systemValues(entity)
    XCTAssertEqual(values.0, 7)
    XCTAssertEqual(values.1, 2)
    XCTAssertEqual(entity.toMutationRecord()["version"], .int(2))
  }
}
