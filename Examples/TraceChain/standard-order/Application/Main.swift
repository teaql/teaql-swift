import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
import TeaQLStandardTelemetry

private actor Audits: AuditSink {
  private var count = 0
  func record(_ event: AuditEvent) { count += 1 }
  func value() -> Int { count }
}

@main enum StandardOrderVerification {
  static func main() async {
    do { try await run() }
    catch {
      FileHandle.standardError.write(Data("FAIL Swift standard Order: \(type(of: error))\n".utf8))
      exit(1)
    }
  }
  private static func require(_ ok: Bool, _ reason: String) throws {
    guard ok else { throw TeaQLError.execution(reason) }
  }
  private static func run() async throws {
    guard let database = CommandLine.arguments.dropFirst().first else {
      throw TeaQLError.execution("provide a retained SQLite path")
    }
    StandardTelemetryModule.install()
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let service = try SQLiteDataService(path: database), audit = Audits()
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit,
      querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    let first = await audit.value()
    try require(first == 0 || first == 4, "generated root and three constants")
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    try require(await audit.value() == first, "repeated schema seed")
    let secret = "ORDER-PRIVATE-" + UUID().uuidString
    var customer = try Q.customers().comment("create customer").purpose("prepare standard Order graph").newEntity(context)
    customer.updatePlatform(1); customer.updateName("North Star Retail"); customer.updateVersion(1)
    customer = try await customer.auditAs("seed standard customer").save(context)
    for index in 0..<4 {
      var order = try Q.customerOrders().comment("create order").purpose("prepare standard Order graph").newEntity(context)
      order.updateCustomer(customer.id); order.updateStatus(index == 0 ? 1001 : 1002)
      order.updateOrderNumber(index == 3 ? "OTHER-004" : secret + String(format: "-%03d", index + 1))
      order.updateOrderDate(Date(timeIntervalSince1970: 1_790_812_800 + Double(index) * 86_400))
      order.updateTotalAmount(Decimal(index == 3 ? 900 : (index + 1) * 100)); order.updateVersion(1)
      order = try await order.auditAs("seed standard order").save(context)
      for number in 1...5 {
        var item = try Q.orderItems().comment("create item").purpose("prepare bounded previews").newEntity(context)
        item.updateCustomerOrder(order.id); item.updateProductName("Box \(number)")
        item.updateQuantity(Int64(number)); item.updateUnitPrice(20); item.updateVersion(1)
        _ = try await item.auditAs("seed standard item").save(context)
      }
    }
    for repetition in 0..<4 {
      let counted = repetition < 2
      var request = Q.customerOrdersWithMinimalFields().withOrderNumberContaining(secret)
        .facetByStatusAs("statusCounts", Q.orderStatusesWithMinimalFields().selectName().selectColor().countAs("orderCount")
          .sumTotalAmountOfCustomerOrdersAs("orderTotalAmount", Q.customerOrdersWithMinimalFields())
          .orderByDisplayOrderAscending().comment("load status facets"))
        .selectOrderNumber().selectOrderDate()
        .selectStatusWith(Q.orderStatusesWithMinimalFields().selectName().selectColor().comment("load status"))
        .selectOrderItemListWith(Q.orderItemsWithMinimalFields().selectProductName().selectQuantity()
          .orderByIdAscending().limit(3).comment("load item previews"))
        .countOrderItemsAs("itemCount").orderByOrderDateDescending().orderByIdDescending()
        .offset(1).limit(1).comment("load order list")
      if counted { request = request.countAs("totalOrders") }
      let rows = try await request.purpose("render order list page").executeForList(context)
      try require(rows.count == 1, "bounded list")
      if counted { try require(rows.totalCount == 3 && rows.aggregations["totalOrders"] == .int(3), "exact filtered total") }
      else { try require(rows.aggregations.isEmpty, "no implicit exact count") }
      guard let row = rows.first else { throw TeaQLError.execution("missing selected row") }
      try require(E.customerOrder(row).orderNumber().eval() == secret + "-002", "selected order")
      try require(E.customerOrder(row).status().name().eval() == "Paid", "forward detail")
      try require(E.customerOrder(row).orderItemList().size().eval() == 3, "bounded preview")
      try require(E.customerOrder(row).orderItemList().first().productName().eval() == "Box 1", "sorted preview")
      try require(row.dynamicProperties.value("itemCount") == .int(5), "full child count")
      guard let facets = rows.facets["statusCounts"] else { throw TeaQLError.execution("missing facets") }
      try require(facets.count == 3, "facet cardinality")
      for index in 0..<3 {
        try require(facets[index]["id"] == .int(Int64(1001 + index)), "facet order")
        try require(facets[index]["orderCount"] == .int([1, 2, 0][index]), "filtered facet count")
        if index < 2 { try require(facets[index]["orderTotalAmount"]?.decimalValue == Decimal([100, 500][index]), "facet sum") }
        else { try require(facets[index]["orderTotalAmount"] == .null, "empty SUM is null") }
      }
    }
    try require(await audit.value() == first + 25, "independent committed audit")
    await context.runtimeTelemetry.flush(); await context.runtimeTelemetry.shutdown()
    print("SWIFT_STANDARD_ORDER PASSED queries=4 counted=2 uncounted=2 total=3 preview=3 itemCount=5 facets=3 first_seed_audits=\(first) repeat_seed_audits=0 audits=\(await audit.value()) ordinary_sql_logs=0 database=\(database)")
  }
}
