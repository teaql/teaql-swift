import XCTest
@testable import TeaQLCore

final class ObjectLocationTests: XCTestCase {
  func testRendersCanonicalNativeAndJSONPaths() {
    let location = ObjectLocation().property("order_items").index(2).property("user_url")
    XCTAssertEqual(location.modelPath, "order_items[2].user_url")
    XCTAssertEqual(location.nativePath, "orderItems[2].userUrl")
    XCTAssertEqual(location.instancePath, "/orderItems/2/userUrl")
  }

  func testDescriptorResolvesCanonicalModelNameIndependentlyOfStorageName() {
    let descriptor = EntityDescriptor(
      name: "User", table: "user_data",
      properties: [PropertyDescriptor(
        name: "userEmail", modelName: "user_email", column: "email_address", type: .string)])
    XCTAssertEqual(descriptor.property(named: "user_email")?.name, "userEmail")
  }
}
