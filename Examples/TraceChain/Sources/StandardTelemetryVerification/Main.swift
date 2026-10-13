import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
import TeaQLStandardTelemetry

private actor AuditCount: AuditSink {
    private var count = 0
    func record(_ event: AuditEvent) { count += 1 }
    func value() -> Int { count }
}

@main enum StandardTelemetryVerification {
    static func main() async {
        do { try await run() }
        catch {
            // The probe never prints raw exception text or SQL bindings.
            FileHandle.standardError.write(Data("FAIL Swift standard telemetry: \(type(of: error))\n".utf8))
            exit(1)
        }
    }
    private static func run() async throws {
        guard let path = CommandLine.arguments.dropFirst().first else {
            throw TeaQLError.execution("provide a fresh retained SQLite path")
        }
        // One application-assembly registration, not per-query instrumentation.
        // Disabled configuration never constructs the optional SDK pipeline.
        StandardTelemetryModule.install()
        var runtime = TeaQLRuntime()
        try runtime.install(GeneratedRuntimeModule.module)
        let service = try SQLiteDataService(path: path), audit = AuditCount()
        let sql = SQLExecutionEvidenceStore()
        let context = UserContext(runtime: runtime, actor: "standard-telemetry-verification",
            queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
            auditSink: audit, telemetrySink: sql, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        let afterFirst = await sql.snapshot().count
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        let afterSecond = await sql.snapshot().count
        guard afterSecond == afterFirst + 1, await audit.value() == 1 else {
            throw TeaQLError.execution("repeated schema must inspect the root without rewriting it")
        }
        for _ in 0..<2 {
            let rows = try await Q.platformsWithMinimalFields().selectName()
                .withIdIs(1).orderByIdAscending().limit(1)
                .comment("load the generated Domain Root").purpose("verify the seeded application")
                .executeForList(context)
            guard rows.count == 1, let root = rows.first,
                try E.platform(root).id().eval() == 1,
                try E.platform(root).name().eval() == "Trace Chain Verification" else {
                throw TeaQLError.execution("generated Q/E root check failed")
            }
        }
        let entries = await sql.snapshot()
        guard entries.count == 6, entries.filter({ $0.operation == .insert }).count == 1,
            entries.allSatisfy({ $0.executionOutcome == "success" }) else {
            throw TeaQLError.execution("seed, repeated seed and Q/E physical evidence differs")
        }
        await context.runtimeTelemetry.flush()
        await context.runtimeTelemetry.shutdown()
        print("PASS Swift standard telemetry: seeded root=1 repeated seed writes=0 Q/E=2 SQL=6 committed audit=1")
    }
}
