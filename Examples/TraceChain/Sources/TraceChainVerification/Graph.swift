import Foundation
import GeneratedTeaQL
import TeaQLCore

func order(_ context: UserContext, id: Int64?, label: String) throws -> CustomerOrder {
    var value = try Q.customerOrders().comment("initialize order")
        .purpose("construct trace verification graph").newEntity(context)
    if let id { value.updateId(id) }
    value.updatePlatform(1)
    value.updateOrderNumber(label)
    value.updateDescription("Draft order")
    return value
}

func payment(_ context: UserContext, id: Int64?, parentID: Int64, label: String) throws -> Payment {
    var value = try Q.payments().comment("initialize payment")
        .purpose("compose order graph").newEntity(context)
    if let id { value.updateId(id) }
    value.updateCustomerOrder(parentID)
    value.updateReferenceCode(label)
    return value
}

func loadOrder(_ context: UserContext, id: Int64) async throws -> CustomerOrder {
    guard let value = try await Q.customerOrders().withIdIs(id).limit(1)
        .comment("load complete current order").purpose("mutate a fully loaded entity")
        .executeForList(context).first
    else { throw TeaQLError.execution("order was not persisted") }
    return value
}

func normativeGraph(
    _ context: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore,
    audit: AuditCapture, base: Int64
) async throws {
    // Seed only through generated APIs. The removed child must already exist.
    _ = try await order(context, id: base, label: "TRACE-\(base)").auditAs("seed draft order").save(context)
    var unavailable = try Q.orderItems().comment("initialize unavailable item")
        .purpose("prepare loaded deletion fixture").newEntity(context)
    unavailable.updateId(base + 102)
    unavailable.updateCustomerOrder(base)
    unavailable.updateName("Unavailable item")
    unavailable = try await unavailable.auditAs("seed unavailable item").save(context)
    var root = try await loadOrder(context, id: base)
    root.updateDescription("Submitted order")
    var available = try Q.orderItems().comment("initialize available item")
        .purpose("compose normative graph").newEntity(context)
    available.updateId(base + 101)
    available.updateName("Available item")
    available.updateCustomerOrder(base)
    unavailable.markForDeletion()
    _ = unavailable.auditAs("remove unavailable item")
    var pay = try payment(context, id: base + 201, parentID: base, label: "TRACE-PAYMENT")
    _ = pay.auditAs("authorize payment")
    var attempt = try Q.paymentAttempts().comment("initialize attempt")
        .purpose("compose payment graph").newEntity(context)
    attempt.updateId(base + 301)
    attempt.updatePayment(pay.id)
    attempt.updateReferenceCode("TRACE-ATTEMPT")
    pay.paymentAttemptList.append(attempt)
    var shipment = try Q.shipments().comment("initialize shipment")
        .purpose("compose order graph").newEntity(context)
    shipment.updateId(base + 401)
    shipment.updateCustomerOrder(base)
    shipment.updateReferenceCode("TRACE-SHIPMENT")
    _ = shipment.auditAs("dispatch shipment")
    root.orderItemList = [available, unavailable]
    root.paymentList.append(pay)
    root.shipmentList.append(shipment)
    await audit.clear(); await sql.enableAll(); await commands.clear(commitBarrier: true)
    _ = try await root.auditAs("submit order").save(context)
    let parent = NodeExpectation(type: "CustomerOrder", id: base, reason: "submit order")
    let payNode = NodeExpectation(type: "Payment", id: base + 201, reason: "authorize payment")
    let expected: [String: [NodeExpectation]] = [
        key("CustomerOrder", base): [parent], key("OrderItem", base + 101): [parent],
        key("OrderItem", base + 102): [parent, NodeExpectation(type: "OrderItem", id: base + 102, reason: "remove unavailable item")],
        key("Payment", base + 201): [parent, payNode], key("PaymentAttempt", base + 301): [parent, payNode],
        key("Shipment", base + 401): [parent, NodeExpectation(type: "Shipment", id: base + 401, reason: "dispatch shipment")],
    ]
    try checkObservedGraph(expected, commands: await commands.snapshot(), sql: await sql.snapshot(),
        audit: await audit.snapshot(), rootReason: "submit order")
    let deletes = await audit.snapshot().filter { $0.operation == .delete }
    try require(deletes.count == 1 && deletes.first?.entityID == .int(base + 102), "delete not audited")
    await commands.clear()
    let deleted = try await Q.orderItems().withIdIs(base + 102).deletedRowsOnly().limit(1)
        .comment("inspect marked deletion").purpose("verify negative version and local reason")
        .executeForList(context)
    try require(deleted.count == 1 && deleted[0].version < 0, "deletion was not persisted")
    let loaded = try await Q.customerOrders().withIdIs(base).limit(1)
        .selectOrderItemListWith(Q.orderItems().limit(10))
        .selectPaymentListWith(Q.payments().selectPaymentAttemptListWith(Q.paymentAttempts().limit(10)).limit(10))
        .selectShipmentListWith(Q.shipments().limit(10))
        .comment("load saved order graph").purpose("verify generated Q and E lists")
        .executeForList(context)
    try require(loaded.count == 1, "graph query missed root")
    try require(try E.customerOrder(loaded[0]).orderItemList().size().eval() == 1,
        "generated E did not exclude deleted child")
    try require(try E.customerOrder(loaded[0]).paymentList().first().id().eval() == base + 201,
        "generated E payment identity differs")
    print("PASS normative graph: six real commands/SQL/committed audits; root=\(base), deletion=\(base + 102)")
}

func generatedThreeLevelQuery(_ context: UserContext, sql: SQLExecutionEvidenceStore, base: Int64) async throws {
    await sql.enableSelect()
    let comment = "load payment attempt business graph", purpose = "prove three generated relation levels"
    let rows = try await Q.paymentAttempts().withIdIs(base + 301).limit(1)
        .selectPaymentWith(Q.payments().limit(1)
            .selectCustomerOrderWith(Q.customerOrders().limit(1)
                .selectPlatformWith(Q.platforms().limit(1))))
        .comment(comment).purpose(purpose).executeForList(context)
    guard let row = rows.first, let pay = try E.paymentAttempt(row).payment().eval(),
          let root = try E.payment(pay).customerOrder().eval(),
          let platform = try E.customerOrder(root).platform().eval()
    else { throw TeaQLError.execution("generated Q/E graph was not loaded") }
    try require(try E.platform(platform).name().eval() == "Trace Chain Verification", "deep E value differs")
    let entries = await sql.snapshot()
    try require(entries.count == 4, "three-level query did not execute four statements")
    let names = ["payment", "customerOrder", "platform"]
    let details = ["PaymentAttempt.payment", "Payment.customerOrder", "CustomerOrder.platform"]
    for (depth, entry) in entries.enumerated() {
        let relations = entry.tracePath.filter { $0.kind == "relation" }
        try require(relations.map(\.name) == Array(names.prefix(depth))
            && relations.map(\.comment) == Array(details.prefix(depth)), "relation route lost at depth \(depth)")
        try require(entry.tracePath.first?.name == "PaymentAttempt" && entry.comment == comment
            && entry.purpose == purpose && entry.tracePath.last?.name == "select",
            "derived query lost originating request intent")
    }
    print("PASS generated three-level Q/E: PaymentAttempt.payment -> Payment.customerOrder -> CustomerOrder.platform")
    let hidden = try await Q.payments().withIdIs(base + 201).limit(1)
        .selectCustomerOrderWith(Q.customerOrders().withIdIs(0).limit(1))
        .comment("load filtered forward identity").purpose("distinguish NotLoaded detail from null")
        .executeForList(context)
    guard let hiddenPayment = hidden.first,
          let identity = try E.payment(hiddenPayment).customerOrder().eval()
    else { throw TeaQLError.execution("filtered detail erased the real reference") }
    try require(try E.customerOrder(identity).id().eval() == base, "filtered reference lost its FK")
    func assertUnfetched() throws {
        do {
            _ = try E.customerOrder(identity).description().eval()
        } catch {
            try require(String(describing: error).contains("NotLoaded"), "wrong hidden-detail error: \(error)")
            return
        }
        throw TeaQLError.execution("hidden detail became loaded-null")
    }
    try assertUnfetched()
    let visible = try await Q.payments().withIdIs(base + 201).limit(1)
        .selectCustomerOrderWith(Q.customerOrders().withIdIs(base).limit(1))
        .comment("load independent full reference").purpose("verify edge-owned load boundaries")
        .executeForList(context)
    guard let visiblePayment = visible.first,
          let full = try E.payment(visiblePayment).customerOrder().eval()
    else { throw TeaQLError.execution("full reference was not loaded") }
    try require(try E.customerOrder(full).description().eval() != nil, "full detail missing")
    try assertUnfetched()
    print("PASS FORWARD_NOTLOADED: generated Q/E keeps identity, hidden detail fails closed")
}
