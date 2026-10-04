import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TeaQLError.execution(message) }
}
let secret = "Campus Learning Platform"
let comment = "load \(secret) Facets"
let purpose = "verify \(secret) generated provenance"
func facets(_ includeAll: Bool) -> SchoolRequest<RequestDraft> {
    Q.schools().filterBySchoolType(1001).orderByIdAscending().limit(1)
        .facetBySchoolTypeAs("types", Q.schoolTypes().orderByIdAscending().limit(10)
            .facetByPlatformAs("platforms", Q.platforms().withNameIs(secret)
                .orderByIdAscending().limit(10), includeAllFacets: includeAll),
            includeAllFacets: includeAll)
}
func verifyFacets<T>(_ list: SmartList<T>, includeAll: Bool, count: Int64) throws {
    guard let types = list.facets["types"], let platforms = types.facets["platforms"] else {
        throw TeaQLError.execution("missing requested nested Facet metadata")
    }
    try require(types.map { $0["id"] ?? .null } == (includeAll ? [.int(1001), .int(1002)]
        : count > 0 ? [.int(1001)] : []), "wrong type Facet membership")
    try require(types.map { $0["count"] ?? .null } == (includeAll ? [.int(count), .int(0)]
        : count > 0 ? [.int(count)] : []), "count must retain full filtered membership before limit")
    try require(platforms.map { $0["id"] ?? .null } == (includeAll || count > 0 ? [.int(1)] : []),
        "wrong nested platform membership")
    try require(platforms.map { $0["count"] ?? .null } == (includeAll ? [.int(2)]
        : count > 0 ? [.int(1)] : []), "nested Facet counted excluded type candidates")
}
func verifySQL(_ facts: [SQLExecutionMetadata],
    _ diagnostics: [String], root: String, loaded: Bool, logging: Bool,
    expectedRoutes: [[String]]) throws {
    try require(facts.count > 3, "actual SQLite statements not observed")
    try require(facts.map { $0.tracePath.filter { $0.kind == "relation" }.map(\.name) } == expectedRoutes,
        "ordered physical paths differ, including count-source SELECTs")
    let routes = loaded ? [[], ["schoolList"], ["schoolList", "schoolType"],
        ["schoolList", "schoolType", "platform"]] : [[], ["schoolType"], ["schoolType", "platform"]]
    for fact in facts {
        let path = fact.tracePath, edges = path.filter { $0.kind == "relation" }
        try require(path.map(\.kind) == ["operation", "request"]
            + Array(repeating: "relation", count: edges.count) + ["provider", "sql"], "noncanonical path")
        try require(path.prefix(2).map(\.name) == [root, root], "lost original operation root")
        try require(routes.contains(edges.map(\.name)), "unexpected relation route")
        var entity = root
        for edge in edges {
            try require(edge.comment == entity + "." + edge.name, "lost qualified relation detail")
            entity = edge.name == "schoolList" ? "School" : edge.name == "schoolType" ? "SchoolType" : "Platform"
        }
        try require(path.suffix(2).map(\.name) == ["sqlite", "select"], "wrong physical route")
        try require(path.map(\.level) == Array(path.indices), "noncanonical levels")
        try require(path.allSatisfy { $0.entityID == nil } && fact.mutationLineage.isEmpty,
            "query path acquired mutation identities or lineage")
        try require(fact.executionOutcome == "success" && fact.resultCount != nil,
            "metadata must describe actual returned SQLite records")
        try require(fact.comment == "load [REDACTED] Facets"
            && fact.purpose == "verify [REDACTED] generated provenance", "future-only private intent leaked")
    }
    try require(facts.contains { $0.tracePath.filter { $0.kind == "relation" }.count == (loaded ? 3 : 2) },
        "nested materialization SQL was not observed")
    try require(diagnostics.count == (logging ? facts.count : 0), "diagnostic logging switch mismatch")
    try require(!facts.description.contains(secret) && !diagnostics.description.contains(secret), "private safe sink leak")
    try require(comment == "load \(secret) Facets" && purpose == "verify \(secret) generated provenance",
        "safe projection changed caller-owned intent")
}
@main enum FacetAcceptance {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL Swift Facet: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw TeaQLError.execution("usage: FacetAcceptance <retained-sqlite-path>")
        }
        let service = try SQLiteDataService(path: CommandLine.arguments[1])
        var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
        let seed = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
            requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
        try await seed.ensureSchema(GeneratedRuntimeModule.module)
        for name in ["Facet School A", "Facet School B"] {
            let existing = try await Q.schools().withNameIs(name).limit(1)
                .comment("find retained fixture").purpose("idempotent fixture seed").executeForList(seed)
            if existing.isEmpty {
                var school = try Q.schools().comment("initialize fixture").purpose("seed generated Facets").newEntity(seed)
                school.updatePlatform(1); school.updateSchoolType(1001); school.updateName(name)
                school.updateAddress("12 River Road"); school.updateEstablishedDate(Date(timeIntervalSince1970: 810950400))
                school.updateStudentCapacity(800); school.updateActive(true)
                school.updateCreateTime(Date()); school.updateUpdateTime(Date())
                _ = try await school.auditAs("seed retained generated Facet fixture").save(seed)
            }
        }
        var scenarios = 0
        for logging in [false, true] { for includeAll in [false, true] {
            for empty in [false, true] {
                let evidence = SQLExecutionEvidenceStore()
                let diagnostic = TextDiagnosticSQLLogSink(writer: { _ in })
                let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
                    requestPolicy: RequestPolicy { query in
                        try require((query.comment == comment && query.purpose == purpose)
                            || (query.comment == "independent \(secret)" && query.purpose == "verify request isolation"),
                            "policy lost original intent")
                        return query
                    }, telemetrySink: evidence,
                    diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging)
                var query = facets(includeAll)
                if empty { query = query.withNameIs("absent") }
                let result: SmartList<School> = try await query.comment(comment).purpose(purpose).executeForList(context)
                try require(result.count == (empty ? 0 : 1), "wrong paged root rows")
                try verifyFacets(result, includeAll: includeAll, count: empty ? 0 : 2)
                let facts = await evidence.snapshot(), diagnostics = await diagnostic.snapshot()
                try verifySQL(facts, diagnostics,
                    root: "School", loaded: false, logging: logging, expectedRoutes: queryRoutes("root"))
                let choiceProof = try childProof(result, id: 0, members: result.map(\.id))
                let independent = try await Q.schoolTypes().withIdIs(1001).limit(1)
                    .comment("independent \(secret)").purpose("verify request isolation").executeForList(context)
                let nextFacts = Array(await evidence.snapshot().dropFirst(facts.count))
                try require(independent.count == 1 && nextFacts.count == 1
                    && nextFacts[0].comment == "independent \(secret)", "redactions escaped invocation")
                try emitProof(QueryProof(branch: "root", logging: logging, includeAll: includeAll,
                    empty: empty, visible: result.count, types: choiceProof.types, platforms: choiceProof.platforms,
                    sql: facts.map(StatementProof.init), diagnostics: diagnostics.count,
                    nextSQL: nextFacts.map(StatementProof.init)))
                scenarios += 1
            }
        } }
        scenarios += try await verifyLoaded(service, runtime: runtime)
        scenarios += try await verifyWriteback(service, runtime: runtime)
        print("Swift generated Facet acceptance passed: \(scenarios) scenarios; root/nested/to-many/to-one/empty/includeAll; both logging modes; retained school.db")
    }
}
