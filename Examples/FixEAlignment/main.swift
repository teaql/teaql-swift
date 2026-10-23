import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ value: Bool, _ message: String) throws {
  if !value { throw TeaQLError.execution(message) }
}

private func missing<T>(
  _ read: () throws -> T, at location: String, attempted: String, expression: String
) throws -> NotLoadedDiagnostic {
  do { _ = try read() }
  catch let error as TeaQLCore.TeaQLNotLoadedError {
    let wire = error.toWire()
    try require(wire.code == "NOT_LOADED", "Wrong NotLoaded code")
    try require(wire.instancePath == location, "Wrong first missing location")
    try require(wire.attemptedInstancePath == attempted, "Lost the attempted suffix")
    try require(wire.expressionWithBrokenPoint == expression, "Wrong native chain or breakpoint")
    try require(!error.description.contains("PRIVATE-FALLBACK"), "Error exported a fallback value")
    return wire
  }
  throw TeaQLError.execution("NotLoaded must not become null or a fallback")
}

@main enum FixEAlignment {
  static func main() async throws {
    let first = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    let second = first.addingTimeInterval(25 * 3600)
    let service = try SQLiteDataService(path: ":memory:")
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime()
    try runtime.install(module)
    func context(at time: Date) -> UserContext {
      UserContext(runtime: runtime, actor: "fix-e-example",
        activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
        queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        businessClock: FixedBusinessClock(time))
    }
    let initialContext = context(at: first)
    try await initialContext.ensureSchema(module)
    var draft = try Q.purchaseOrders().comment("Prepare the synthetic clock fixture")
      .purpose("Verify generated audited save and E diagnostics").newEntity(initialContext)
    draft.updateContactPhone("5550100")
    let order = try await draft.auditAs("Create the synthetic Fix order").save(initialContext)
    try require(try E.purchaseOrder(order).createTime().eval() == first, "Create time did not consume T0")
    try require(try E.purchaseOrder(order).updateTime().eval() == first, "Update time did not consume T0")
    try require(try E.purchaseOrder(order).tenantId().eval() == 1, "Declared context root was not injected")
    try require(try E.purchaseOrder(order).internalNote().orElse("fallback") == "fallback",
                "Loaded null must retain fallback behavior")

    let rows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(order.id).limit(1)
      .comment("Load the identity projection without eager data")
      .purpose("Verify complete E diagnostics without implicit loading").executeForList(initialContext)
    try require(rows.count == 1, "Missing saved order")
    let partial = rows[0]
    let diagnostics = [
      try missing({ try E.purchaseOrder(partial).tenant().name().eval() },
        at: "/tenant", attempted: "/tenant/name",
        expression: "E.purchaseOrder(<root>).tenant()<broken>.name().eval()"),
      try missing({ try E.purchaseOrder(partial).tenant().purchaseOrderList().first().tenant().name().eval() },
        at: "/tenant", attempted: "/tenant/purchaseOrderList/0/tenant/name",
        expression: "E.purchaseOrder(<root>).tenant()<broken>.purchaseOrderList().first().tenant().name().eval()"),
      try missing({ try E.purchaseOrder(partial).orderItemList().get(2).productName().eval() },
        at: "/orderItemList", attempted: "/orderItemList/2/productName",
        expression: "E.purchaseOrder(<root>).orderItemList()<broken>.get(2).productName().eval()"),
      try missing({ try E.purchaseOrder(partial).contactPhone().orElse("PRIVATE-FALLBACK") },
        at: "/contactPhone", attempted: "/contactPhone",
        expression: "E.purchaseOrder(<root>).contactPhone()<broken>.orElse(<fallback>)")
    ]
    let updateContext = context(at: second)
    let beforeUpdate = try await Q.purchaseOrders().withIdIs(order.id).limit(1)
      .comment("Reload the complete order before changing it")
      .purpose("Verify update Fix preserves create time").executeForList(updateContext)
    try require(beforeUpdate.count == 1, "Missing order before update")
    var loaded = beforeUpdate[0]
    loaded.updateContactPhone("5550101")
    _ = try await loaded.auditAs("Update the synthetic Fix order").save(updateContext)
    let afterUpdate = try await Q.purchaseOrders().withIdIs(order.id).limit(1)
      .comment("Reload the persisted update")
      .purpose("Verify Business Clock values using E").executeForList(updateContext)
    try require(afterUpdate.count == 1, "Missing updated order")
    let persisted = afterUpdate[0]
    try require(try E.purchaseOrder(persisted).createTime().eval() == first, "Create time was not preserved")
    try require(try E.purchaseOrder(persisted).updateTime().eval() == second, "Update time did not advance to T1")
    try require(try E.purchaseOrder(persisted).contactPhone().eval() == "5550101", "Business input was not updated")
    struct Result: Encodable {
      let language = "swift", passed = true, normalGeneratedSave = true
      let createTimePreserved = true, updateTimeAdvanced = true, declaredContextRootInjected = true
      let diagnostics: [NotLoadedDiagnostic]
    }
    let bytes = try JSONEncoder().encode(Result(diagnostics: diagnostics))
    print("FIX_E_EXAMPLE=" + String(decoding: bytes, as: UTF8.self))
  }
}
