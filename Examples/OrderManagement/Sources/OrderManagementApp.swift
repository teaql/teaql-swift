import Foundation
import TeaQLCore
import TeaQLSQLite

actor ConsoleAuditSink: AuditSink {
  func record(_ event: AuditEvent) async throws {
    print("APP AUDIT: \(event.operation.rawValue) \(event.entity), reason=\(event.reason)")
  }
}

@main
enum OrderManagementApp {
  static func main() async throws {
    let path = FileManager.default.currentDirectoryPath + "/order-management.sqlite"
    let database = try SQLiteDataService(path: path)
    let descriptors = [
      CommercePlatform.descriptor, Customer.descriptor, OrderStatus.descriptor,
      CustomerOrder.descriptor, Product.descriptor, OrderLine.descriptor,
      OrderSearchPreset.descriptor,
    ]
    let context = UserContext(
      actor: "swift-quick-start",
      queryExecutor: database,
      mutationExecutor: database,
      requestPolicy: RequestPolicy { $0 },
      auditSink: ConsoleAuditSink()
    )
    try await context.ensureSchema(RuntimeModule(name: "OrderManagement", entities: descriptors))
    print("TeaQL SQLite: schema is ready")

    let existing = try await Q.customerOrders()
      .withOrderNumberIs("SWIFT-ORDER-001")
      .comment("Check whether the quick-start fixture already exists")
      .purpose("Make quick-start seeding idempotent")
      .executeForList(context)

    if existing.isEmpty {
      var order = CustomerOrder()
      order.orderNumber = "SWIFT-ORDER-001"
      order.orderDate = Date()
      order.totalAmount = Decimal(string: "129.95")!
      order.status = 1
      order.customer = 1
      order.commercePlatform = 1
      order.createTime = Date()
      order.updateTime = Date()
      order.version = 1
      _ = try await order.auditAs("Create the Swift quick-start order").save(context)
      print("TeaQL seed: created SWIFT-ORDER-001")
    }

    let orders = try await Q.customerOrders()
      .withOrderNumberContaining("SWIFT")
      .limit(20)
      .comment("SQLite order search from the Swift App Console")
      .purpose("Show recent matching orders")
      .executeForList(context)

    for order in orders {
      print(
        "ORDER \(order.id): \(order.orderNumber), total=\(order.totalAmount), version=\(order.version)"
      )
    }
    print("TeaQL query: returned \(orders.count) order(s); hard limit remains 10,000")
    print("TeaQL row audit: \(try await database.auditEvents().count) event(s)")
  }
}
