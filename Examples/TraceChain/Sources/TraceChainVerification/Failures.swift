import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

/// Test-only fault injection. No business reads/writes or handcrafted
/// descriptors: all application operations still use generated Mutation/Q/E.
func installReadbackFault(path: String, id: Int64) throws {
    var handle: OpaquePointer?
    try require(sqlite3_open(path, &handle) == SQLITE_OK, "fault fixture connection failed")
    defer { sqlite3_close(handle) }
    let table = Payment.descriptor.table.replacingOccurrences(of: "\"", with: "\"\"")
    let column = (Payment.descriptor.idProperty?.column ?? "id").replacingOccurrences(of: "\"", with: "\"\"")
    let statement = "CREATE TRIGGER IF NOT EXISTS trace_vanish_\(id) AFTER INSERT ON \"\(table)\" "
        + "WHEN NEW.\"\(column)\"=\(id) BEGIN DELETE FROM \"\(table)\" WHERE \"\(column)\"=NEW.\"\(column)\"; END"
    try require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK, "fault trigger creation failed")
}

func generatedFailureProofs(_ context: UserContext, sql: SQLExecutionEvidenceStore, audit: AuditCapture,
                            path: String, base: Int64) async throws {
    var root = try order(context, id: base + 5_000, label: "TRACE-FAILED-ROOT")
    let duplicate = try payment(context, id: base + 201, parentID: root.id, label: "TRACE-DUPLICATE")
    _ = duplicate.auditAs("authorize failing payment")
    root.paymentList.append(duplicate)
    await sql.enableAll(); await audit.clear()
    do {
        _ = try await root.auditAs("submit failing order").save(context)
        throw TeaQLError.execution("expected SQLite UNIQUE failure")
    } catch let error as SQLiteError {
        guard case .sqlite(let code, _, _) = error else { throw error }
        try require(code == SQLITE_CONSTRAINT, "not an actual SQLite constraint error")
    }
    let failed = await sql.snapshot(), failedAudits = await audit.snapshot()
    try require(failed.count == 3 && failed.map(\.executionOutcome) == ["success", "success", "failure"]
        && failed.map(\.operation) == [.insert, .select, .insert]
        && failedAudits.isEmpty, "failure diagnostics or commit barrier lost")
    let parent = NodeExpectation(type: "CustomerOrder", id: root.id, reason: "submit failing order")
    try checkChain(failed[1].mutationLineage, [parent], boundary: "successful parent readback before failure")
    try checkChain(failed[2].mutationLineage, [parent,
        NodeExpectation(type: "Payment", id: base + 201, reason: "authorize failing payment")], boundary: "failed child SQL")
    let after = try await Q.customerOrders().withIdIs(root.id).limit(1)
        .comment("inspect failed graph rollback").purpose("verify parent did not commit").executeForList(context)
    try require(after.isEmpty, "failed graph left a committed root")
    print("PASS actual generated child UNIQUE failure retains successful root SQL and failed child lineage; no committed audit")

    let rootID = base + 6_000, paymentID = rootID + 1
    try installReadbackFault(path: path, id: paymentID)
    var refreshed = try order(context, id: rootID, label: "TRACE-READBACK")
    let pay = try payment(context, id: paymentID, parentID: rootID, label: "TRACE-READBACK-PAYMENT")
    _ = pay.auditAs("authorize readback payment"); refreshed.paymentList.append(pay)
    await sql.enableAll(); await audit.clear()
    do {
        _ = try await refreshed.auditAs("submit readback order").save(context)
        throw TeaQLError.execution("expected rejected persisted snapshot")
    } catch let error as TeaQLError {
        guard case .execution(let message) = error, message.contains("Persisted state refresh expected one Payment row; found 0")
        else { throw error }
    }
    let readback = await sql.snapshot(), readbackAudits = await audit.snapshot()
    try require(readback.count == 4 && readback.map(\.operation) == [.insert, .select, .insert, .select]
        && readbackAudits.isEmpty, "readback erased write diagnostics or emitted committed audits")
    try require(readback.allSatisfy { $0.executionOutcome == "success" }
        && readback[1].resultCount == 1 && readback[3].resultCount == 0
        && readback[3].resultSummary.contains("persisted snapshot rejected"),
        "readback validation failure was confused with failed SQL execution")
    let readbackParent = NodeExpectation(type: "CustomerOrder", id: rootID, reason: "submit readback order")
    let expected = [readbackParent, NodeExpectation(type: "Payment", id: paymentID, reason: "authorize readback payment")]
    try checkChain(readback[1].mutationLineage, [readbackParent], boundary: "successful root readback")
    try checkChain(readback[2].mutationLineage, expected, boundary: "successful write before readback")
    try checkChain(readback[3].mutationLineage, expected, boundary: "rejected readback")
    try require(readback[3].comment == "submit readback order"
        && readback[3].purpose == "verify the persisted mutation result"
        && readback[3].tracePath.map(\.kind) == ["operation", "request", "provider", "sql"]
        && readback[3].tracePath.filter { $0.kind == "sql" }.map(\.name) == ["select"], "readback intent or physical leaf differs")
    let rolledBack = try await Q.customerOrders().withIdIs(rootID).limit(1)
        .comment("inspect readback rollback").purpose("verify successful statements did not imply commit").executeForList(context)
    try require(rolledBack.isEmpty, "readback failure left a committed parent")
    print("PASS actual SQLite-triggered readback rejection: two writes, one successful readback + separate zero-row SELECT; graph rolls back")
}
