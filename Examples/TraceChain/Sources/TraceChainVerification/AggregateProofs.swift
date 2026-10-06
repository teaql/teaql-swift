import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

/// Observe actual native-provider returns through the existing telemetry SPI.
/// No executor wrapper, replacement rows, synthetic SQL or trace frames.
private final class AggregatePhysicalCapture: RuntimeTelemetry, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SQLExecutionMetadata] = []
    func clear() { lock.withLock { entries.removeAll() } }
    func snapshot() -> [SQLExecutionMetadata] { lock.withLock { entries } }
    func withOperation<Result: Sendable>(_ operation: RuntimeOperation,
        completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
        _ body: () async throws -> Result) async rethrows -> Result {
        let result = try await body()
        if operation.family == "provider", let query = result as? QueryResult, let metadata = query.metadata {
            lock.withLock { entries.append(metadata) }
        }
        return result
    }
    func withSynchronousOperation<Result>(_ operation: RuntimeOperation,
        completion: (Result) -> [String: RuntimeTelemetryValue],
        _ body: () throws -> Result) rethrows -> Result { try body() }
    func flush() async {}
    func shutdown() async {}
}

private struct AggregateStatement: Encodable {
    let sql: String, debugSQL: String
    let parameters: [TeaQLValue], path: [TraceNode]
    let comment: String?, purpose: String?, outcome: String?
    let resultCount: Int?
    init(_ metadata: SQLExecutionMetadata) {
        sql = metadata.parameterizedSQL; debugSQL = metadata.debugSQL
        parameters = metadata.parameters; path = metadata.tracePath
        comment = metadata.comment; purpose = metadata.purpose
        outcome = metadata.executionOutcome; resultCount = metadata.resultCount
    }
}

private struct AggregateObservation: Encodable {
    let logging: Bool, nested: Bool, filtered: Bool
    let rootID: Int64, itemIDs: [Int64], eligible: Int64, empty: Int64
    let physical: [AggregateStatement], safe: [AggregateStatement]
}

func generatedAggregateProofs(runtime: TeaQLRuntime, service: SQLiteDataService, base: Int64) async throws {
    let physical = AggregatePhysicalCapture(), sql = SQLExecutionEvidenceStore(), audit = AuditCapture()
    let text = TextDiagnosticSQLLogSink(writer: { _ in })
    let commands = CommandCapture(service: service, audit: audit)
    var context = UserContext(runtime: runtime, actor: "aggregate-conformance", queryExecutor: service,
        mutationExecutor: commands, requestPolicy: RequestPolicy { $0 }, auditSink: audit,
        telemetrySink: sql, diagnosticSQLLogSink: text, runtimeTelemetry: physical)
    let rootID = base + 80_000, itemID = rootID + 101, otherItemID = rootID + 102
    let payID = rootID + 201, attemptID = rootID + 301
    let secret = "AGGREGATE-PRIVATE-\(rootID)"
    var root = try order(context, id: rootID, label: "AGGREGATE-\(rootID)")
    for (id, name) in [(itemID, secret), (otherItemID, "Other aggregate item")] {
        var item = try Q.orderItems().comment("initialize aggregate item")
            .purpose("compose actual membership fixture").newEntity(context)
        item.updateId(id); item.updateCustomerOrder(rootID); item.updateName(name)
        root.orderItemList.append(item)
    }
    var pay = try payment(context, id: payID, parentID: rootID, label: "AGGREGATE-PAYMENT")
    var attempt = try Q.paymentAttempts().comment("initialize aggregate attempt")
        .purpose("compose nested membership fixture").newEntity(context)
    attempt.updateId(attemptID); attempt.updatePayment(payID); attempt.updateReferenceCode("AGGREGATE-ATTEMPT")
    pay.paymentAttemptList.append(attempt); root.paymentList.append(pay)
    _ = try await root.auditAs("seed aggregate membership graph").save(context)
    let seedAudit = await audit.snapshot()
    try require(seedAudit.count == 5, "aggregate graph must produce five committed audits")

    for logging in [false, true] {
      for nested in [false, true] {
        for filtered in [false, true] {
            context.querySQLLogEnabled = logging; context.mutationSQLLogEnabled = logging
            let textBefore = await text.snapshot().count
            physical.clear(); await sql.enableAll(); await audit.clear(); await commands.clear()
            let forward = Q.customerOrders().withIdIs(filtered ? 0 : rootID).limit(1)
            let children = Q.orderItems().orderByIdAscending().limit(10).selectCustomerOrderWith(forward)
            let request = Q.customerOrders().withIdIs(rootID).limit(1)
                .countOrderItemsWith("eligibleItems", Q.orderItems().withNameIs(secret))
                .countOrderItemsWith("emptyItems", Q.orderItems().withIdIs(0))
                .selectOrderItemListWith(children)
            let comment = "load aggregate graph \(secret)", purpose = "verify membership and safe intent \(secret)"
            let loaded: CustomerOrder
            if nested {
                let rows = try await Q.paymentAttempts().withIdIs(attemptID).limit(1)
                    .selectPaymentWith(Q.payments().limit(1).selectCustomerOrderWith(request))
                    .comment(comment).purpose(purpose).executeForList(context)
                guard let row = rows.first, let pay = try E.paymentAttempt(row).payment().eval(),
                      let order = try E.payment(pay).customerOrder().eval()
                else { throw TeaQLError.execution("nested aggregate owner missing") }
                loaded = order
            } else {
                guard let order = try await request.comment(comment).purpose(purpose).executeForList(context).first
                else { throw TeaQLError.execution("aggregate owner missing") }
                loaded = order
            }
            try require(loaded.id == rootID && loaded.hasQueryProjection("eligibleItems")
                && loaded.hasQueryProjection("emptyItems"), "generated hydration dropped aggregate aliases")
            guard let eligible = try loaded.queryProjection("eligibleItems").int64Value,
                  let empty = try loaded.queryProjection("emptyItems").int64Value
            else { throw TeaQLError.execution("aggregate result was not numeric") }
            try require(eligible == 1 && empty == 0, "filtered count or empty count differs")
            try require(try E.customerOrder(loaded).orderItemList().size().eval() == 2
                && loaded.orderItemList.map(\.id) == [itemID, otherItemID], "aggregate narrowed selected membership")
            for item in loaded.orderItemList {
                try require(try E.orderItem(item).customerOrderId().eval() == rootID, "forward load replaced scalar FK")
                guard let target = try E.orderItem(item).customerOrder().eval()
                else { throw TeaQLError.execution("forward identity was removed") }
                try require(target.id == rootID, "forward identity differs")
                if filtered {
                    do {
                        _ = try E.customerOrder(target).description().eval()
                        throw TeaQLError.execution("filtered detail was falsely loaded")
                    } catch is TeaQLNotLoadedError {}
                } else {
                    try require(try E.customerOrder(target).description().eval() == "Draft order", "full forward detail missing")
                }
            }
            try require(!loaded.hasQueryProjection("missingAlias") && !loaded.hasQueryProjection("id")
                && !loaded.hasQueryProjection("orderItemList"), "modeled fields leaked into alias snapshot")
            do {
                _ = try loaded.queryProjection("missingAlias")
                throw TeaQLError.execution("missing alias silently became zero")
            } catch let error as QueryProjectionNotLoaded { try require(error.alias == "missingAlias", "wrong missing alias") }
            try require(loaded.toMutationRecord()["eligibleItems"] == nil
                && loaded.toRecord()["eligibleItems"] == nil && !loaded.teaqlEntityRoot.hasPending(loaded.teaqlEntityKey),
                "query projections leaked into persistence or mutation ownership")
            let encoded = String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self)
            try require(!encoded.contains("eligibleItems") && !encoded.contains("emptyItems"), "aliases leaked into modeled JSON")
            let raw = physical.snapshot(), safe = await sql.snapshot()
            let observedRoutes = raw.map { $0.tracePath.filter { $0.kind == "relation" }.map(\.name) }
            try require(raw.count == (nested ? 8 : 6) && safe.count == raw.count,
                "physical aggregate statement count differs: raw=\(raw.count) safe=\(safe.count) nested=\(nested); routes=\(observedRoutes)")
            let prefix = nested ? ["payment", "customerOrder"] : []
            // SQLite's existing probe policy loads the forward edge once per child.
            let suffixes = [[], ["orderItemList"], ["orderItemList"], ["orderItemList"],
                ["orderItemList", "customerOrder"], ["orderItemList", "customerOrder"]]
            let expected = nested ? [[], ["payment"]] + suffixes.map { prefix + $0 } : suffixes
            for (index, pair) in zip(raw, safe).enumerated() {
                let (actual, redacted) = pair
                try require(actual.parameterizedSQL == redacted.parameterizedSQL
                    && actual.parameters.count == redacted.parameters.count && actual.tracePath == redacted.tracePath
                    && actual.resultCount == redacted.resultCount, "safe evidence does not match native provider SQL")
                try require(actual.comment == comment && actual.purpose == purpose
                    && redacted.comment?.contains(secret) == false && redacted.purpose?.contains(secret) == false
                    && !redacted.debugSQL.contains(secret) && !redacted.parameters.contains(.string(secret)),
                    "private aggregate operand escaped safe intent/SQL projection")
                try require(actual.executionOutcome == "success" && actual.tracePath.first?.name == (nested ? "PaymentAttempt" : "CustomerOrder")
                    && actual.tracePath.filter { $0.kind == "relation" }.map(\.name) == expected[index]
                    && actual.tracePath.map(\.kind) == ["operation", "request"]
                        + Array(repeating: "relation", count: expected[index].count) + ["provider", "sql"]
                    && actual.tracePath.last?.name == "select", "incomplete aggregate physical route")
            }
            try require(raw.contains { $0.parameters.contains(.string(secret)) }, "masked aggregate test did not bind its real secret")
            let lines = await text.snapshot()
            try require(lines.count - textBefore == (logging ? raw.count : 0)
                && lines.dropFirst(textBefore).allSatisfy { !$0.contains(secret) }, "logging switch or masking differs")
            let readCommands = await commands.snapshot(), readAudit = await audit.snapshot()
            try require(readCommands.isEmpty && readAudit.isEmpty, "read-only aggregate mutated data")
            let observation = AggregateObservation(logging: logging, nested: nested, filtered: filtered,
                rootID: rootID, itemIDs: loaded.orderItemList.map(\.id), eligible: eligible, empty: empty,
                physical: raw.map(AggregateStatement.init), safe: safe.map(AggregateStatement.init))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print("AGGREGATE_OBSERVED " + String(decoding: try encoder.encode(observation), as: UTF8.self))
            let full = try await loadOrder(context, id: rootID)
            try require(try E.customerOrder(full).description().eval() == "Draft order", "independent full read failed")
            if filtered {
                guard let identity = try E.orderItem(loaded.orderItemList[0]).customerOrder().eval()
                else { throw TeaQLError.execution("filtered identity disappeared") }
                do {
                    _ = try E.customerOrder(identity).description().eval()
                    throw TeaQLError.execution("independent query widened old filtered view")
                } catch is TeaQLNotLoadedError {}
            }
            print("PASS Swift generated aggregate membership: logging=\(logging) nested=\(nested) filtered=\(filtered)")
        }
      }
    }
}
