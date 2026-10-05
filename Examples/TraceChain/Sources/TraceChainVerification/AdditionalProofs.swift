import Foundation
import GeneratedTeaQL
import TeaQLCore

private struct AssignedCommand: Encodable {
    let entity: String, operation: String
    let id: Int64?, lineage: [TraceNode]
    init(_ request: MutationRequest) {
        entity = request.mutation.entity.name; operation = request.mutation.kind.rawValue
        id = (request.mutation.id ?? request.mutation.values["id"])?.int64Value
        lineage = request.mutation.mutationLineage ?? []
    }
}

private struct AssignedSQL: Encodable {
    let sql: String, operation: String, outcome: String?, comment: String?, purpose: String?, reason: String?
    let parameters: [TeaQLValue], lineage: [TraceNode], path: [TraceNode]
    let affectedRows: Int?, resultCount: Int?
    init(_ entry: SQLExecutionMetadata) {
        sql = entry.parameterizedSQL; operation = entry.operation.rawValue; outcome = entry.executionOutcome
        comment = entry.comment; purpose = entry.purpose; reason = entry.auditReason
        parameters = entry.parameters; lineage = entry.mutationLineage; path = entry.tracePath
        affectedRows = entry.affectedRows; resultCount = entry.resultCount
    }
}

private struct AssignedAudit: Encodable {
    let entity: String
    let id: Int64?, lineage: [TraceNode]
    init(_ event: AuditEvent) {
        entity = event.entity; id = event.entityID?.int64Value; lineage = event.mutationLineage ?? []
    }
}

private struct AssignedGraphObservation: Encodable {
    let logging: Bool
    let before: [String: Int64]
    let commands: [AssignedCommand], sql: [AssignedSQL], audit: [AssignedAudit]
}

func assignedGraph(_ originalContext: UserContext, commands: CommandCapture, sql: SQLExecutionEvidenceStore, audit: AuditCapture) async throws {
    for logging in [false, true] {
    var context = originalContext
    context.querySQLLogEnabled = logging; context.mutationSQLLogEnabled = logging
    var root = try order(context, id: nil, label: "TRACE-ALLOCATED")
    var pay = try payment(context, id: nil, parentID: 0, label: "TRACE-ALLOCATED-PAYMENT")
    _ = pay.auditAs("authorize allocated payment")
    var attempt = try Q.paymentAttempts().comment("initialize allocated attempt")
        .purpose("verify late identity inheritance").newEntity(context)
    attempt.updatePayment(0); attempt.updateReferenceCode("TRACE-ALLOCATED-ATTEMPT")
    pay.paymentAttemptList.append(attempt); root.paymentList.append(pay)
    var sibling = try Q.orderItems().comment("initialize allocated unannotated sibling")
        .purpose("verify child responsibility cannot contaminate siblings").newEntity(context)
    sibling.updateCustomerOrder(0); sibling.updateName("TRACE-ALLOCATED-SIBLING")
    root.orderItemList.append(sibling)
    let before = ["CustomerOrder": root.id, "Payment": pay.id, "PaymentAttempt": attempt.id, "OrderItem": sibling.id]
    try require(before.values.allSatisfy { $0 <= 0 }, "allocation fixture must not set persistent IDs before save")
    await commands.clear(commitBarrier: true); await sql.enableAll(); await audit.clear()
    let saved = try await root.auditAs("submit allocated order").save(context)
    let events = await audit.snapshot(), physical = await sql.snapshot(), requests = await commands.snapshot()
    let entries = physical.filter { $0.operation != .select }, reads = physical.filter { $0.operation == .select }
    try require(events.count == 4 && entries.count == 4 && reads.count == 4 && saved.id > 0,
        "allocated graph did not persist and read back four nodes")
    guard let paymentID = events.first(where: { $0.entity == "Payment" })?.entityID?.int64Value,
          let attemptID = events.first(where: { $0.entity == "PaymentAttempt" })?.entityID?.int64Value,
          let siblingID = events.first(where: { $0.entity == "OrderItem" })?.entityID?.int64Value
    else { throw TeaQLError.execution("allocated graph IDs missing") }
    let parent = NodeExpectation(type: "CustomerOrder", id: saved.id, reason: "submit allocated order")
    let leaf = NodeExpectation(type: "Payment", id: paymentID, reason: "authorize allocated payment")
    let expected = [key("CustomerOrder", saved.id): [parent], key("OrderItem", siblingID): [parent],
        key("Payment", paymentID): [parent, leaf], key("PaymentAttempt", attemptID): [parent, leaf]]
    // SQLite allocates in INSERT. Keep the actual pre-allocation request;
    // do not manufacture an assigned command ID from the returned metadata.
    try require(requests.count == 4, "allocated graph lost a real create command")
    var observedTypes: Set<String> = []
    for (index, request) in requests.enumerated() {
        let type = request.mutation.entity.name
        guard let event = events.first(where: { $0.entity == type }), let id = event.entityID?.int64Value,
              let wanted = expected[key(type, id)] else { throw TeaQLError.execution("allocated command target missing") }
        try require(observedTypes.insert(type).inserted && request.mutation.kind == .create
            && request.mutation.id == nil && request.mutation.values["id"] == nil
            && request.intent.comment == "submit allocated order", "pre-allocation command was rewritten")
        let lineage = request.mutation.mutationLineage ?? []
        var planned = wanted
        if wanted.last?.type == type {
            guard let temporary = lineage.last?.entityID?.int64Value, temporary <= 0
            else { throw TeaQLError.execution("pre-allocation scope must retain its temporary typed key") }
            planned[planned.count - 1] = NodeExpectation(type: type, id: temporary, reason: wanted.last!.reason)
        }
        try checkChain(lineage, planned, boundary: "pre-allocation command \(type)")
        let write = physical[index * 2], read = physical[index * 2 + 1]
        try require(write.operation == .insert && write.affectedRows == 1 && write.executionOutcome == "success"
            && read.operation == .select && read.resultCount == 1 && read.executionOutcome == "success"
            && read.parameters == [.int(id)], "assigned physical identity or write/readback outcome differs")
        try require(write.tracePath.first?.name == "CustomerOrder"
            && write.tracePath.first(where: { $0.kind == "entity" })?.name == type
            && read.tracePath.map(\.kind) == ["operation", "request", "provider", "sql"],
            "allocated physical route is not canonical")
        try require(write.auditReason == "submit allocated order" && read.auditReason == "submit allocated order"
            && read.comment == "submit allocated order" && read.purpose == "verify the persisted mutation result",
            "assigned readback lost originating intent")
        try checkChain(write.mutationLineage, wanted, boundary: "allocated physical SQL \(type)")
        try checkChain(read.mutationLineage, wanted, boundary: "allocated SELECT readback \(type)")
        try checkChain(event.mutationLineage ?? [], wanted, boundary: "allocated committed audit \(type)")
    }
    let observation = AssignedGraphObservation(logging: logging, before: before,
        commands: requests.map(AssignedCommand.init), sql: physical.map(AssignedSQL.init), audit: events.map(AssignedAudit.init))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print("ASSIGNED_IDENTITY_OBSERVED " + String(decoding: try encoder.encode(observation), as: UTF8.self))
    guard let loaded = try await Q.customerOrders().withIdIs(saved.id).limit(1)
        .selectPaymentListWith(Q.payments().selectPaymentAttemptListWith(Q.paymentAttempts().limit(10)).limit(10))
        .selectOrderItemListWith(Q.orderItems().limit(10))
        .comment("independently reload allocated graph").purpose("verify persisted assigned typed identities")
        .executeForList(context).first
    else { throw TeaQLError.execution("allocated root missing from independent Q reload") }
    try require(loaded.version == 1 && loaded.paymentList.count == 1 && loaded.orderItemList.count == 1
        && loaded.paymentList[0].version == 1 && loaded.paymentList[0].paymentAttemptList.count == 1
        && loaded.paymentList[0].paymentAttemptList[0].version == 1 && loaded.orderItemList[0].version == 1,
        "allocated graph membership or original versions differ")
    try require(try E.customerOrder(loaded).paymentList().first().id().eval() == paymentID
        && E.customerOrder(loaded).orderItemList().first().id().eval() == siblingID
        && E.paymentAttempt(loaded.paymentList[0].paymentAttemptList[0]).id().eval() == attemptID,
        "independent E traversal does not match assigned command identities")
    print("PASS assigned identity logging=\(logging): actual command/SQL/audit, unannotated sibling and independent Q/E reload")
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
    // A complete chain belongs to one typed key, not to the entire graph.
    let siblingID = rootID + 2
    var sibling = try Q.orderItems().comment("initialize unannotated ledger sibling")
        .purpose("verify independent graph fallback").newEntity(context)
    sibling.updateId(siblingID)
    sibling.updateCustomerOrder(rootID)
    sibling.updateName("Ledger fallback sibling")
    root.orderItemList.append(sibling)
    await commands.clear(); await sql.enableAll(); await audit.clear()
    _ = try await root.auditAs("submit ledger order").save(context)
    let parent = NodeExpectation(type: "CustomerOrder", id: rootID, reason: "submit ledger order")
    let expected = [key("CustomerOrder", rootID): [parent],
        key("OrderItem", siblingID): [parent],
        key("Payment", paymentID): [parent, NodeExpectation(type: "Payment", id: paymentID, reason: "ledger-specific approval")]]
    try checkObservedGraph(expected, commands: await commands.snapshot(), sql: await sql.snapshot(),
        audit: await audit.snapshot(), rootReason: "submit ledger order")
    print("PASS generated graph consumes typed ledger-specific replacement, not fallback concatenation")
    print("PASS Swift generated ledger override: Payment replaces fallback; independent OrderItem inherits only root at command/SQL/audit")
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
    try require(events.count == 4 && entries.count == 8 && requests.count == 4, "concurrent graph cardinality differs")
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
