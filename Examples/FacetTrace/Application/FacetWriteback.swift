import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

actor WritebackAudit: AuditSink {
    private var events: [AuditEvent] = []
    func record(_ event: AuditEvent) { events.append(event) }
    func snapshot() -> [AuditEvent] { events }
}
func verifyWriteback(_ service: SQLiteDataService, runtime: TeaQLRuntime) async throws -> Int {
    for logging in [false, true] {
        let audit = WritebackAudit(), evidence = SQLExecutionEvidenceStore()
        let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
            requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: evidence,
            querySQLLogEnabled: logging, mutationSQLLogEnabled: logging)
        let parents = try await Q.schoolTypes().withIdIs(1001).limit(1)
            .selectSchoolListWith(facets(false)).comment(comment).purpose(purpose).executeForList(context)
        var parent = parents[0]
        let beforeNoop = await evidence.snapshot().count
        _ = try await parent.auditAs("save unmodified Facet parent").save(context)
        let noopFacts = Array(await evidence.snapshot().dropFirst(beforeNoop))
        let noopEvents = await audit.snapshot()
        let noopWrites = noopFacts.filter { $0.operation != .select }.count
        try require(noopWrites == 0 && noopEvents.isEmpty, "Facet metadata dirtied an unmodified graph")
        let childID = try E.schoolType(parent).schoolList().first().id().eval()
        let oldVersion = try E.school(parent.schoolList[0]).version().eval()
        let oldAddress = try E.school(parent.schoolList[0]).address().eval()
        let newAddress = oldAddress == "12 River Road" ? "14 River Road" : "12 River Road"
        parent.schoolList[0].updateAddress(newAddress)
        try require(try E.school(parent.schoolListResult[0]).address().eval() == newAddress,
            "array writeback diverged from SmartList carrier")
        try verifyFacets(parent.schoolListResult, includeAll: false, count: 2)
        _ = try await parent.auditAs("update loaded child address through root").save(context)
        let rows = try await Q.schools().withNameIs("Facet School A").limit(1)
            .comment("read committed address").purpose("verify array writeback").executeForList(context)
        try require(try E.school(rows[0]).id().eval() == childID, "fixture identity changed")
        try require(try E.school(rows[0]).address().eval() == newAddress, "audited root save lost array mutation")
        let events = await audit.snapshot()
        try require(events.count == 1 && events[0].entity == "School" && events[0].operation == .update
            && events[0].reason == "update loaded child address through root", "exact committed child audit missing")
        let facts = await evidence.snapshot()
        let writes = facts.filter { $0.operation != .select }
        try require(writes.count == 1 && writes[0].operation == .update && writes[0].affectedRows == 1,
            "exact real child UPDATE was not observed")
        guard let id = childID, let beforeVersion = oldVersion,
              let afterVersion = try E.school(rows[0]).version().eval() else {
            throw TeaQLError.execution("writeback identity/version missing")
        }
        try require(afterVersion == beforeVersion + 1, "child version did not advance exactly once")
        try require(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("facets"),
            "query carrier entered committed audit")
        try require(parent.toRecord()["facets"] == nil && parent.toRecord()["loadedRelations"] == nil,
            "query carrier entered persistence record")
        try emitProof(WritebackProof(logging: logging, id: id, oldAddress: oldAddress ?? "",
            newAddress: newAddress, beforeVersion: beforeVersion, afterVersion: afterVersion,
            noopWrites: noopWrites, noopAudits: noopEvents.count, updateWrites: writes.count,
            audits: events.count, auditEvents: events, sql: facts.map(StatementProof.init)))
    }
    return 2
}
