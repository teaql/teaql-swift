import CSQLite
import Foundation
import TeaQLCore
import TeaQLSQLite
import Testing

@Suite("Checked version lifecycle SQLite")
struct VersionLifecycleSQLiteTests {
  private let entity = EntityDescriptor(name: "VersionProbe", table: "version_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])

  @Test func largestLiveUpdateStaysAnInteger() async throws {
    try await withFixture(version: Int64.max - 1) { service, path in
      let saved = try await service.execute(Mutation(kind: .update, entity: entity, id: .int(1),
        values: ["name": .string("updated")], expectedVersion: Int64.max - 1, auditReason: "reach the last live version"))
      #expect(saved.persistedRecord?["version"] == .int(.max))
      let persisted = try storedVersion(path)
      #expect(persisted == Int64.max)
      #expect(saved.metadata?.parameterizedSQL.contains("+ 1") == false)
    }
  }

  @Test func exhaustedUpdateDoesNotWriteOrAudit() async throws {
    try await withFixture(version: .max) { service, path in
      do {
        _ = try await service.execute(Mutation(kind: .update, entity: entity, id: .int(1),
          values: ["name": .string("must-not-persist")], expectedVersion: .max, auditReason: "reject exhaustion"))
        Issue.record("exhausted update persisted")
      } catch { #expect(String(describing: error).contains("VERSION_EXHAUSTED")) }
      let persisted = try storedVersion(path), audit = try await service.auditEvents()
      #expect(persisted == Int64.max)
      #expect(audit.isEmpty)
    }
  }

  @Test func negativeUpdateAndRepeatedDeleteAreRejected() async throws {
    for kind in [MutationKind.update, .delete] {
      try await withFixture(version: -2) { service, path in
        do {
          _ = try await service.execute(Mutation(kind: kind, entity: entity, id: .int(1),
            values: ["name": .string("must-not-persist")], expectedVersion: -2, auditReason: "keep the tombstone"))
          Issue.record("tombstone accepted a live mutation")
        } catch { #expect(String(describing: error).contains("INVALID_VERSION_STATE")) }
        let persisted = try storedVersion(path), audit = try await service.auditEvents()
        #expect(persisted == -2)
        #expect(audit.isEmpty)
      }
    }
  }

  @Test func recoveryUsesTheExactCheckedVersionAndKeepsReadbackAndAudit() async throws {
    for (old, next) in [(Int64(-2), Int64(3)), (Int64.min + 2, Int64.max)] {
      try await withFixture(version: old) { service, path in
        let saved = try await service.execute(Mutation(kind: .recover, entity: entity, id: .int(1),
          expectedVersion: old, auditReason: "recover the exact tombstone"))
        #expect(saved.affectedRows == 1)
        #expect(saved.persistedRecord?["version"] == .int(next))
        #expect(saved.generatedValues["version"] == .int(next))
        let persisted = try storedVersion(path), audit = try await service.auditEvents()
        #expect(persisted == next)
        #expect(saved.metadata?.operation == .recover)
        #expect(saved.metadata?.statements.count == 2)
        #expect(audit.map { $0["operation"] } == [.string("recover")])
      }
    }
  }

  @Test func exhaustedTombstonesCannotRecover() async throws {
    for old in [Int64.min, Int64.min + 1] {
      try await withFixture(version: old) { service, path in
        do {
          _ = try await service.execute(Mutation(kind: .recover, entity: entity, id: .int(1),
            expectedVersion: old, auditReason: "retain exhausted tombstones"))
          Issue.record("exhausted tombstone recovered")
        } catch { #expect(String(describing: error).contains("VERSION_EXHAUSTED")) }
        let persisted = try storedVersion(path), audit = try await service.auditEvents()
        #expect(persisted == old)
        #expect(audit.isEmpty)
      }
    }
  }

  @Test func maximumLiveDeletionProducesMinimumTombstoneWithoutTrapping() async throws {
    try await withFixture(version: .max) { service, path in
      let saved = try await service.execute(Mutation(kind: .delete, entity: entity, id: .int(1),
        expectedVersion: .max, auditReason: "delete the final live version without overflow"))
      let persisted = try storedVersion(path), audit = try await service.auditEvents()
      #expect(persisted == Int64.min)
      #expect(saved.persistedRecord?["version"] == .int(.min))
      #expect(saved.generatedValues["version"] == .int(.min))
      #expect(audit.map { $0["operation"] } == [.string("delete")])
    }
  }

  @Test func staleRecoveryIsRejectedAndTheCorrectRetryWorks() async throws {
    try await withFixture(version: -2) { service, path in
      do {
        _ = try await service.execute(Mutation(kind: .recover, entity: entity, id: .int(1),
          expectedVersion: -3, auditReason: "reject a stale tombstone"))
        Issue.record("stale recovery persisted")
      } catch let error as TeaQLError {
        #expect(error == .optimisticLock(entity: entity.name, id: .int(1), expectedVersion: -3))
      }
      let before = try storedVersion(path), auditBefore = try await service.auditEvents()
      #expect(before == -2 && auditBefore.isEmpty)
      _ = try await service.execute(Mutation(kind: .recover, entity: entity, id: .int(1),
        expectedVersion: -2, auditReason: "retry with the exact tombstone"))
      let after = try storedVersion(path), auditAfter = try await service.auditEvents()
      #expect(after == 3 && auditAfter.count == 1)
    }
  }

  @Test func explicitIntentConstructorCannotBypassProviderAdmission() async throws {
    try await withFixture(version: .max) { service, path in
      let request = MutationRequest(mutation: Mutation(kind: .update, entity: entity, id: .int(1),
        values: ["name": .string("must-not-persist")], expectedVersion: .max),
        intent: try MutationIntent(comment: "revalidate at the provider boundary"))
      do { _ = try await service.execute(request); Issue.record("nonthrowing constructor bypassed admission") }
      catch let error as MutationVersionError { #expect(error.code == .exhausted) }
      let persisted = try storedVersion(path), audit = try await service.auditEvents()
      #expect(persisted == Int64.max && audit.isEmpty)
    }
  }

  @Test func failedRecoveringBatchRollsBackAndCanRetryWithoutLosingTheTombstone() async throws {
    try await withFixture(version: -2) { service, path in
      let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
      let recovery = Mutation(kind: .recover, entity: entity, id: .int(1), expectedVersion: -2,
        auditReason: "recover the first item")
      let stale = Mutation(kind: .update, entity: entity, id: .int(99), values: ["name": .string("absent")],
        expectedVersion: 1, auditReason: "force a later optimistic failure")
      do {
        _ = try await context.execute(MutationBatchRequest(mutations: [recovery, stale], comment: "rollback a recovered sibling"))
        Issue.record("failed graph committed")
      } catch let error as TeaQLError {
        #expect(error == .optimisticLock(entity: entity.name, id: .int(99), expectedVersion: 1))
      }
      let before = try storedVersion(path), auditBefore = try await service.auditEvents()
      #expect(before == -2 && auditBefore.isEmpty)
      _ = try await context.execute(MutationBatchRequest(mutations: [recovery], comment: "retry the same recovered item"))
      let after = try storedVersion(path), auditAfter = try await service.auditEvents()
      #expect(after == 3 && auditAfter.count == 1)
    }
  }

  // Direct SQLite is restricted to boundary injection and the independent
  // storage oracle. Business writes still exercise the actual provider API.
  private func withFixture(version: Int64,
    _ body: (SQLiteDataService, String) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-version-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("probe.sqlite").path
    let service = try SQLiteDataService(path: path)
    let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
    try await context.ensureSchema(RuntimeModule(name: "version fixture", entities: [entity]))
    var raw: OpaquePointer?
    guard sqlite3_open(path, &raw) == SQLITE_OK else { throw TeaQLError.execution("version fixture open") }
    defer { sqlite3_close(raw) }
    guard sqlite3_exec(raw, "INSERT INTO version_probe(id,version,name) VALUES(1,\(version),'original')", nil, nil, nil) == SQLITE_OK
    else { throw TeaQLError.execution("version fixture injection") }
    try await body(service, path)
  }

  private func storedVersion(_ path: String) throws -> Int64 {
    var raw: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw TeaQLError.execution("version oracle open") }
    defer { sqlite3_close(raw) }
    guard sqlite3_prepare_v2(raw, "SELECT version,typeof(version) FROM version_probe WHERE id=1", -1, &statement, nil) == SQLITE_OK
    else { throw TeaQLError.execution("version oracle prepare") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw TeaQLError.execution("version oracle missing row") }
    #expect(sqlite3_column_type(statement, 0) == SQLITE_INTEGER)
    #expect(String(cString: sqlite3_column_text(statement, 1)) == "integer")
    return sqlite3_column_int64(statement, 0)
  }
}
