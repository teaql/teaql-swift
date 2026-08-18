import XCTest
@testable import TeaQLCore

final class RuntimeTelemetryTests: XCTestCase {
  func testOperationDropsSensitiveAttributesAndNoopReturnsBodyValue() async throws {
    let operation = RuntimeOperation(
      family: "query", name: "School.list",
      attributes: [
        "teaql.entity.type": .string("School"),
        "teaql.entity.id": .integer(42),
        "teaql.audit.reason": .string("secret"),
      ])

    XCTAssertEqual(operation.attributes["teaql.entity.type"], .string("School"))
    XCTAssertNil(operation.attributes["teaql.entity.id"])
    XCTAssertNil(operation.attributes["teaql.audit.reason"])
    let result = try await NoopRuntimeTelemetry().withOperation(operation) { 7 }
    XCTAssertEqual(result, 7)
  }
}
