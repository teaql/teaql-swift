import Foundation
import CSQLite
import TeaQLCore
import TeaQLSQLite

/// Runtime-owned fixture, deliberately separate from generated application code.
func verifyFieldAwareSQLMasking() async throws {
    let entity = EntityDescriptor(name: "MaskingCustomer", table: "masking_customer", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true),
        PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "displayName", modelName: "display_name", column: "legal_name", type: .string),
        PropertyDescriptor(name: "address", type: .string),
        PropertyDescriptor(name: "password", type: .string),
    ], auditMaskFields: ["display_name"])
    let service = try SQLiteDataService(path: ":memory:")
    let evidence = SQLExecutionEvidenceStore()
    let sink = TextDiagnosticSQLLogSink(writer: { _ in })
    var context = UserContext(queryExecutor: service, mutationExecutor: service,
        requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
    try await context.ensureSchema(RuntimeModule(name: "masking-fixture", entities: [entity]))
    _ = try await context.execute(Mutation(kind: .create, entity: entity, values: [
        "id": .int(1), "displayName": .string("Riverside"), "address": .string("1 Runtime Road"),
        "password": .string("PASSWORD-CANARY")
    ], auditReason: "what: create masking fixture"))
    let beforeFailure = await evidence.snapshot().count
    do {
        _ = try await context.execute(Mutation(kind: .create, entity: entity, values: [
            "id": .int(1), "displayName": .string("Riverside"), "address": .string("1 Runtime Road"),
            "password": .string("PASSWORD-CANARY")
        ], auditReason: "what: verify duplicate key diagnostics"))
        try require(false, "duplicate primary key unexpectedly succeeded")
    } catch let error as SQLiteError {
        guard case .sqlite(let code, _, _) = error, code == 19 else { throw error }
    }
    let failureEntries = await evidence.snapshot()
    try require(failureEntries.count == beforeFailure + 1, "failed SQL did not produce exactly one diagnostic")
    try require(failureEntries.last?.executionOutcome == "failure" && failureEntries.last?.affectedRows == nil,
        "failure outcome or unknown row count lost")
    var query = SelectQuery(entity: entity)
    query.filter = .equal("displayName", .string("Riverside")); query.limit = 1
    query.comment = "what: find Riverside"; query.purpose = "why: verify safe projection"
    let result = try await context.execute(query)
    try require(result.records.first?["displayName"] == .string("Riverside"), "mask changed database name")
    try require(result.records.first?["password"] == .string("PASSWORD-CANARY"), "mask changed database password")
    _ = try await context.execute(Mutation(kind: .update, entity: entity, id: .int(1),
        values: ["displayName": .string("Lakeside")], expectedVersion: 1, auditReason: "what: update masking fixture"))
    query.filter = .equal("id", .int(1))
    // Intent describes the current operation, not a previous request's private value.
    query.comment = "what: reload updated fixture by ID"
    let updated = try await context.execute(query)
    try require(updated.records.first?["displayName"] == .string("Lakeside"), "update changed by logging")
    _ = try await context.execute(Mutation(kind: .delete, entity: entity, id: .int(1), expectedVersion: 2,
        auditReason: "what: delete masking fixture"))
    let entries = await evidence.snapshot()
    try require(Set(entries.map(\.operation)).count == 4, "missing CRUD logging evidence")
    try require(entries.allSatisfy { $0.sqlOmissionReason == nil }, "normal SQL was omitted")
    let logs = await sink.snapshot().joined(separator: "\n")
    try require(logs.contains("Ri*****de") && logs.contains("La****de"), "field mask was not applied")
    try require(logs.contains("1 Runtime Road"), "ordinary field was hidden")
    try require(!logs.contains("Riverside") && !logs.contains("Lakeside") && !logs.contains("PASSWORD-CANARY"), "plaintext leak")
    try require(logs.contains("masked") && logs.contains("NOT REPLAYABLE") && logs.contains("parameterCount="), "missing diagnostic context")
    let previousCount = await sink.snapshot().count
    context.querySQLLogEnabled = false
    _ = try await context.execute(query)
    try require(await sink.snapshot().count == previousCount, "query log switch ignored")
    print("PASS field-aware expanded SQL masking (SQLite CRUD, ordinary fields, credentials, query switch)")
    try await verifyReadbackFailureMasking(entity: entity)
    try await verifyRelationFailureMasking(entity: entity)
}

private func verifyRelationFailureMasking(entity: EntityDescriptor) async throws {
    let directory = FileManager.default.temporaryDirectory
    let path = directory.appendingPathComponent("teaql-relation-example-\(UUID()).sqlite").path
    let logFile = directory.appendingPathComponent("teaql-relation-example-\(UUID()).log")
    let child = EntityDescriptor(name: "MaskChild", table: "mask_child", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true),
        PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "parent", type: .int),
    ])
    let service = try SQLiteDataService(path: path)
    let evidence = SQLExecutionEvidenceStore()
    let sink = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
        requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
    try await context.ensureSchema(RuntimeModule(name: "relation-fixture", entities: [entity, child]))
    _ = try await context.execute(Mutation(kind: .create, entity: entity, values: [
        "id": .int(1), "displayName": .string("Riverside"), "address": .string("1 Runtime Road"),
        "password": .string("PASSWORD-CANARY")
    ], auditReason: "what: seed relation parent"))
    _ = try await context.execute(Mutation(kind: .create, entity: child, values: [
        "id": .int(1), "parent": .int(1)
    ], auditReason: "what: seed relation child"))
    await evidence.enableAll()
    var query = SelectQuery(entity: entity)
    query.filter = .and([.equal("displayName", .string("Riverside")), .equal("password", .string("PASSWORD-CANARY"))])
    query.limit = 1; query.comment = "what: load Riverside PASSWORD-CANARY graph"
    query.purpose = "why: verify inherited intent"
    var childQuery = SelectQuery(entity: child)
    childQuery.projection = ["id"]; childQuery.limit = 2
    query.relationQuery("children", localKey: "id", foreignKey: "parent", query: childQuery)
    var db: OpaquePointer?
    try require(sqlite3_open(path, &db) == SQLITE_OK, "fixture database open failed")
    defer { sqlite3_close(db) }
    try require(sqlite3_exec(db, "ALTER TABLE mask_child RENAME TO unavailable", nil, nil, nil) == SQLITE_OK, "fixture rename failed")
    do {
        defer { precondition(sqlite3_exec(db, "ALTER TABLE unavailable RENAME TO mask_child", nil, nil, nil) == SQLITE_OK) }
        do {
            _ = try await context.execute(query)
            throw TeaQLError.execution("missing relation table unexpectedly succeeded")
        } catch let error as SQLiteError {
            guard case .sqlite(let code, _, _) = error, code == 1 else { throw error }
        }
    }
    let entries = await evidence.snapshot()
    try require(entries.count == 2 && entries.map(\.executionOutcome) == ["success", "failure"], "relation outcomes missing")
    try require(entries.last?.comment?.contains("what: load") == true, "relation intent lost")
    let text = await sink.snapshot().joined(separator: "\n")
    try text.write(to: logFile, atomically: true, encoding: .utf8)
    let disk = try String(contentsOf: logFile, encoding: .utf8)
    try require(!disk.contains("Riverside") && !disk.contains("PASSWORD-CANARY") && disk.contains("mask_child"), "relation log unsafe or SQL lost")
    try require(!entries.description.contains("Riverside") && !entries.description.contains("PASSWORD-CANARY"), "relation evidence unsafe")
    let restored = try await context.execute(query)
    guard case .array(let children) = restored.records.first?["children"], case .object(let row) = children.first else {
        throw TeaQLError.execution("restored relation graph missing")
    }
    try require(children.count == 1 && row["id"] == .int(1), "restored child graph changed")
    print("PASS relation masking: inherited intent, SQLite failure, safe evidence/file log and restored graph")
}

private func verifyReadbackFailureMasking(entity: EntityDescriptor) async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-mask-example-\(UUID()).sqlite").path
    let service = try SQLiteDataService(path: path)
    let evidence = SQLExecutionEvidenceStore()
    let sink = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: service, mutationExecutor: service,
        requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
    try await context.ensureSchema(RuntimeModule(name: "readback-fixture", entities: [entity]))
    // Test fault injection only; business data is still written by mutation API.
    var db: OpaquePointer?
    try require(sqlite3_open(path, &db) == SQLITE_OK, "fixture database open failed")
    defer { sqlite3_close(db) }
    try require(sqlite3_exec(db, "CREATE TRIGGER vanish AFTER INSERT ON masking_customer WHEN NEW.id=777 BEGIN DELETE FROM masking_customer WHERE id=NEW.id; END", nil, nil, nil) == SQLITE_OK,
        "fixture trigger creation failed")
    func mutation(_ id: Int64) -> Mutation {
        Mutation(kind: .create, entity: entity, values: ["id": .int(id), "displayName": .string("Riverside"),
            "address": .string("1 Runtime Road"), "password": .string("PASSWORD-CANARY")],
            auditReason: "what: persist Riverside PASSWORD-CANARY")
    }
    do {
        _ = try await context.execute(mutation(777))
        throw TeaQLError.execution("expected readback rejection")
    } catch let error as TeaQLError {
        guard case .execution(let message) = error, message.contains("Persisted state refresh") else { throw error }
    }
    let first = await evidence.snapshot()
    try require(first.count == 2 && first[0].affectedRows == 1 && first[1].resultCount == 0,
        "write/readback diagnostics missing")
    try require(first.allSatisfy { $0.executionOutcome == "success" }, "snapshot rejection mislabeled as SQL failure")
    await evidence.enableAll()
    try await service.beginGraphTransaction()
    do {
        for id: Int64 in [30, 777, 31] { _ = try await context.execute(mutation(id)) }
        throw TeaQLError.execution("expected partial graph failure")
    } catch let error as TeaQLError {
        try await service.rollbackGraphTransaction()
        guard case .execution(let message) = error, message.contains("Persisted state refresh") else { throw error }
    }
    let partial = await evidence.snapshot()
    try require(partial.count == 3, "partial graph must retain two writes and one rejected readback")
    try require(partial.map(\.operation) == [.insert, .insert, .select], "partial graph order changed")
    let text = await sink.snapshot().joined(separator: "\n")
    try require(!text.contains("Riverside") && !text.contains("PASSWORD-CANARY"), "inherited intent leaked")
    try require(text.contains("Ri*****de") && text.contains("1 Runtime Road"), "normal SQL masked wholesale")
    var query = SelectQuery(entity: entity)
    query.limit = 10; query.comment = "what: inspect rollback"; query.purpose = "why: verify graph atomicity"
    try require(try await context.execute(query).records.isEmpty, "partial graph did not roll back")
    try require(try await service.auditEvents().isEmpty, "audit rows survived rollback")
    _ = try await context.execute(mutation(32))
    print("PASS readback and partial graph diagnostics (inherited intent masked, rollback, connection reuse)")
}
