import Foundation
import GeneratedTeaQL
import TeaQLCore

func assignedGraph(_ context: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore, audit: AuditCapture) async throws {
    var root = try order(context, id: nil, label: "TRACE-ALLOCATED")
    var pay = try payment(context, id: nil, parentID: 0, label: "TRACE-ALLOCATED-PAYMENT")
    _ = pay.auditAs("authorize allocated payment")
    var attempt = try Q.paymentAttempts().comment("initialize allocated attempt")
        .purpose("verify late identity inheritance").newEntity(context)
    attempt.updatePayment(0); attempt.updateReferenceCode("TRACE-ALLOCATED-ATTEMPT")
    pay.paymentAttemptList.append(attempt); root.paymentList.append(pay)
    await commands.clear(); await sql.enableAll(); await audit.clear()
    let saved = try await root.auditAs("submit allocated order").save(context)
    let events = await audit.snapshot(), entries = await sql.snapshot().filter { $0.operation != .select }
    try require(events.count == 3 && entries.count == 3 && saved.id > 0, "allocated graph did not persist three nodes")
    guard let paymentID = events.first(where: { $0.entity == "Payment" })?.entityID?.int64Value
    else { throw TeaQLError.execution("allocated payment ID missing") }
    let parent = NodeExpectation(type: "CustomerOrder", id: saved.id, reason: "submit allocated order")
    let leaf = NodeExpectation(type: "Payment", id: paymentID, reason: "authorize allocated payment")
    for (index, event) in events.enumerated() {
        let expected = event.entity == "CustomerOrder" ? [parent] : [parent, leaf]
        try checkChain(event.mutationLineage ?? [], expected, boundary: "allocated committed audit")
        try checkChain(entries[index].mutationLineage, expected, boundary: "allocated physical SQL")
    }
    print("PASS assigned identities: generated root, child and grandchild; SQL/audit scopes contain no temporary IDs")
}

func ledgerReplacement(_ context: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore,
                       audit: AuditCapture, base: Int64) async throws {
    let rootID = base + 1_000, paymentID = rootID + 1
    var root = try order(context, id: rootID, label: "TRACE-LEDGER")
    let pay = try payment(context, id: paymentID, parentID: rootID, label: "TRACE-LEDGER-PAYMENT")
    _ = pay.auditAs("authorize graph fallback")
    let owned: any TeaQLMutationRootedEntity = pay
    owned.teaqlEntityRoot.setTraceChain(owned.teaqlEntityKey, chain: [
        TraceNode(entity: "CustomerOrder", comment: "submit ledger order", purpose: "", level: 0,
            kind: "auditReason", entityID: .int(rootID)),
        TraceNode(entity: "Payment", comment: "ledger-specific approval", purpose: "", level: 1,
            kind: "auditReason", entityID: .int(paymentID)),
    ])
    root.paymentList.append(pay)
    await commands.clear(); await sql.enableAll(); await audit.clear()
    _ = try await root.auditAs("submit ledger order").save(context)
    let parent = NodeExpectation(type: "CustomerOrder", id: rootID, reason: "submit ledger order")
    let expected = [key("CustomerOrder", rootID): [parent],
        key("Payment", paymentID): [parent, NodeExpectation(type: "Payment", id: paymentID, reason: "ledger-specific approval")]]
    try checkObservedGraph(expected, commands: await commands.snapshot(), sql: await sql.snapshot(),
        audit: await audit.snapshot(), rootReason: "submit ledger order")
    print("PASS generated graph consumes typed ledger-specific replacement, not fallback concatenation")
}

func sameIDVersions(_ context: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore,
                    audit: AuditCapture, base: Int64) async throws {
    let identity = base + 2_000
    var root = try await order(context, id: identity, label: "TRACE-SAME-ID").auditAs("seed typed identity").save(context)
    root.updateDescription("advance only root version")
    _ = try await root.auditAs("advance root version").save(context)
    _ = try await payment(context, id: identity, parentID: identity, label: "TRACE-SAME-ID-PAYMENT")
        .auditAs("seed payment version one").save(context)
    guard var loaded = try await Q.customerOrders().withIdIs(identity).limit(1)
        .selectPaymentListWith(Q.payments().limit(10))
        .comment("load different versions sharing one numeric ID").purpose("verify typed optimistic identity")
        .executeForList(context).first, loaded.paymentList.count == 1
    else { throw TeaQLError.execution("same-ID graph missing") }
    try require(loaded.version == 2 && loaded.paymentList[0].version == 1, "precondition versions are not 2/1")
    loaded.updateDescription("typed root update")
    loaded.paymentList[0].updateReferenceCode("TRACE-TYPED-UPDATED")
    _ = loaded.paymentList[0].auditAs("authorize typed payment")
    await commands.clear(); await sql.enableAll(); await audit.clear()
    _ = try await loaded.auditAs("submit typed order").save(context)
    let parent = NodeExpectation(type: "CustomerOrder", id: identity, reason: "submit typed order")
    try checkObservedGraph([key("CustomerOrder", identity): [parent],
        key("Payment", identity): [parent, NodeExpectation(type: "Payment", id: identity, reason: "authorize typed payment")]],
        commands: await commands.snapshot(), sql: await sql.snapshot(), audit: await audit.snapshot(), rootReason: "submit typed order")
    let observed = await commands.snapshot().map { $0.mutation }
    try require(observed.first?.expectedVersion == 2 && observed.last?.expectedVersion == 1,
        "same numeric ID reused another entity type's optimistic version")
    let reloaded = try await loadOrder(context, id: identity)
    try require(reloaded.version == 3, "root version was not advanced independently")
    print("PASS same-ID/different-type generated updates preserve versions 2/1 and separate lineages")
}

func concurrentGraphs(_ context: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore,
                      audit: AuditCapture, base: Int64) async throws {
    await commands.clear(); await sql.enableAll(); await audit.clear()
    @Sendable func save(_ id: Int64, label: String) async throws {
        var root = try order(context, id: id, label: "TRACE-\(label)")
        let pay = try payment(context, id: id, parentID: id, label: "TRACE-\(label)-PAYMENT")
        _ = pay.auditAs("authorize \(label)")
        root.paymentList.append(pay)
        await Task.yield()
        _ = try await root.auditAs("submit \(label)").save(context)
    }
    async let first: Void = save(base + 3_000, label: "graph-A")
    async let second: Void = save(base + 4_000, label: "graph-B")
    _ = try await (first, second)
    let events = await audit.snapshot(), entries = await sql.snapshot(), requests = await commands.snapshot()
    try require(events.count == 4 && entries.count == 4 && requests.count == 4, "concurrent graph cardinality differs")
    for (id, label) in [(base + 3_000, "graph-A"), (base + 4_000, "graph-B")] {
        let parent = NodeExpectation(type: "CustomerOrder", id: id, reason: "submit \(label)")
        let expected = [key("CustomerOrder", id): [parent], key("Payment", id): [parent,
            NodeExpectation(type: "Payment", id: id, reason: "authorize \(label)")]]
        try checkObservedGraph(expected,
            commands: requests.filter { $0.intent.comment == "submit \(label)" },
            sql: entries.filter { $0.auditReason == "submit \(label)" },
            audit: events.filter { $0.reason == "submit \(label)" }, rootReason: "submit \(label)")
    }
    print("PASS overlapping Tasks use one Context without sharing graph reasons or typed identities")
}
