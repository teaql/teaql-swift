import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

// Keep the package-only schema capability on the real SQLite provider. The
// trusted policy observes generated query intent without replacing that provider.
private final class BootstrapQueries: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [QueryIntent] = []
    func observe(_ query: SelectQuery) throws -> SelectQuery {
        let intent = try QueryIntent(comment: query.comment, purpose: query.purpose)
        lock.withLock { values.append(intent) }
        return query
    }
    func snapshot() -> [QueryIntent] { lock.withLock { values } }
    func clear() { lock.withLock { values.removeAll() } }
}
private actor BootstrapDiagnostics: DiagnosticSQLLogSink {
    private var values: [SQLExecutionMetadata] = []
    func write(_ metadata: SQLExecutionMetadata) { values.append(metadata) }
    func snapshot() -> [SQLExecutionMetadata] { values }
    func clear() { values.removeAll() }
}
private actor BootstrapCommands: GraphTransactionExecutor {
    let service: SQLiteDataService
    private var requests: [MutationRequest] = [], results: [MutationResult] = []
    private var active = false, commits = 0
    init(_ service: SQLiteDataService) { self.service = service }
    func beginGraphTransaction() async throws {
        try await service.beginGraphTransaction(); active = true
    }
    func commitGraphTransaction() async throws {
        try await service.commitGraphTransaction(); active = false; commits += 1
    }
    func rollbackGraphTransaction() async throws {
        try await service.rollbackGraphTransaction(); active = false
    }
    func execute(_ request: MutationRequest) async throws -> MutationResult {
        requests.append(request)
        let result = try await service.execute(request)
        results.append(result)
        return result
    }
    func committed() -> Bool { !active && commits > 0 }
    func snapshot() -> (requests: [MutationRequest], results: [MutationResult], commits: Int) {
        (requests, results, commits)
    }
    func clear() { requests.removeAll(); results.removeAll(); commits = 0 }
}
private actor BootstrapAudit: AuditSink {
    let commands: BootstrapCommands
    let path: String
    private var values: [AuditEvent] = []
    init(_ commands: BootstrapCommands, path: String) { self.commands = commands; self.path = path }
    func record(_ event: AuditEvent) async throws {
        let committed = await commands.committed()
        try require(committed, "bootstrap audit escaped before graph COMMIT")
        // A second read-only connection inside the callback proves visibility,
        // rather than inferring commit from a successful INSERT result.
        var database: OpaquePointer?, statement: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        try require(opened == SQLITE_OK, "bootstrap audit reader failed")
        let prepared = sqlite3_prepare_v2(database, "SELECT id, version, name FROM platform_data WHERE id=1", -1,
            &statement, nil)
        try require(prepared == SQLITE_OK, "bootstrap audit SELECT failed")
        let visible = sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int64(statement, 0) == 1
            && sqlite3_column_int64(statement, 1) == 1
            && String(cString: sqlite3_column_text(statement, 2)) == "Trace Chain Verification"
        try require(visible, "bootstrap audit reader did not see committed Platform#1")
        values.append(event)
    }
    func snapshot() -> [AuditEvent] { values }
    func clear() { values.removeAll() }
}
private func bootstrapRoute(_ entry: SQLExecutionMetadata, mutation: Bool) throws {
    try require(entry.executionOutcome == "success"
        && entry.tracePath.map(\.kind) == ["operation", mutation ? "entity" : "request", "provider", "sql"]
        && entry.tracePath.first?.name == "Platform"
        && entry.tracePath[2].name == "sqlite" && entry.tracePath.last?.name == entry.operation.rawValue,
        "bootstrap physical SQL route is not canonical")
}
func generatedBootstrapProofs(path: String) async throws {
    for logging in [false, true] {
        let database = path + (logging ? ".bootstrap-on" : ".bootstrap-off")
        let service = try SQLiteDataService(path: database)
        let commands = BootstrapCommands(service), queries = BootstrapQueries()
        let audit = BootstrapAudit(commands, path: database)
        let sql = SQLExecutionEvidenceStore(), diagnostics = BootstrapDiagnostics()
        var runtime = TeaQLRuntime()
        try runtime.install(GeneratedRuntimeModule.module)
        // All observers precede ensureSchema. No synthetic RuntimeModule or
        // replacement bootstrap callback is used here.
        var context = UserContext(runtime: runtime, actor: "caller-before-bootstrap", auditCategory: "caller-category",
            queryExecutor: service, mutationExecutor: commands,
            requestPolicy: RequestPolicy { try queries.observe($0) }, auditSink: audit,
            telemetrySink: sql, diagnosticSQLLogSink: diagnostics)
        context.querySQLLogEnabled = logging; context.mutationSQLLogEnabled = logging
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        try require(context.actor == "caller-before-bootstrap" && context.auditCategory == "caller-category",
            "bootstrap changed caller identity")
        let first = await commands.snapshot(), events = await audit.snapshot(), physical = await sql.snapshot()
        let lookup = queries.snapshot()
        try require(lookup.count == 1, "one actual generated bootstrap lookup required")
        let firstWrites = first.requests.count
        try require((firstWrites == 0 || firstWrites == 1) && first.results.count == firstWrites
            && events.count == firstWrites && first.commits == firstWrites,
            "bootstrap command/result/committed audit counts disagree")
        try require(physical.count == 1 + 2 * firstWrites && physical[0].resultCount == 1 - firstWrites,
            "bootstrap lookup/write/readback physical statements disagree")
        try bootstrapRoute(physical[0], mutation: false)
        try require(physical[0].comment == lookup[0].comment && physical[0].purpose == lookup[0].purpose,
            "bootstrap physical lookup lost its generated request intent")
        let diagnosticCount = await diagnostics.snapshot().count
        try require(diagnosticCount == (logging ? physical.count : 0),
            "bootstrap diagnostic logging switch ignored")
        if firstWrites == 1 {
            let request = first.requests[0], mutation = request.mutation
            try require(mutation.entity.name == "Platform" && mutation.kind == .create
                && (mutation.id ?? mutation.values["id"]) == .int(1), "bootstrap typed target identity missing")
            let wanted = [NodeExpectation(type: "Platform", id: 1, reason: request.intent.comment)]
            try checkChain(mutation.mutationLineage ?? [], wanted, boundary: "bootstrap raw command")
            guard let metadata = first.results[0].metadata else { throw TeaQLError.execution("bootstrap result metadata missing") }
            try require(metadata.statements.count == 2, "bootstrap raw result lacks distinct write/readback")
            let write = metadata.statements[0], read = metadata.statements[1]
            try bootstrapRoute(write, mutation: true); try bootstrapRoute(read, mutation: false)
            try require(write.operation == .insert && write.affectedRows == 1
                && read.operation == .select && read.resultCount == 1
                && read.comment == request.intent.comment && read.purpose == "verify the persisted mutation result",
                "bootstrap raw write/readback intent or outcome lost")
            for raw in metadata.statements {
                try require(raw.auditReason == request.intent.comment, "raw result changed bootstrap request intent")
                try checkChain(raw.mutationLineage, wanted, boundary: "bootstrap raw SQL")
            }
            let event = events[0]
            try require(event.entity == "Platform" && event.entityID == .int(1)
                && event.actor == "teaql-generated-bootstrap" && event.category == "runtime-bootstrap",
                "bootstrap audit target/actor/category lost")
            let safeReason = request.intent.comment.replacingOccurrences(of: "1", with: "[REDACTED]")
            try require(event.reason == safeReason, "bootstrap audit did not preserve safely projected intent")
            let safeWanted = [NodeExpectation(type: "Platform", id: 1, reason: safeReason)]
            try checkChain(event.mutationLineage ?? [], safeWanted, boundary: "bootstrap committed safe audit")
            for entry in physical.dropFirst() {
                try bootstrapRoute(entry, mutation: entry.operation == .insert)
                try require(entry.auditReason == safeReason, "bootstrap safe SQL lost request intent")
                try checkChain(entry.mutationLineage, safeWanted, boundary: "bootstrap safe physical SQL")
            }
        }
        await commands.clear(); queries.clear(); await audit.clear(); await sql.enableAll(); await diagnostics.clear()
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        let repeatState = await commands.snapshot(), repeatEvents = await audit.snapshot(), repeatSQL = await sql.snapshot()
        let repeatLookup = queries.snapshot()
        try require(repeatState.requests.isEmpty && repeatState.results.isEmpty && repeatState.commits == 0
            && repeatEvents.isEmpty, "repeated bootstrap wrote or audited unchanged data")
        try require(repeatLookup == lookup, "repeated bootstrap changed its owned query intent")
        try require(repeatSQL.count == 1 && repeatSQL[0].comment == lookup[0].comment
            && repeatSQL[0].purpose == lookup[0].purpose && repeatSQL[0].resultCount == 1,
            "repeated bootstrap lookup differs")
        try bootstrapRoute(repeatSQL[0], mutation: false)
        let repeatDiagnosticCount = await diagnostics.snapshot().count
        try require(repeatDiagnosticCount == (logging ? 1 : 0), "repeat bootstrap diagnostics differ")
        let roots = try await Q.platforms().withIdIs(1).limit(1)
            .comment("read bootstrap root").purpose("verify generated bootstrap persistence").executeForList(context)
        try require(roots.count == 1 && roots[0].id == 1 && roots[0].version == 1, "generated root reload failed")
        let record: [String: Any] = ["case": "TC-REQ-09", "path": "generated default bootstrap", "logging": logging,
            "firstWrites": firstWrites, "repeatWrites": 0, "committedAudits": firstWrites,
            "physicalStatements": physical.count, "diagnostics": logging ? physical.count : 0,
            "comment": lookup[0].comment, "purpose": lookup[0].purpose, "restoredContext": true]
        print("BOOTSTRAP INTENT " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
    }
    print("PASS Swift generated bootstrap intent: logging off/on, committed audit, repeat no writes")
}
