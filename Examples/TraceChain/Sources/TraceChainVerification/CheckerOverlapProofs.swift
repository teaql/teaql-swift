import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

/// Pauses a real BEGIN, not a Checker result, so both public calls stay live.
private actor CheckerBeginPause {
    private var entered = false, released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor CheckerInvocations {
    private var active = 0, maximum = 0
    private var bothWaiter: CheckedContinuation<Void, Never>?
    func save(_ entity: CustomerOrder, reason: String, context: UserContext) async -> Result<CustomerOrder, any Error> {
        active += 1; maximum = max(maximum, active)
        if active == 2 { bothWaiter?.resume(); bothWaiter = nil }
        defer { active -= 1 }
        // No barrier between this observer and the actual generated public save.
        do { return .success(try await entity.auditAs(reason).save(context)) }
        catch { return .failure(error) }
    }
    func waitForBoth() async {
        if maximum < 2 { await withCheckedContinuation { bothWaiter = $0 } }
    }
    func snapshot() -> (active: Int, maximum: Int) { (active, maximum) }
}

private actor CheckerDiagnostics: DiagnosticSQLLogSink {
    private var values: [SQLExecutionMetadata] = []
    func write(_ metadata: SQLExecutionMetadata) { values.append(metadata) }
    func snapshot() -> [SQLExecutionMetadata] { values }
    func clear() { values.removeAll() }
}

private actor CheckerCommands: GraphTransactionExecutor {
    let service: SQLiteDataService
    private var requests: [MutationRequest] = [], physical: [SQLExecutionMetadata] = []
    private var starts = 0, commits = 0, rollbacks = 0, active = 0, maximum = 0
    private var pause: CheckerBeginPause?
    private var transactionStart = 0, committedKeys: Set<String> = []
    init(_ service: SQLiteDataService) { self.service = service }
    func pauseNextBegin(_ value: CheckerBeginPause) { pause = value }
    func beginGraphTransaction() async throws {
        try require(active == 0, "Context must serialize real graph transactions")
        try await service.beginGraphTransaction()
        transactionStart = requests.count
        starts += 1; active += 1; maximum = max(maximum, active)
        if let waiting = pause { pause = nil; await waiting.hold() }
    }
    func commitGraphTransaction() async throws {
        try await service.commitGraphTransaction(); commits += 1; active -= 1
        for request in requests.dropFirst(transactionStart) {
            if let id = (request.mutation.id ?? request.mutation.values["id"])?.int64Value {
                committedKeys.insert(key(request.mutation.entity.name, id))
            }
        }
    }
    func rollbackGraphTransaction() async throws {
        try await service.rollbackGraphTransaction(); rollbacks += 1; active -= 1
    }
    func execute(_ request: MutationRequest) async throws -> MutationResult {
        requests.append(request) // Count provider entry, not only successful completion.
        let result = try await service.execute(request)
        guard let metadata = result.metadata else { throw TeaQLError.execution("physical mutation metadata missing") }
        physical.append(contentsOf: metadata.statements.isEmpty ? [metadata] : metadata.statements)
        return result
    }
    func clear() {
        requests.removeAll(); physical.removeAll(); starts = 0; commits = 0; rollbacks = 0; maximum = active
        committedKeys.removeAll()
    }
    func hasCommitted(entity: String, id: Int64) -> Bool { committedKeys.contains(key(entity, id)) }
    func snapshot() -> (requests: [MutationRequest], physical: [SQLExecutionMetadata], starts: Int,
                        commits: Int, rollbacks: Int, active: Int, maximum: Int) {
        (requests, physical, starts, commits, rollbacks, active, maximum)
    }
}

private actor CheckerAudit: AuditSink {
    let commands: CheckerCommands
    private var values: [AuditEvent] = []
    init(_ commands: CheckerCommands) { self.commands = commands }
    func record(_ event: AuditEvent) async throws {
        guard let id = event.entityID?.int64Value,
              await commands.hasCommitted(entity: event.entity, id: id)
        else { throw TeaQLError.execution("application audit escaped before its actual graph commit") }
        values.append(event)
    }
    func snapshot() -> [AuditEvent] { values }
    func clear() { values.removeAll() }
}

private struct CheckerSQL: Encodable {
    let operation: String, sql: String, debugSQL: String
    let parameters: [TeaQLValue], lineage: [TraceNode], path: [TraceNode]
    let reason: String?
    init(_ value: SQLExecutionMetadata) {
        operation = value.operation.rawValue; sql = value.parameterizedSQL; debugSQL = value.debugSQL
        parameters = value.parameters; lineage = value.mutationLineage; path = value.tracePath; reason = value.auditReason
    }
}

private struct CheckerCommand: Encodable {
    let entity: String, comment: String
    let id: TeaQLValue?, version: Int64?, lineage: [TraceNode]
    init(_ request: MutationRequest) {
        entity = request.mutation.entity.name; comment = request.intent.comment
        id = request.mutation.id ?? request.mutation.values["id"]; version = request.mutation.expectedVersion
        lineage = request.mutation.mutationLineage ?? []
    }
}

private struct CheckerObservation: Encodable {
    let logging: Bool, rejectedFirst: Bool
    let publicOverlap: Int, serializedTransactions: Int, begins: Int, commits: Int, rollbacks: Int
    let violations: [[String: String]], commands: [CheckerCommand], rawSQL: [CheckerSQL], safeSQL: [CheckerSQL]
    let audit: [AuditEvent]
}

private func loadCheckerGraphs(_ context: UserContext, ids: [Int64]) async throws -> [CustomerOrder] {
    let rows = try await Q.customerOrders().withIdIn(ids).orderByIdAscending().limit(2)
        .selectPlatformWith(Q.platforms().limit(1))
        .selectOrderItemListWith(Q.orderItems().orderByIdAscending().limit(10))
        .comment("load complete graphs for generated Checker overlap")
        .purpose("preserve original versions and shared readonly snapshots").executeForList(context)
    try require(rows.count == ids.count, "Checker graph missing")
    return Array(rows)
}

func generatedCheckerOverlap(runtime: TeaQLRuntime, service: SQLiteDataService, base: Int64) async throws {
    try require(runtime.checker(named: "CustomerOrder") != nil && runtime.checker(named: "OrderItem") != nil,
        "real generated checkers must be installed")
    let commands = CheckerCommands(service), sql = SQLExecutionEvidenceStore()
    let audit = CheckerAudit(commands)
    let diagnostics = CheckerDiagnostics(), policy = OwnershipPolicyCapture()
    var context = UserContext(runtime: runtime, actor: "checker-overlap", queryExecutor: service,
        mutationExecutor: commands, requestPolicy: RequestPolicy { $0 }, auditSink: audit,
        telemetrySink: sql, diagnosticSQLLogSink: diagnostics,
        mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy })
    var scenario: Int64 = 0
    for logging in [false, true] { for rejectedFirst in [false, true] {
        context.querySQLLogEnabled = logging; context.mutationSQLLogEnabled = logging
        let firstID = base + 12_000 + scenario * 100, secondID = firstID + 1
        scenario += 1
        let nonce = UUID().uuidString, privateName = "private-checked-item-\(nonce)"
        for id in [firstID, secondID] {
            var seed = try order(context, id: id, label: "checker-\(nonce)-\(id)")
            var child = try Q.orderItems().comment("initialize complete Checker child")
                .purpose("seed accepted and rejected graph fixtures").newEntity(context)
            child.updateId(id + 10); child.updateName("original-child-\(id)")
            seed.orderItemList.append(child)
            _ = try await seed.auditAs("seed generated Checker fixture").save(context)
        }
        let loaded = try await loadCheckerGraphs(context, ids: [firstID, secondID])
        var good = loaded[0], bad = loaded[1]
        guard let goodReference = try E.customerOrder(good).platform().eval(),
              let badReference = try E.customerOrder(bad).platform().eval(),
              let shared = goodReference.teaqlLoadedSnapshot, let other = badReference.teaqlLoadedSnapshot
        else { throw TeaQLError.execution("shared provider-loaded Platform snapshot missing") }
        let sharedBefore = shared.record, badVersion = bad.version
        let badOriginal = try E.customerOrder(bad).description().eval()
        try require(shared === other && good.teaqlEntityRoot !== bad.teaqlEntityRoot
            && goodReference.teaqlEntityRoot !== badReference.teaqlEntityRoot, "shared snapshots must not share graph ownership")
        good.updateDescription("accepted-root-\(nonce)")
        good.orderItemList[0].updateName(privateName)
        _ = good.orderItemList[0].auditAs("accepted child responsibility")
        bad.updateDescription("rejected-pending-\(nonce)")
        var missing = try Q.orderItems().comment("initialize incomplete Checker child")
            .purpose("verify a real missing-required-field rejection").newEntity(context)
        missing.updateId(secondID + 20) // Deliberately omit updateName; no fake Checker failure.
        _ = missing.auditAs("rejected child responsibility")
        bad.orderItemList.append(missing)
        await commands.clear(); await audit.clear(); await sql.enableAll(); await diagnostics.clear(); policy.clear()
        let pause = CheckerBeginPause(), invocations = CheckerInvocations()
        await commands.pauseNextBegin(pause)
        let validGraph = good, invalidGraph = bad, sharedContext = context
        let first = Task { await invocations.save(rejectedFirst ? invalidGraph : validGraph,
            reason: rejectedFirst ? "reject incomplete graph" : "accept checked graph", context: sharedContext) }
        await pause.waitUntilEntered()
        let second = Task { await invocations.save(rejectedFirst ? validGraph : invalidGraph,
            reason: rejectedFirst ? "accept checked graph" : "reject incomplete graph", context: sharedContext) }
        await invocations.waitForBoth()
        let overlap = await invocations.snapshot(), paused = await commands.snapshot()
        // Release before any throwing assertion so a failed test cannot strand the real transaction.
        await pause.release()
        let outcomes = await [first.value, second.value]
        try require(overlap.active == 2 && overlap.maximum == 2 && paused.starts == 1 && paused.active == 1,
            "two public saves must overlap while the actual Context gate serializes transactions")
        _ = try outcomes[rejectedFirst ? 1 : 0].get()
        let rejected: CheckException
        switch outcomes[rejectedFirst ? 0 : 1] {
        case .success: throw TeaQLError.execution("generated Checker accepted missing required child name")
        case .failure(let error):
            guard let check = error as? CheckException else { throw error }; rejected = check
        }
        try require(rejected.violations.contains { $0.ruleID.lowercased() == "required"
            && $0.location.nativePath == "orderItemList[1].name" }, "wrong generated Checker violation: \(rejected.violations)")
        let captured = await commands.snapshot(), safe = await sql.snapshot(), events = await audit.snapshot()
        let logged = await diagnostics.snapshot()
        let expected = [key("CustomerOrder", firstID): [NodeExpectation(type: "CustomerOrder", id: firstID, reason: "accept checked graph")],
            key("OrderItem", firstID + 10): [NodeExpectation(type: "CustomerOrder", id: firstID, reason: "accept checked graph"),
                NodeExpectation(type: "OrderItem", id: firstID + 10, reason: "accepted child responsibility")]]
        try checkObservedGraph(expected, commands: captured.requests, sql: captured.physical, audit: events, rootReason: "accept checked graph")
        try checkObservedGraph(expected, commands: captured.requests, sql: safe, audit: events, rootReason: "accept checked graph")
        try require(captured.starts == 2 && captured.commits == 1 && captured.rollbacks == 1
            && captured.active == 0 && captured.maximum == 1, "Checker transaction outcomes differ")
        try require(logged.count == (logging ? 4 : 0), "diagnostics switch changed execution or emitted rejected SQL")
        try require(captured.physical.contains { $0.parameters.contains(.string(privateName)) }, "real raw binding lost accepted private value")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let safeText = String(decoding: try encoder.encode(safe.map(CheckerSQL.init)), as: UTF8.self)
            + String(decoding: try encoder.encode(logged.map(CheckerSQL.init)), as: UTF8.self)
            + String(decoding: try encoder.encode(events), as: UTF8.self)
        try require(!safeText.contains(privateName), "private child value leaked through a safe observer")
        try require(policy.snapshot().count == 1 && policy.snapshot().flatMap(\.operations).count == 2,
            "rejected or readonly graph reached mutation-policy review")
        try require(Set(policy.snapshot().flatMap(\.operations).map { "\($0.entity)#\($0.entityID?.int64Value ?? 0)" })
            == Set(expected.keys), "policy reviewed a rejected or readonly identity")
        try require(shared.record == sharedBefore && goodReference.teaqlEntityRoot.snapshot().isEmpty
            && badReference.teaqlEntityRoot.snapshot().isEmpty, "readonly shared reference was mutated")
        try require(bad.teaqlEntityRoot.change(bad.teaqlEntityKey)["description"] == .string("rejected-pending-\(nonce)"),
            "rejection lost caller-owned pending changes")
        try require(context.lastFixEvidence.isEmpty, "fixture with no Fix rules retained unrelated evidence")
        let observation = CheckerObservation(logging: logging, rejectedFirst: rejectedFirst, publicOverlap: overlap.maximum,
            serializedTransactions: captured.maximum, begins: captured.starts, commits: captured.commits, rollbacks: captured.rollbacks,
            violations: rejected.violations.map { ["rule": $0.ruleID, "path": $0.location.nativePath] },
            commands: captured.requests.map(CheckerCommand.init), rawSQL: captured.physical.map(CheckerSQL.init),
            safeSQL: safe.map(CheckerSQL.init), audit: events)
        print("CHECKER_OVERLAP_OBSERVED " + String(decoding: try encoder.encode(observation), as: UTF8.self))
        let persisted = try await loadCheckerGraphs(context, ids: [firstID, secondID])
        try require(E.customerOrder(persisted[0]).description().eval() == "accepted-root-\(nonce)"
            && E.orderItem(persisted[0].orderItemList[0]).name().eval() == privateName, "accepted graph did not persist")
        try require(persisted[1].version == badVersion && persisted[1].orderItemList.count == 1
            && E.customerOrder(persisted[1]).description().eval() == badOriginal, "rejected graph changed the database")
        try require(E.platform(E.customerOrder(persisted[1]).platform().eval()!).version().eval() == goodReference.version,
            "shared readonly Platform version changed")
        var next = persisted[1]
        let nextReason = "independent after Checker rejection \(privateName)"
        next.updateDescription("next-independent-\(nonce)")
        await commands.clear(); await audit.clear(); await sql.enableAll(); await diagnostics.clear(); policy.clear()
        _ = try await next.auditAs(nextReason).save(context)
        let nextCaptured = await commands.snapshot()
        let nextExpected = [key("CustomerOrder", secondID): [NodeExpectation(type: "CustomerOrder", id: secondID, reason: nextReason)]]
        try checkObservedGraph(nextExpected, commands: nextCaptured.requests, sql: nextCaptured.physical,
            audit: await audit.snapshot(), rootReason: nextReason)
        try checkObservedGraph(nextExpected, commands: nextCaptured.requests, sql: await sql.snapshot(),
            audit: await audit.snapshot(), rootReason: nextReason)
        let nextDiagnostics = await diagnostics.snapshot()
        try require(nextDiagnostics.count == (logging ? 2 : 0), "following save lost the diagnostic switch")
        try require(nextCaptured.commits == 1 && nextCaptured.rollbacks == 0 && context.lastFixEvidence.isEmpty,
            "following independent save inherited rejected Checker state")
        let nextReloaded = try await loadCheckerGraphs(context, ids: [secondID])
        try require(E.customerOrder(nextReloaded[0]).description().eval() == "next-independent-\(nonce)", "following save not persisted")
        print("PASS generated Checker overlap logging=\(logging) rejectedFirst=\(rejectedFirst): accepted-only SQL/audit and independent next save")
    } }
    print("PASS: Swift generated Checker accepted/rejected overlap 4 cases; callbacks serialized")
}
