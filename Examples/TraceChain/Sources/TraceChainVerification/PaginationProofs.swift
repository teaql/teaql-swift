import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct PageCommand: Encodable {
    let entity: String
    let id: TeaQLValue?
    let kind: String
    let originalVersion: Int64?
    let values: TeaQLRecord
    let comment: String
    let lineage: [TraceNode]
    init(_ request: MutationRequest) {
        entity = request.mutation.entity.name
        id = request.mutation.id ?? request.mutation.values["id"]
        kind = request.mutation.kind.rawValue
        originalVersion = request.mutation.expectedVersion
        values = request.mutation.values
        comment = request.intent.comment
        lineage = request.mutation.mutationLineage ?? []
    }
}

private struct PageSQL: Encodable {
    let sql: String
    let parameters: [TeaQLValue]
    let path: [TraceNode]
    let comment: String?
    let purpose: String?
    let auditReason: String?
    let outcome: String?
    let resultCount: Int?
    let lineage: [TraceNode]
    init(_ value: SQLExecutionMetadata) {
        sql = value.debugSQL; parameters = value.parameters; path = value.tracePath
        comment = value.comment; purpose = value.purpose; auditReason = value.auditReason
        outcome = value.executionOutcome; resultCount = value.resultCount; lineage = value.mutationLineage
    }
}

private struct PageObservation: Encodable {
    let phase: String
    let checks: [String: Bool]
    let rootIDs: [Int64]
    let rootVersions: [Int64]
    let total: Int
    let offset: Int
    let limit: Int
    let commands: [PageCommand]
    let sql: [PageSQL]
    let audit: [AuditEvent]
    let plans: [MutationPlan]
}

private func observePage(_ phase: String, checks: [String: Bool], page: TeaQLPage<CustomerOrder>,
    commands: CommandCapture, sql: SQLExecutionEvidenceStore, audit: AuditCapture,
    policy: OwnershipPolicyCapture) async throws {
    let observation = PageObservation(phase: phase, checks: checks, rootIDs: page.items.map(\.id),
        rootVersions: page.items.map(\.version), total: page.total, offset: page.offset, limit: page.limit,
        commands: await commands.snapshot().map(PageCommand.init), sql: await sql.snapshot().map(PageSQL.init),
        audit: await audit.snapshot(), plans: policy.snapshot())
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    print("PAGE_OBSERVED " + String(decoding: try encoder.encode(observation), as: UTF8.self))
    try require(checks.values.allSatisfy { $0 }, "page \(phase) checks failed: \(checks)")
    print("PASS Swift generated page: \(phase)")
}

private func loadPage(_ context: UserContext, ids: [Int64], comment: String) async throws -> TeaQLPage<CustomerOrder> {
    try await Q.customerOrders().withIdIn(ids).orderByIdAscending()
        .selectPlatformWith(Q.platforms().limit(1))
        .selectOrderItemListWith(Q.orderItems().orderByIdAscending().limit(10))
        .comment(comment).purpose("verify independently saveable paginated graphs")
        .executeForPage(context, offset: 1, limit: 2)
}

func generatedPaginationProofs(runtime: TeaQLRuntime, service: SQLiteDataService, base: Int64) async throws {
    let audit = AuditCapture(), sql = SQLExecutionEvidenceStore(), policy = OwnershipPolicyCapture()
    let commands = CommandCapture(service: service, audit: audit)
    let context = UserContext(runtime: runtime, actor: "page-conformance", queryExecutor: service,
        mutationExecutor: commands, requestPolicy: RequestPolicy { $0 }, auditSink: audit,
        telemetrySink: sql, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }),
        mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy })
    let ids = [base + 8_000, base + 8_001, base + 8_002]
    for id in ids {
        var root = try order(context, id: id, label: "page-\(id)")
        var child = try Q.orderItems().comment("initialize pagination child")
            .purpose("prepare independent page graphs").newEntity(context)
        child.updateId(id + 100); child.updateCustomerOrder(id); child.updateName("page child \(id)")
        root.orderItemList.append(child)
        _ = try await root.auditAs("seed pagination graph").save(context)
    }
    var advanced = try await loadOrder(context, id: ids[1])
    advanced.updateDescription("page first root version two")
    _ = try await advanced.auditAs("advance first page root").save(context)
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    let comment = "load one bounded page with shared Platform"
    let page = try await loadPage(context, ids: ids, comment: comment)
    try require(page.items.count == 2, "page must return two roots")
    var first = page.items[0], second = page.items[1]
    guard let firstReference = try E.customerOrder(first).platform().eval(),
          let secondReference = try E.customerOrder(second).platform().eval(),
          let snapshot = firstReference.teaqlLoadedSnapshot,
          let other = secondReference.teaqlLoadedSnapshot
    else { throw TeaQLError.execution("page reference snapshot missing") }
    let pageSQL = await sql.snapshot()
    let countSQL = pageSQL.filter { $0.parameterizedSQL.contains("COUNT(*)") }
    let rowSQL = pageSQL.filter { !$0.parameterizedSQL.contains("COUNT(*)") }
    let allIntent = pageSQL.allSatisfy { $0.comment == comment
        && $0.purpose == "verify independently saveable paginated graphs"
        && $0.tracePath.first?.name == "CustomerOrder" && $0.executionOutcome == "success" }
    let allCanonical = pageSQL.allSatisfy { entry in
        entry.tracePath.first?.kind == "operation" && entry.tracePath.last?.kind == "sql"
            && entry.tracePath.last?.name == "select"
            && !entry.tracePath.contains { ["comment", "purpose", "auditReason"].contains($0.kind) }
    }
    let pendingBefore = first.teaqlEntityRoot.snapshot()
    try await observePage("page-rows", checks: [
        "bounded_page_and_exact_total": page.total == 3 && page.offset == 1 && page.limit == 2,
        "stable_ids_and_versions": page.items.map(\.id) == Array(ids.suffix(2)) && page.items.map(\.version) == [2, 1],
        "independent_root_ledgers": first.teaqlEntityRoot !== second.teaqlEntityRoot,
        "independent_reference_ledgers": firstReference.teaqlEntityRoot !== secondReference.teaqlEntityRoot,
        "actual_shared_readonly_snapshot": snapshot === other,
        "no_hydration_mutations": pendingBefore.isEmpty && second.teaqlEntityRoot.snapshot().isEmpty,
        "one_count_with_full_filter": countSQL.count == 1 && countSQL[0].resultCount == 1
            && !countSQL[0].parameterizedSQL.contains("LIMIT") && !countSQL[0].parameterizedSQL.contains("OFFSET"),
        // SQLite's AlwaysProbe policy applies the bounded forward query once
        // per parent too. Snapshot sharing does not promise SQL deduplication.
        "rows_and_forward_reverse_loads": rowSQL.count == 5 && rowSQL.filter { $0.tracePath.contains { $0.name == "platform" } }.count == 2
            && rowSQL.filter { $0.tracePath.contains { $0.name == "orderItemList" } }.count == 2,
        "origin_intent_on_all_statements": allIntent, "canonical_paths": allCanonical,
        "generated_e_loaded_child": try E.customerOrder(first).orderItemList().size().eval() == 1
            && E.customerOrder(second).orderItemList().size().eval() == 1,
    ], page: page, commands: commands, sql: sql, audit: audit, policy: policy)

    first.updateDescription("saved first paginated root")
    second.updateDescription("pending second paginated root")
    let secondPending = second.teaqlEntityRoot.snapshot(), originalSnapshot = snapshot.record
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    _ = try await first.auditAs("save first page root only").save(context)
    try checkObservedGraph([key("CustomerOrder", ids[1]): [NodeExpectation(type: "CustomerOrder", id: ids[1], reason: "save first page root only")]],
        commands: await commands.snapshot(), sql: await sql.snapshot(), audit: await audit.snapshot(), rootReason: "save first page root only")
    let rootCommands = await commands.snapshot()
    let persistedSecond = try await loadOrder(context, id: ids[2])
    try await observePage("save-first-root", checks: [
        "only_first_root_reviewed": policy.snapshot().flatMap(\.operations).count == 1,
        "original_version_two": rootCommands.first?.mutation.expectedVersion == 2,
        "other_root_still_pending": second.teaqlEntityRoot.snapshot() == secondPending,
        "other_root_not_persisted": try E.customerOrder(persistedSecond).description().eval() == "Draft order" && persistedSecond.version == 1,
        "readonly_snapshot_unchanged": snapshot.record == originalSnapshot,
    ], page: page, commands: commands, sql: sql, audit: audit, policy: policy)

    var cleanPage = try await loadPage(context, ids: ids, comment: "reload independently persisted page")
    var clean = cleanPage.items[0]
    clean.orderItemList[0].updateName("saved paginated descendant")
    _ = clean.orderItemList[0].auditAs("edit page descendant")
    let childID = clean.orderItemList[0].id
    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    _ = try await clean.auditAs("save clean page ancestor").save(context)
    try checkObservedGraph([key("OrderItem", childID): [NodeExpectation(type: "CustomerOrder", id: ids[1], reason: "save clean page ancestor"),
        NodeExpectation(type: "OrderItem", id: childID, reason: "edit page descendant")]], commands: await commands.snapshot(),
        sql: await sql.snapshot(), audit: await audit.snapshot(), rootReason: "save clean page ancestor")
    let childCommands = await commands.snapshot()
    try await observePage("save-clean-descendant", checks: [
        "one_child_reviewed": policy.snapshot().flatMap(\.operations).count == 1,
        "original_child_version_one": childCommands.first?.mutation.expectedVersion == 1,
        "other_root_pending_untouched": second.teaqlEntityRoot.snapshot() == secondPending,
        "readonly_snapshot_unchanged": snapshot.record == originalSnapshot,
    ], page: cleanPage, commands: commands, sql: sql, audit: audit, policy: policy)

    await commands.clear(); await sql.enableAll(); await audit.clear(); policy.clear()
    _ = try await second.auditAs("save second page root only").save(context)
    try checkObservedGraph([key("CustomerOrder", ids[2]): [NodeExpectation(type: "CustomerOrder", id: ids[2], reason: "save second page root only")]],
        commands: await commands.snapshot(), sql: await sql.snapshot(), audit: await audit.snapshot(), rootReason: "save second page root only")
    let secondCommands = await commands.snapshot()
    cleanPage = try await loadPage(context, ids: ids, comment: "verify committed page independently")
    try await observePage("save-second-root", checks: [
        "only_second_root_reviewed": policy.snapshot().flatMap(\.operations).count == 1,
        "original_second_version_one": secondCommands.first?.mutation.expectedVersion == 1,
        "persisted_root_versions_three_two": cleanPage.items.map(\.version) == [3, 2],
        "first_root_value": try E.customerOrder(cleanPage.items[0]).description().eval() == "saved first paginated root",
        "second_root_value": try E.customerOrder(cleanPage.items[1]).description().eval() == "pending second paginated root",
        "descendant_value": try E.orderItem(cleanPage.items[0].orderItemList[0]).name().eval() == "saved paginated descendant",
        "descendant_version_two": cleanPage.items[0].orderItemList[0].version == 2,
        "other_child_version_one": cleanPage.items[1].orderItemList[0].version == 1,
        "readonly_snapshot_unchanged": snapshot.record == originalSnapshot,
    ], page: cleanPage, commands: commands, sql: sql, audit: audit, policy: policy)
}
