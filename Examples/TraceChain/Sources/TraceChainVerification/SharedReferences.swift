import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

/// Observe the actual reviewed plans, including phantom creates that emit no SQL.
final class OwnershipPolicyCapture: MutationPolicy, @unchecked Sendable {
    let identity = MutationPolicyIdentity(policyID: "trace-ownership", version: "1", fingerprint: "local-fixture")
    private let lock = NSLock()
    private var plans: [MutationPlan] = []
    func review(context: UserContext, plan: MutationPlan) -> MutationPolicyDecision {
        lock.withLock { plans.append(plan) }
        return MutationPolicyDecision(verdict: .allow)
    }
    func snapshot() -> [MutationPlan] { lock.withLock { plans } }
    func clear() { lock.withLock { plans.removeAll() } }
}

private struct OwnershipCommand: Encodable {
    let entity: String
    let id: TeaQLValue?
    let kind: String
    let originalVersion: Int64?
    let values: TeaQLRecord
    let comment: String
    let lineage: [TraceNode]
    init(_ request: MutationRequest) {
        let mutation = request.mutation
        entity = mutation.entity.name; id = mutation.id ?? mutation.values["id"]
        kind = mutation.kind.rawValue; originalVersion = mutation.expectedVersion
        values = mutation.values; comment = request.intent.comment
        lineage = mutation.mutationLineage ?? []
    }
}

private struct OwnershipSQL: Encodable {
    let operation: String
    let sql: String
    let originalSQL: String
    let path: [TraceNode]
    let lineage: [TraceNode]
    let comment: String?
    let outcome: String?
    init(_ metadata: SQLExecutionMetadata) {
        operation = metadata.operation.rawValue; sql = metadata.debugSQL
        originalSQL = metadata.parameterizedSQL; path = metadata.tracePath
        lineage = metadata.mutationLineage; comment = metadata.auditReason
        outcome = metadata.executionOutcome
    }
}

private struct OwnershipObservation: Encodable {
    let scenario: String
    let checks: [String: Bool]
    let commands: [OwnershipCommand]
    let sql: [OwnershipSQL]
    let audit: [AuditEvent]
    let plans: [MutationPlan]
}

private func observeOwnership(_ scenario: String, checks: [String: Bool],
    commands: CommandCapture, sql: SQLExecutionEvidenceStore, audit: AuditCapture,
    policy: OwnershipPolicyCapture) async throws {
    try require(checks.values.allSatisfy { $0 }, "\(scenario): ownership checks failed: \(checks)")
    let observation = OwnershipObservation(scenario: scenario, checks: checks,
        commands: await commands.snapshot().map(OwnershipCommand.init),
        sql: await sql.snapshot().filter { $0.operation != .select }.map(OwnershipSQL.init),
        audit: await audit.snapshot(), plans: policy.snapshot())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print("OWNERSHIP_OBSERVED " + String(decoding: try encoder.encode(observation), as: UTF8.self))
    print("PASS Swift generated ownership: \(scenario)")
}

private func loadOwnershipGraph(_ context: UserContext, ids: [Int64]) async throws -> [CustomerOrder] {
    let rows = try await Q.customerOrders().withIdIn(ids).orderByIdAscending().limit(2)
        .selectPlatformWith(Q.platforms().limit(1))
        .selectOrderItemListWith(Q.orderItems().orderByIdAscending().limit(10))
        .comment("load independent roots and shared read-only Platform")
        .purpose("verify immutable snapshots do not share mutation ownership").executeForList(context)
    try require(rows.count == ids.count, "ownership graph roots missing")
    return Array(rows)
}

func sharedOwnershipProofs(runtime: TeaQLRuntime, service: SQLiteDataService, base: Int64) async throws {
    let audit = AuditCapture(), sql = SQLExecutionEvidenceStore(), policy = OwnershipPolicyCapture()
    let commands = CommandCapture(service: service, audit: audit)
    let context = UserContext(runtime: runtime, actor: "trace-ownership", queryExecutor: service,
        mutationExecutor: commands, requestPolicy: RequestPolicy { $0 }, auditSink: audit,
        telemetrySink: sql, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }),
        mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy })
    // Existing rollback/readback fixtures reserve the +5000 and +6000 bands.
    let firstID = base + 7_000, secondID = firstID + 1
    for (id, label) in [(firstID, "ownership-A"), (secondID, "ownership-B")] {
        var root = try order(context, id: id, label: label)
        for offset in [Int64(10), 20] {
            var child = try Q.orderItems().comment("initialize ownership child")
                .purpose("prepare isolated graphs").newEntity(context)
            child.updateId(id + offset); child.updateCustomerOrder(id); child.updateName("child \(id + offset)")
            root.orderItemList.append(child)
        }
        _ = try await root.auditAs("seed ownership graph").save(context)
    }
    var advanced = try await loadOrder(context, id: firstID)
    advanced.updateDescription("version-two first root")
    _ = try await advanced.auditAs("advance first root only").save(context)

    var roots = try await loadOwnershipGraph(context, ids: [firstID, secondID])
    guard let firstReference = try E.customerOrder(roots[0]).platform().eval(),
          let secondReference = try E.customerOrder(roots[1]).platform().eval(),
          let shared = firstReference.teaqlLoadedSnapshot,
          let otherShared = secondReference.teaqlLoadedSnapshot
    else { throw TeaQLError.execution("actual loaded immutable reference snapshot missing") }
    let originalSnapshot = shared.record
    let sharedReference = shared === otherShared
    let independentRoots = roots[0].teaqlEntityRoot !== roots[1].teaqlEntityRoot
    let independentReferences = firstReference.teaqlEntityRoot !== secondReference.teaqlEntityRoot
    try require(sharedReference && independentRoots && independentReferences, "query sharing/ledger precondition failed")
    try require(roots[0].version == 2 && roots[1].version == 1,
        "ownership root versions must be 2/1; actual \(roots.map { "\($0.id):\($0.version)" })")
    try require(roots.allSatisfy { $0.teaqlEntityRoot.snapshot().isEmpty }, "hydration invented pending field changes")
    roots[0].updateDescription("independent first mutation")
    roots[1].updateDescription("independent second mutation")
    let first = roots[0], second = roots[1]
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    async let savedFirst = first.auditAs("save ownership A").save(context)
    async let savedSecond = second.auditAs("save ownership B").save(context)
    _ = try await (savedFirst, savedSecond)
    let requests = await commands.snapshot(), entries = await sql.snapshot(), events = await audit.snapshot()
    for (id, reason) in [(firstID, "save ownership A"), (secondID, "save ownership B")] {
        try checkObservedGraph([key("CustomerOrder", id): [NodeExpectation(type: "CustomerOrder", id: id, reason: reason)]],
            commands: requests.filter { $0.intent.comment == reason },
            sql: entries.filter { $0.auditReason == reason }, audit: events.filter { $0.reason == reason }, rootReason: reason)
    }
    let persisted = try await loadOwnershipGraph(context, ids: [firstID, secondID])
    let expectedVersions = requests.map { $0.mutation.expectedVersion }.compactMap { $0 }.sorted()
    try await observeOwnership("shared-readonly", checks: [
        "actual_shared_snapshot": sharedReference, "independent_root_ledgers": independentRoots,
        "independent_reference_ledgers": independentReferences, "snapshot_unchanged": shared.record == originalSnapshot,
        "only_two_root_commands": requests.count == 2 && requests.allSatisfy { $0.mutation.entity.name == "CustomerOrder" },
        "original_versions_1_2": expectedVersions == [1, 2],
        "reviewed_only_two_updates": policy.snapshot().count == 2 && policy.snapshot().flatMap(\.operations).count == 2
            && policy.snapshot().flatMap(\.operations).allSatisfy { $0.kind == .update && $0.entity == "CustomerOrder" },
        "persisted_versions_3_2": persisted.map(\.version) == [3, 2],
        "persisted_values": try E.customerOrder(persisted[0]).description().eval() == "independent first mutation"
            && E.customerOrder(persisted[1]).description().eval() == "independent second mutation",
        "children_unchanged": persisted.flatMap(\.orderItemList).allSatisfy { $0.version == 1 },
        "reference_version_unchanged": try E.platform(firstReference).version().eval() == 1
            && E.platform(try E.customerOrder(persisted[0]).platform().eval()!).version().eval() == 1,
    ], commands: commands, sql: sql, audit: audit, policy: policy)

    var target = persisted[0], foreign = persisted[1]
    foreign.updateDescription("unsaved foreign root")
    foreign.orderItemList[1].updateName("unsaved unrelated sibling")
    foreign.orderItemList[0].updateName("moved reached child")
    _ = foreign.orderItemList[0].auditAs("move reached child")
    let sourceLedger = foreign.teaqlEntityRoot, sourceBefore = sourceLedger.snapshot()
    let movedID = foreign.orderItemList[0].id
    target.orderItemList.append(foreign.orderItemList[0])
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    _ = try await target.auditAs("save reached child only").save(context)
    try checkObservedGraph([key("OrderItem", movedID): [NodeExpectation(type: "CustomerOrder", id: firstID, reason: "save reached child only"),
        NodeExpectation(type: "OrderItem", id: movedID, reason: "move reached child")]],
        commands: await commands.snapshot(), sql: await sql.snapshot(), audit: await audit.snapshot(), rootReason: "save reached child only")
    let reachedReload = try await loadOwnershipGraph(context, ids: [firstID, secondID])
    let moved = try requireItem(reachedReload[0], id: movedID)
    try await observeOwnership("scoped-import", checks: [
        "source_pending_preserved": sourceLedger.snapshot() == sourceBefore,
        "unrelated_root_not_imported": target.teaqlEntityRoot.change(foreign.teaqlEntityKey).isEmpty,
        "unrelated_sibling_not_imported": target.teaqlEntityRoot.change(foreign.orderItemList[1].teaqlEntityKey).isEmpty,
        "reached_fk_persisted": try E.orderItem(moved).customerOrderId().eval() == firstID,
        "reached_value_persisted": try E.orderItem(moved).name().eval() == "moved reached child",
        "foreign_root_unchanged": try E.customerOrder(reachedReload[1]).description().eval() == "independent second mutation",
        "unrelated_sibling_unchanged": reachedReload[1].orderItemList.count == 1 && reachedReload[1].orderItemList[0].version == 1,
        "one_reviewed_operation": policy.snapshot().flatMap(\.operations).count == 1,
    ], commands: commands, sql: sql, audit: audit, policy: policy)

    var clean = reachedReload[0]
    let parentVersion = clean.version, changedID = clean.orderItemList[0].id
    clean.orderItemList[0].updateName("clean ancestor child edit")
    _ = clean.orderItemList[0].auditAs("edit one descendant")
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    _ = try await clean.auditAs("save clean ancestor graph").save(context)
    try checkObservedGraph([key("OrderItem", changedID): [NodeExpectation(type: "CustomerOrder", id: firstID, reason: "save clean ancestor graph"),
        NodeExpectation(type: "OrderItem", id: changedID, reason: "edit one descendant")]],
        commands: await commands.snapshot(), sql: await sql.snapshot(), audit: await audit.snapshot(), rootReason: "save clean ancestor graph")
    let cleanReload = try await loadOwnershipGraph(context, ids: [firstID])
    try await observeOwnership("clean-ancestor", checks: [
        "parent_version_unchanged": cleanReload[0].version == parentVersion,
        "child_value_persisted": try E.orderItem(requireItem(cleanReload[0], id: changedID)).name().eval() == "clean ancestor child edit",
        "one_reviewed_operation": policy.snapshot().flatMap(\.operations).count == 1,
        "reference_snapshot_unchanged": shared.record == originalSnapshot,
    ], commands: commands, sql: sql, audit: audit, policy: policy)

    guard var old = try await Q.orderItems().withIdIs(changedID).limit(1)
        .comment("load old child version").purpose("verify mixed loaded versions fail before SQL").executeForList(context).first
    else { throw TeaQLError.execution("conflict child missing") }
    var advancedChild = old
    advancedChild.updateName("advance conflict child")
    _ = try await advancedChild.auditAs("advance conflict child").save(context)
    guard var current = try await Q.orderItems().withIdIs(changedID).limit(1)
        .comment("load current child version").purpose("verify conflicting independent snapshots").executeForList(context).first
    else { throw TeaQLError.execution("new conflict child missing") }
    // Copying a mutable wrapper is not an independent read. Reload the old
    // version via its original immutable snapshot using a fresh ledger.
    guard let oldSnapshot = old.teaqlLoadedSnapshot else { throw TeaQLError.execution("old snapshot missing") }
    old = try OrderItem.from(record: oldSnapshot.record)
    old.updateName("old version pending"); current.updateName("current version pending")
    let oldBefore = old.teaqlEntityRoot.snapshot(), currentBefore = current.teaqlEntityRoot.snapshot()
    var conflictRoot = cleanReload[0]; conflictRoot.orderItemList = [old, current]
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    var rejected = false
    do { _ = try await conflictRoot.auditAs("reject mixed versions").save(context) }
    catch let error as TeaQLError { rejected = String(describing: error).contains("ENTITY_VERSION_CONFLICT") }
    let conflictCommands = await commands.snapshot(), conflictSQL = await sql.snapshot(), conflictAudit = await audit.snapshot()
    try await observeOwnership("version-conflict", checks: [
        "conflicting_loaded_versions": old.version + 1 == current.version,
        "rejected_before_provider": rejected && conflictCommands.isEmpty && conflictSQL.isEmpty && conflictAudit.isEmpty,
        "no_reviewed_business_operation": policy.snapshot().isEmpty,
        "old_pending_preserved": old.teaqlEntityRoot.snapshot() == oldBefore,
        "current_pending_preserved": current.teaqlEntityRoot.snapshot() == currentBefore,
    ], commands: commands, sql: sql, audit: audit, policy: policy)
}

private func requireItem(_ root: CustomerOrder, id: Int64) throws -> OrderItem {
    guard let item = root.orderItemList.first(where: { $0.id == id }) else { throw TeaQLError.execution("expected child missing") }
    return item
}
