import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

func verifyLoaded(_ service: SQLiteDataService, runtime: TeaQLRuntime) async throws -> Int {
    var scenarios = 0
    for logging in [false, true] { for includeAll in [false, true] {
        for threshold in [0, 32] {
            let evidence = SQLExecutionEvidenceStore(), diagnostic = TextDiagnosticSQLLogSink(writer: { _ in })
            let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
                requestPolicy: RequestPolicy { query in
                    try require(query.comment == comment && query.purpose == purpose, "derived policy lost original intent")
                    return query
                }, telemetrySink: evidence, diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging)
            let parents = try await Q.schoolTypes().orderByIdAscending().limit(10)
                .selectSchoolListWith(facets(includeAll).topNProbeParentThreshold(threshold))
                .comment(comment).purpose(purpose).executeForList(context)
            try require(parents.map(\.id) == [1001, 1002], "wrong generated parents")
            for parent in parents {
                let children: SmartList<School> = parent.schoolListResult
                let count = parent.id == 1001 ? 1 : 0
                try require(children.isLoaded && children.count == count, "loaded empty/nonempty carrier lost")
                try require(try E.schoolType(parent).schoolList().size().eval() == count, "E lost loaded child list")
                try require(parent.schoolList.map(\.id) == children.map(\.id), "array convenience diverged")
                try verifyFacets(children, includeAll: includeAll, count: parent.id == 1001 ? 2 : 0)
                let encoded = String(decoding: try JSONEncoder().encode(parent), as: UTF8.self)
                try require(!encoded.contains("schoolList") && !encoded.contains("facets"), "query carrier leaked into model JSON")
                try require(parent.teaqlEntityRoot.snapshot().isEmpty, "hydration dirtied mutation ledger")
                try require(parent.teaqlLoadedSnapshot?.record["facets"] == nil
                    && parent.teaqlLoadedSnapshot?.record["loadedRelations"] == nil, "sidecar entered mutation snapshot")
                var copy = parent
                copy.schoolList.removeAll()
                try require(copy.schoolListResult.isEmpty && copy.schoolListResult.facets.count == children.facets.count,
                    "mutable array is not backed by the same SmartList")
                try require(parent.schoolListResult.count == count, "independent value copy changed owner")
            }
            let facts = await evidence.snapshot(), diagnostics = await diagnostic.snapshot()
            try verifySQL(facts, diagnostics, root: "SchoolType", loaded: true, logging: logging,
                expectedRoutes: queryRoutes("to-many", threshold: threshold))
            try emitProof(QueryProof(branch: "to-many", logging: logging, includeAll: includeAll,
                threshold: threshold, visible: parents.count,
                children: try parents.map { try childProof($0.schoolListResult, id: $0.id,
                    members: $0.schoolList.map(\.id)) },
                sql: facts.map(StatementProof.init), diagnostics: diagnostics.count))
            scenarios += 1
        }
        for empty in [false, true] {
            let evidence = SQLExecutionEvidenceStore(), diagnostic = TextDiagnosticSQLLogSink(writer: { _ in })
            let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
                requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
                diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging)
            var types = Q.schoolTypes().limit(10).facetByPlatformAs("platforms", Q.platforms().withNameIs(secret).limit(10),
                includeAllFacets: includeAll)
            if empty { types = types.withIdIs(-1) }
            let rows = try await Q.schools().orderByIdAscending().limit(10).selectSchoolTypeWith(types)
                .comment(comment).purpose(purpose).executeForList(context)
            try require(rows.count == 2, "forward fixture rows missing")
            var hiddenDetailFailures = 0
            for row in rows {
                let carrier: SmartList<SchoolType> = row.schoolTypeResult
                try require(carrier.isLoaded && carrier.count == 1, "filtered detail erased actual FK identity")
                guard let identity = try E.school(row).schoolType().eval() else {
                    throw TeaQLError.execution("forward identity is not null")
                }
                try require(try E.school(row).schoolTypeId().eval() == 1001
                    && E.schoolType(identity).id().eval() == 1001, "filtered identity changed")
                if empty {
                    do {
                        _ = try E.schoolType(identity).code().eval()
                        throw TeaQLError.execution("hidden detail became loaded-null")
                    } catch is TeaQLNotLoadedError { hiddenDetailFailures += 1 }
                } else {
                    try require(try E.schoolType(identity).code().eval() == "PRIMARY", "loaded detail changed")
                }
                guard let platforms = carrier.facets["platforms"] else { throw TeaQLError.execution("forward Facet missing") }
                try require(platforms.map { $0["count"] ?? .null } == (includeAll || !empty ? [.int(empty ? 0 : 1)] : []),
                    "forward Facet wrong count")
            }
            let facts = await evidence.snapshot(), diagnostics = await diagnostic.snapshot()
            try verifySQL(facts, diagnostics, root: "School", loaded: false, logging: logging,
                expectedRoutes: queryRoutes("to-one"))
            guard let firstCarrier = rows.first?.schoolTypeResult,
                  let platforms = firstCarrier.facets["platforms"] else {
                throw TeaQLError.execution("forward Facet metadata missing")
            }
            try emitProof(QueryProof(branch: "to-one", logging: logging, includeAll: includeAll,
                empty: empty, visible: rows.count, platforms: try choices(platforms),
                identities: try rows.map { try E.school($0).schoolTypeId().eval() ?? -1 },
                hiddenDetailFailures: hiddenDetailFailures, sql: facts.map(StatementProof.init),
                diagnostics: diagnostics.count))
            scenarios += 1
        }
        let evidence = SQLExecutionEvidenceStore()
        let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
            requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, querySQLLogEnabled: false)
        let independent = try await Q.schoolTypes().withIdIs(1001).limit(1)
            .comment("independent \(secret)").purpose("verify request isolation").executeForList(context)
        try require(!independent[0].schoolListResult.isLoaded, "unselected relation became loaded empty")
        try require(await evidence.snapshot().last?.comment == "independent \(secret)", "redactions escaped invocation")
        let unselected = try await Q.schools().limit(1).comment("independent forward reference")
            .purpose("verify forward NotLoaded").executeForList(context)
        try require(!unselected[0].schoolTypeResult.isLoaded && unselected[0].schoolTypeEntity == nil,
            "unselected forward carrier became loaded null")
        do {
            _ = try E.schoolType(independent[0]).schoolList().size().eval()
            throw TeaQLError.execution("E hid NotLoaded")
        } catch is TeaQLNotLoadedError {}
    } }
    return scenarios
}
