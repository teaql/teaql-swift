import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TeaQLError.execution(message) }
}

@main
enum ConformanceApp {
    static func main() async throws {
        let directory = FileManager.default.currentDirectoryPath + "/.local"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/conformance.sqlite"
        try? FileManager.default.removeItem(atPath: path)

        let database = try SQLiteDataService(path: path)
        var runtime = TeaQLRuntime()
        try runtime.install(GeneratedRuntimeModule.module)

        let evidence = SQLExecutionEvidenceStore()
        let context = UserContext(
            runtime: runtime,
            actor: "swift-conformance",
            queryExecutor: database,
            mutationExecutor: database,
            requestPolicy: RequestPolicy { $0 },
            telemetrySink: evidence
        )
        try await context.ensureSchema(GeneratedRuntimeModule.module)
        print("PASS ensureSchema (context-scoped SQLite DDL from Runtime Module)")

        var invalid = WorkItem()
        invalid.updatePlatform(1)
        let evidenceBeforeInvalid = await evidence.snapshot().count
        do {
            _ = try await invalid.auditAs("Checker must reject a missing title").save(context)
            throw TeaQLError.execution("Checker accepted a missing required title")
        } catch let error as CheckException {
            try require(error.violations.contains {
                $0.ruleID == "required" && String(describing: $0.location).contains("title")
            }, "Checker did not identify title")
        }
        let evidenceAfterInvalid = await evidence.snapshot().count
        try require(evidenceAfterInvalid == evidenceBeforeInvalid,
                    "Checker must run before mutation SQL")
        print("PASS Checker (canonical title key, rejected before SQL)")

        var item = WorkItem()
        item.updateTitle("Verify Swift runtime")
        item.updatePlatform(1)
        let created = try await item.auditAs("Create conformance work item").save(context)
        try require(created.id > 0 && created.version == 1, "Create did not return ID/version")
        print("PASS Create (id=\(created.id), version=\(created.version))")

        let queriedList = try await Q.workItems().selectSelfFields()
            .withIdIs(created.id)
            .comment("Load the complete work item before mutation")
            .purpose("Verify typed Q API and update semantics")
            .executeForList(context)
        try require(queriedList.count == 1, "Q API did not return one WorkItem")
        var queried = queriedList[0]
        try require(queried.title == "Verify Swift runtime", "Q API returned the wrong title")
        print("PASS Q API (typed SmartList<WorkItem>)")

        try require(try E.workItem(queried).title().eval() == "Verify Swift runtime",
                    "E loaded scalar mismatch")
        try require(try E.workItem(queried).description().orElse("N/A") == "N/A",
                    "E null fallback mismatch")
        let minimal = try await Q.workItemsWithMinimalFields().withIdIs(created.id)
            .comment("Load only mandatory identity fields")
            .purpose("Verify E not-loaded semantics")
            .executeForList(context)
        do {
            _ = try E.workItem(minimal[0]).title().eval()
            throw TeaQLError.execution("E treated not-loaded title as null")
        } catch is TeaQLNotLoadedError {}
        print("PASS E API (loaded, null fallback, and not-loaded are distinct)")

        let oldVersion = queried.version
        queried.updateTitle("Verified Swift runtime")
        queried = try await queried.auditAs("Update conformance work item").save(context)
        try require(queried.version == oldVersion + 1, "Update did not increment version")
        print("PASS Update (version \(oldVersion) -> \(queried.version))")

        queried.markForDeletion()
        _ = try await queried.auditAs("Delete conformance work item").save(context)
        let remaining = try await Q.workItems().withIdIs(created.id)
            .comment("Verify soft-deleted work item is excluded")
            .purpose("Verify delete semantics")
            .executeForList(context)
        try require(remaining.isEmpty, "Default Q returned a deleted row")
        print("PASS Delete (default Q excludes deleted rows)")
        print("PASS Swift minimum runtime conformance: 7/7")
    }
}
