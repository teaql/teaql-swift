import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

@main enum TraceChainVerification {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: Swift generated Trace Chain: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let path = CommandLine.arguments.dropFirst().first ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("teaql-swift-generated-trace-\(UUID()).sqlite").path
        print("database retained: \(path)")
        try await generatedBootstrapProofs(path: path)
        if ProcessInfo.processInfo.environment["TEAQL_SWIFT_TRACE_SCENARIO"] == "bootstrap-intent" { return }
        let service = try SQLiteDataService(path: path)
        let audit = AuditCapture(), sql = SQLExecutionEvidenceStore()
        let commands = CommandCapture(service: service, audit: audit)
        var runtime = TeaQLRuntime()
        try runtime.install(GeneratedRuntimeModule.module)
        let context = UserContext(runtime: runtime, actor: "trace-conformance", queryExecutor: service,
            mutationExecutor: commands, requestPolicy: RequestPolicy { $0 }, auditSink: audit,
            telemetrySink: sql, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        let latest = try await Q.customerOrders().orderByIdDescending().limit(1)
            .comment("choose unused verification IDs").purpose("repeat without deleting prior evidence")
            .executeForList(context).first
        let base = (latest?.id).map { $0 + 10_000 } ?? 100
        if ProcessInfo.processInfo.environment["TEAQL_SWIFT_TRACE_SCENARIO"] == "aggregate-membership" {
            try await generatedAggregateProofs(runtime: runtime, service: service, base: base)
            return
        }
        if ProcessInfo.processInfo.environment["TEAQL_SWIFT_TRACE_SCENARIO"] == "checker-overlap" {
            try await generatedCheckerOverlap(runtime: runtime, service: service, base: base)
            return
        }
        let beforeStarts = await commands.starts()
        await audit.clear(); await sql.enableAll(); await commands.clear()
        do {
            _ = try await order(context, id: nil, label: "rejected").auditAs("\u{0085}").save(context)
            throw TeaQLError.execution("blank root comment was accepted")
        } catch let error as RequestIntentError {
            try require(error.code == "REQUEST_COMMENT_REQUIRED" && error.field == "comment", "wrong intent error")
        }
        do {
            _ = try await Q.customerOrders().limit(1).purpose("validate missing query intent").executeForList(context)
            throw TeaQLError.execution("missing query comment was accepted")
        } catch let error as RequestIntentError {
            try require(error.code == "REQUEST_COMMENT_REQUIRED", "wrong query intent error")
        }
        let rejectedCommands = await commands.snapshot(), rejectedSQL = await sql.snapshot(), rejectedAudit = await audit.snapshot()
        let starts = await commands.starts()
        try require(rejectedCommands.isEmpty && rejectedSQL.isEmpty && rejectedAudit.isEmpty && starts == beforeStarts,
            "invalid intent reached transaction/provider/audit")
        print("PASS generated required intent before provider/transaction access")
        try graphIdentityControls()
        try await normativeGraph(context, commands: commands, sql: sql, audit: audit, base: base)
        try await generatedThreeLevelQuery(context, sql: sql, base: base)
        try await assignedGraph(context, commands: commands, sql: sql, audit: audit)
        try await ledgerReplacement(context, commands: commands, sql: sql, audit: audit, base: base)
        try await sameIDVersions(context, commands: commands, sql: sql, audit: audit, base: base)
        try await concurrentGraphs(context, commands: commands, sql: sql, audit: audit, base: base)
        try await sharedOwnershipProofs(runtime: runtime, service: service, base: base)
        try await generatedCheckerOverlap(runtime: runtime, service: service, base: base)
        try await generatedPaginationProofs(runtime: runtime, service: service, base: base)
        try await generatedAggregateProofs(runtime: runtime, service: service, base: base)
        var native = UserContext(runtime: runtime, actor: "trace-conformance", queryExecutor: service,
            mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, auditSink: audit,
            telemetrySink: sql, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
        try await generatedFailureProofs(native, sql: sql, audit: audit, path: path, base: base)
        native.querySQLLogEnabled = false; native.mutationSQLLogEnabled = false
        for (index, logging) in [false, true].enumerated() {
            var privacyContext = context
            privacyContext.querySQLLogEnabled = logging; privacyContext.mutationSQLLogEnabled = logging
            try await generatedLoadedPrivacy(privacyContext, commands: commands, sql: sql, audit: audit,
                base: base + Int64(index) * 20_000)
        }
        print("PASS: Swift generated Trace Chain example")
    }
}
