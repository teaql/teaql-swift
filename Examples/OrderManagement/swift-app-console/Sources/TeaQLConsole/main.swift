import Foundation
import TeaQLCore
import TeaQLSQLite
#if canImport(GeneratedTeaQL)
import GeneratedTeaQL
#endif

actor ConsoleAuditSink: AuditSink {
  func record(_ event: AuditEvent) async throws {
    print("APP AUDIT: \(event.operation.rawValue) \(event.entity), reason=\(event.reason)")
  }
}

@main
enum OrderManagementApp {
  static func main() async throws {
    let path = CommandLine.arguments.dropFirst().first
      ?? FileManager.default.currentDirectoryPath + "/order-management.sqlite"
    let database = try SQLiteDataService(path: path)
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime()
    try runtime.install(module)
    let context = UserContext(
      runtime: runtime,
      actor: "swift-quick-start",
      activeRoot: ContextEntityRef(entity: "CommercePlatform", id: .int(1)),
      queryExecutor: database,
      mutationExecutor: database,
      requestPolicy: RequestPolicy { $0 },
      auditSink: ConsoleAuditSink()
    )
    try await context.ensureSchema(module)
    print("TeaQL SQLite: schema is ready")

    let existing = try await Q.customerOrders()
      .withOrderNumberIs("SWIFT-ORDER-001")
      .limit(1)
      .comment("Check whether the quick-start fixture already exists")
      .purpose("Make quick-start seeding idempotent")
      .executeForList(context)

    if existing.isEmpty {
      let customers = try await Q.customers().withNameIs("Swift quick-start customer").limit(1)
        .comment("Reuse the quick-start customer")
        .purpose("Create a valid foreign key without invented IDs").executeForList(context)
      let customer: Customer
      if let found = customers.first { customer = found }
      else {
        var draft = try await Q.customers().comment("Prepare the demo customer")
          .purpose("Seed the example through generated audited mutation").newEntity(context)
        draft.updateName("Swift quick-start customer")
        draft.updateEmail("swift-demo@example.com")
        draft.updateCommercePlatform(1)
        customer = try await draft.auditAs("Create the quick-start customer").save(context)
      }
      var order = try await Q.customerOrders().comment("Prepare the quick-start order")
        .purpose("Demonstrate generated audited save with automatic Checker/Fix").newEntity(context)
      order.updateOrderNumber("SWIFT-ORDER-001")
      order.updateOrderDate(context.businessTime)
      order.updateTotalAmount(Decimal(string: "129.95")!)
      order.updateStatusToPending()
      order.updateCustomer(customer.id)
      order.updateCommercePlatform(1)
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
        "ORDER \(order.id): \(try E.customerOrder(order).orderNumber().eval() ?? ""), total=\(order.totalAmount), version=\(order.version)"
      )
    }
    print("TeaQL query: returned \(orders.count) order(s); hard limit remains 10,000")
    print("TeaQL row audit: \(try await database.auditEvents().count) event(s)")
  }
}
