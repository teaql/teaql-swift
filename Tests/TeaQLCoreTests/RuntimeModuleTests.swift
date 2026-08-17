import XCTest
@testable import TeaQLCore

final class RuntimeModuleTests: XCTestCase {
  private let first = EntityDescriptor(
    name: "First", table: "first_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])

  func testPassiveModulesInstallAndComposeDeterministically() throws {
    let module = RuntimeModule(name: "example", entities: [first])
    XCTAssertEqual(module.entities, [first])

    var runtime = TeaQLRuntime()
    try runtime.install(module)
    try runtime.install(module)
    XCTAssertEqual(runtime.entities, [first])
    XCTAssertEqual(runtime.entity(named: "First"), first)
  }

  func testConflictingDescriptorsFailInstallation() throws {
    let conflict = EntityDescriptor(
      name: "First", table: "other_data",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "one", entities: [first]))
    XCTAssertThrowsError(
      try runtime.install(RuntimeModule(name: "two", entities: [conflict])))
  }
}
