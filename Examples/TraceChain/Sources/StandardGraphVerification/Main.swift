import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
import TeaQLStandardTelemetry

private actor GraphAudits: AuditSink {
    private var events: [AuditEvent] = []
    func record(_ event: AuditEvent) { events.append(event) }
    func snapshot() -> [AuditEvent] { events }
    func clear() { events.removeAll() }
}

@main enum StandardGraphVerification {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL Swift standard graph: \(type(of: error))\n".utf8))
            exit(1)
        }
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TeaQLError.execution(message) }
    }
    private static func load(_ context: UserContext, id: Int64) async throws -> CustomerOrder {
        guard let row = try await Q.customerOrders().withIdIs(id).limit(1)
            .selectOrderItemListWith(Q.orderItems().orderByIdAscending().limit(10).comment("load items"))
            .selectPaymentListWith(Q.payments().selectPaymentAttemptListWith(
                Q.paymentAttempts().limit(10).comment("load attempts")).limit(10).comment("load payments"))
            .selectShipmentListWith(Q.shipments().limit(10).comment("load shipments"))
            .comment("load complete payment graph").purpose("verify graph persistence and prepare mutations")
            .executeForList(context).first else { throw TeaQLError.execution("missing graph") }
        return row
    }
    private static func facts(_ phase: String, _ sql: SQLExecutionEvidenceStore, _ audit: GraphAudits) async throws {
        let events = await audit.snapshot(), statements = await sql.snapshot()
        let data: [String: Any] = ["phase": phase, "sql": statements.map { entry in
            ["operation": entry.operation.rawValue, "outcome": entry.executionOutcome ?? "unknown",
             "lineage": entry.mutationLineage.map { ["name": $0.name, "comment": $0.comment] }]
        }, "audits": events.map { event in
            ["entity": event.entity, "operation": event.operation.rawValue, "reason": event.reason,
             "lineage": (event.mutationLineage ?? []).map { ["name": $0.name, "comment": $0.comment] }]
        }]
        let bytes = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        print("SWIFT_STANDARD_GRAPH_FACTS " + String(decoding: bytes, as: UTF8.self))
    }
    private static func health(_ context: UserContext, label: String) throws {
        guard let telemetry = context.runtimeTelemetry as? StandardTelemetry else {
            throw TeaQLError.execution("standard telemetry missing")
        }
        let data = try JSONSerialization.data(withJSONObject: ["losses": telemetry.exportLossReasons,
            "queues": telemetry.exportQueues, "resources": telemetry.exportResources], options: [.sortedKeys])
        print(label + " " + String(decoding: data, as: UTF8.self))
        fflush(nil)
    }
    private static func pressure(_ context: UserContext, id: Int64, sql: SQLExecutionEvidenceStore,
        audit: GraphAudits) async throws {
        // Only generated Q/E is used. Neither business code nor this fixture
        // creates spans, logs, exporters or individual SDK callbacks.
        await context.runtimeTelemetry.flush()
        let beforeAudit = await audit.snapshot().count
        await sql.enableAll()
        try health(context, label: "SWIFT_QUEUE_BASELINE")
        for _ in 0..<1500 {
            let rows = try await Q.customerOrders().withIdIs(id).limit(1)
                .comment("inspect the saved payment graph root")
                .purpose("verify bounded generated Q/E under export pressure").executeForList(context)
            try require(rows.count == 1 && E.customerOrder(rows[0]).description().eval() == "Submitted graph",
                "pressure read changed business data")
        }
        try health(context, label: "SWIFT_QUEUE_READY")
        if ProcessInfo.processInfo.environment["TEAQL_STANDARD_QUEUE_BACKLOG"] == "true" {
            let started = ContinuousClock.now
            await context.runtimeTelemetry.shutdown()
            let elapsed = started.duration(to: .now)
            try require(elapsed < .seconds(6), "backlogged shutdown exceeded caller budget")
            try health(context, label: "SWIFT_QUEUE_CLOSED")
            let rows = try await Q.customerOrders().withIdIs(id).limit(1)
                .comment("inspect data after telemetry shutdown")
                .purpose("verify telemetry failure does not govern business queries").executeForList(context)
            try require(rows.count == 1 && E.customerOrder(rows[0]).description().eval() == "Submitted graph", "post-shutdown read")
            try health(context, label: "SWIFT_QUEUE_LATE")
            let afterAudit = await audit.snapshot().count, statements = await sql.snapshot()
            try require(afterAudit == beforeAudit && statements.count == 1501, "shutdown changed business or audits")
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            print("SWIFT_QUEUE_BACKLOG PASSED queries=1500 late=1 sql=1501 audits=\(afterAudit) elapsed_ms=\(milliseconds)")
            fflush(nil)
            return
        }
        await context.runtimeTelemetry.flush()
        try health(context, label: "SWIFT_QUEUE_DRAINED")
        let rows = try await Q.customerOrders().withIdIs(id).limit(1)
            .comment("inspect recovered queue capacity").purpose("verify generated query recovery").executeForList(context)
        try require(rows.count == 1 && E.customerOrder(rows[0]).description().eval() == "Submitted graph", "recovery read")
        await context.runtimeTelemetry.flush()
        try health(context, label: "SWIFT_QUEUE_RECOVERED")
        let afterAudit = await audit.snapshot().count, statements = await sql.snapshot()
        try require(afterAudit == beforeAudit && statements.count == 1501, "pressure altered audits or SQL count")
        print("SWIFT_QUEUE_PRESSURE PASSED queries=1500 recovered=1 sql=1501 audits=\(afterAudit)")
        fflush(nil)
    }
    private static func concurrentClosure(_ context: UserContext, id: Int64,
        sql: SQLExecutionEvidenceStore, audit: GraphAudits) async throws {
        guard let telemetry = context.runtimeTelemetry as? StandardTelemetry else { throw TeaQLError.execution("standard module missing") }
        await telemetry.flush()
        await sql.enableAll()
        let beforeAudit = await audit.snapshot().count
        try health(context, label: "SWIFT_CONCURRENT_BASELINE")
        for _ in 0..<30 {
            let rows = try await Q.customerOrders().withIdIs(id).limit(1)
                .comment("inspect graph before concurrent lifecycle calls")
                .purpose("verify generated Q/E and owned shutdown").executeForList(context)
            try require(rows.count == 1 && E.customerOrder(rows[0]).description().eval() == "Submitted graph", "concurrent read")
        }
        print("SWIFT_CONCURRENT_READY"); fflush(nil)
        let owner = Task { await telemetry.shutdown() }
        for _ in 0..<200 where !telemetry.isShutdown { try await Task.sleep(for: .milliseconds(1)) }
        try require(telemetry.isShutdown, "shutdown owner did not start")
        var callers = await withTaskGroup(of: [String: Int].self) { group in
            for index in 0..<18 {
                group.addTask {
                    if index < 12 { await telemetry.shutdown() } else { await telemetry.flush() }
                    return telemetry.exportResources
                }
            }
            var results: [[String: Int]] = []
            for await result in group { results.append(result) }
            return results
        }
        await owner.value; callers.append(telemetry.exportResources)
        try require(callers.count == 19 && callers.allSatisfy { $0["active_http_requests"] == 0
            && $0["closed_http_transports"] == 3 && $0["lifecycle_workers"] == 0 }, "lifecycle caller returned before closure")
        let rows = try await Q.customerOrders().withIdIs(id).limit(1)
            .comment("inspect graph after concurrent lifecycle calls")
            .purpose("verify independent business continuity").executeForList(context)
        try require(rows.count == 1 && E.customerOrder(rows[0]).description().eval() == "Submitted graph", "late concurrent read")
        let afterAudit = await audit.snapshot().count, statements = await sql.snapshot()
        try require(afterAudit == beforeAudit && statements.count == 31, "lifecycle altered business data or audit")
        try health(context, label: "SWIFT_CONCURRENT_CLOSED")
        print("SWIFT_CONCURRENT PASSED callers=19 queries=30 late=1 sql=31 audits=\(afterAudit)"); fflush(nil)
    }
    // Fault setup only: all domain reads, writes and assertions use generated Q/E/save.
    private static func fault(_ path: String, id: Int64, enabled: Bool) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else { throw TeaQLError.execution("fault fixture open") }
        defer { sqlite3_close(connection) }
        let statement = enabled
            ? "CREATE TRIGGER standard_graph_attempt_failure BEFORE UPDATE ON payment_attempt_data WHEN NEW.id = \(id) BEGIN SELECT RAISE(ABORT, 'controlled attempt failure'); END"
            : "DROP TRIGGER standard_graph_attempt_failure"
        guard sqlite3_exec(connection, statement, nil, nil, nil) == SQLITE_OK else { throw TeaQLError.execution("fault fixture setup") }
    }
    private static func run() async throws {
        guard let path = CommandLine.arguments.dropFirst().first else { throw TeaQLError.execution("provide retained SQLite path") }
        StandardTelemetryModule.install()
        var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
        let service = try SQLiteDataService(path: path), audit = GraphAudits(), sql = SQLExecutionEvidenceStore()
        let context = UserContext(runtime: runtime, actor: "standard-graph-verification",
            queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
            auditSink: audit, telemetrySink: sql, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        let first = await audit.snapshot().count
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        let repeated = await audit.snapshot().count
        try require(repeated == first, "repeated bootstrap wrote audits")
        let beforeRejected = await sql.snapshot().count
        do {
            _ = try await Q.customerOrders().limit(1).purpose("validate missing intent").executeForList(context)
            throw TeaQLError.execution("missing comment was accepted")
        } catch let error as RequestIntentError {
            try require(error.code == "REQUEST_COMMENT_REQUIRED", "wrong comment error")
        }
        let afterRejected = await sql.snapshot().count
        try require(afterRejected == beforeRejected, "rejected intent reached SQL")
        if CommandLine.arguments.dropFirst(2).first == "verify-identity" {
            let roots = try await Q.customerOrders().orderByIdDescending().limit(2)
                .selectPlatformWith(Q.platforms().limit(1))
                .comment("load independent roots sharing a readonly reference")
                .purpose("verify generated hydration ownership").executeForList(context)
            try require(roots.count == 2 && roots[0].teaqlEntityRoot !== roots[1].teaqlEntityRoot,
                "different roots share a mutation ledger")
            guard let firstReference = try E.customerOrder(roots[0]).platform().eval(),
                let secondReference = try E.customerOrder(roots[1]).platform().eval(),
                let firstSnapshot = firstReference.teaqlLoadedSnapshot,
                let secondSnapshot = secondReference.teaqlLoadedSnapshot else {
                throw TeaQLError.execution("readonly reference missing")
            }
            try require(firstReference.teaqlEntityRoot !== secondReference.teaqlEntityRoot
                && firstSnapshot === secondSnapshot, "readonly sharing mixed with mutation ownership")
            await context.runtimeTelemetry.flush(); await context.runtimeTelemetry.shutdown()
            print("SWIFT_STANDARD_GRAPH_IDENTITY PASSED independentRoots=2 sharedSnapshots=1")
            return
        }
        let existing = try await Q.customerOrders().orderByIdDescending().limit(1)
            .comment("choose independent fixture identity").purpose("replay on retained database").executeForList(context)
        let base = (existing.first?.id ?? 0) + 1000
        let secret = "GRAPH-PRIVATE-CANARY"
        var root = try Q.customerOrders().comment("create graph root").purpose("prepare payment graph").newEntity(context)
        root.updateId(base); root.updatePlatform(1); root.updateOrderNumber("TRACE-\(base)"); root.updateDescription("Draft graph")
        var available = try Q.orderItems().comment("create available item").purpose("compose payment graph").newEntity(context)
        available.updateId(base + 101); available.updateCustomerOrder(base); available.updateName(secret + " available")
        var removed = try Q.orderItems().comment("create removed item").purpose("compose payment graph").newEntity(context)
        removed.updateId(base + 102); removed.updateCustomerOrder(base); removed.updateName(secret + " removed")
        var pay = try Q.payments().comment("create payment").purpose("compose payment graph").newEntity(context)
        pay.updateId(base); pay.updateCustomerOrder(base); pay.updateReferenceCode("TRACE-PAYMENT")
        _ = pay.auditAs("authorize payment")
        var attempt = try Q.paymentAttempts().comment("create attempt").purpose("compose payment graph").newEntity(context)
        attempt.updateId(base + 301); attempt.updatePayment(base); attempt.updateReferenceCode("TRACE-ATTEMPT")
        pay.paymentAttemptList.append(attempt)
        var shipment = try Q.shipments().comment("create shipment").purpose("compose payment graph").newEntity(context)
        shipment.updateId(base + 401); shipment.updateCustomerOrder(base); shipment.updateReferenceCode("TRACE-SHIPMENT")
        _ = shipment.auditAs("dispatch shipment")
        root.orderItemList = [available, removed]; root.paymentList.append(pay); root.shipmentList.append(shipment)
        await audit.clear(); await sql.enableAll()
        _ = try await root.auditAs("create payment graph").save(context)
        let created = await audit.snapshot()
        try require(created.count == 6 && created.allSatisfy { $0.operation == .create }, "six committed creates required")
        try await facts("create", sql, audit)
        var mixed = try await load(context, id: base)
        try require(mixed.dynamicProperties.value("orderItemList") == nil
            && mixed.dynamicProperties.value("paymentList") == nil, "modeled relations leaked into dynamic properties")
        try require(E.customerOrder(mixed).orderItemList().size().eval() == 2, "created items")
        try require(E.customerOrder(mixed).paymentList().first().id().eval() == base, "same numeric ID across types")
        try require(E.paymentAttempt(mixed.paymentList[0].paymentAttemptList[0]).id().eval() == base + 301, "loaded attempt")
        mixed.updateDescription("Submitted graph")
        mixed.orderItemList[0].updateName(secret + " changed")
        mixed.orderItemList[1].markForDeletion(); _ = mixed.orderItemList[1].auditAs("remove unavailable item")
        mixed.paymentList[0].updateReferenceCode("TRACE-PAYMENT-UPDATED"); _ = mixed.paymentList[0].auditAs("authorize payment")
        mixed.paymentList[0].paymentAttemptList[0].updateReferenceCode("TRACE-ATTEMPT-UPDATED")
        mixed.shipmentList[0].updateReferenceCode("TRACE-SHIPMENT-UPDATED"); _ = mixed.shipmentList[0].auditAs("dispatch shipment")
        try fault(path, id: base + 301, enabled: true)
        await audit.clear(); await sql.enableAll()
        do { _ = try await mixed.auditAs("attempt payment graph").save(context); throw TeaQLError.execution("fault was not exercised") }
        catch is SQLiteError { }
        let rolledBackAudits = await audit.snapshot()
        try require(rolledBackAudits.isEmpty, "rolled back graph leaked committed audits")
        try await facts("rollback", sql, audit)
        try fault(path, id: base + 301, enabled: false)
        let rolledBack = try await load(context, id: base)
        try require(E.customerOrder(rolledBack).description().eval() == "Draft graph"
            && E.customerOrder(rolledBack).orderItemList().size().eval() == 2 && rolledBack.version == 1, "rollback left changed data")
        await audit.clear(); await sql.enableAll()
        _ = try await mixed.auditAs("retry payment graph").save(context)
        let savedAudits = await audit.snapshot()
        try require(savedAudits.count == 6 && savedAudits.filter { $0.operation == .delete }.count == 1
            && savedAudits.filter { $0.operation == .update }.count == 5, "mixed retry must commit six audited mutations")
        try await facts("retry", sql, audit)
        let saved = try await load(context, id: base)
        try require(E.customerOrder(saved).description().eval() == "Submitted graph"
            && E.customerOrder(saved).orderItemList().size().eval() == 1 && saved.version == 2, "retry graph readback")
        let deleted = try await Q.orderItems().withIdIs(base + 102).deletedRowsOnly().limit(1)
            .comment("inspect marked deletion").purpose("verify graph deletion persisted").executeForList(context)
        try require(deleted.count == 1 && deleted[0].version < 0, "deleted child missing")
        if ProcessInfo.processInfo.environment["TEAQL_STANDARD_QUEUE_PROBE"] == "true" {
            try await pressure(context, id: base, sql: sql, audit: audit)
        }
        if ProcessInfo.processInfo.environment["TEAQL_STANDARD_CONCURRENT_PROBE"] == "true" {
            try await concurrentClosure(context, id: base, sql: sql, audit: audit)
        }
        await context.runtimeTelemetry.flush()
        let probe = ProcessInfo.processInfo.environment["TEAQL_STANDARD_EXPORT_PROBE"] == "true"
        if probe { await context.runtimeTelemetry.flush() }
        await context.runtimeTelemetry.shutdown()
        if probe, let telemetry = context.runtimeTelemetry as? StandardTelemetry {
            let data = try JSONSerialization.data(withJSONObject: ["failed_records": telemetry.exportLosses,
                "rejected": telemetry.rejectedRecords, "responses": telemetry.exportResponses], options: [.sortedKeys])
            print("SWIFT_STANDARD_EXPORT_HEALTH " + String(decoding: data, as: UTF8.self))
        }
        print("SWIFT_STANDARD_GRAPH PASSED create=6 rollback=0 retry=6 deleted=1 first_seed_audits=\(first) repeat_seed_audits=0 ordinary_sql_logs=0")
    }
}
