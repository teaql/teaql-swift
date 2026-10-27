import CSQLite
import Foundation
import Testing
@testable import TeaQLCore
import TeaQLSQLite

@Suite("Mutation lifecycle with real SQLite")
struct MutationLifecycleSQLiteTests {
  @Test(arguments: ["edit-write", "cancel-write", "edit-beforecommit", "cancel-beforecommit", "edit-commit", "cancel-commit"])
  func aPausedSavePreservesTruthAndTheCallersIntention(_ route: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-lifecycle-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("probe.sqlite").path
    let service = try SQLiteDataService(path: path)
    let bootstrap = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
      diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }), runtimeTelemetry: NoopRuntimeTelemetry())
    try await bootstrap.ensureSchema(RuntimeModule(name: "lifecycle", entities: [SQLiteLifecycleEntity.descriptor]))
    _ = try await bootstrap.execute(Mutation(kind: .create, entity: SQLiteLifecycleEntity.descriptor,
      values: ["id": .int(1), "name": .string("original")], auditReason: "seed the lifecycle fixture"))
    let initialAuditCount = try await service.auditEvents().count
    let pause = SQLiteLifecyclePause(), audit = SQLiteLifecycleAudit(), sql = SQLExecutionEvidenceStore()
    let provider = PausedSQLiteProvider(service: service, pause: pause,
      phase: route.hasSuffix("-write") ? .write : route.hasSuffix("-commit") ? .commit : .none)
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      auditSink: audit, telemetrySink: sql, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }),
      runtimeTelemetry: NoopRuntimeTelemetry())
    let entity = try SQLiteLifecycleEntity(record: ["id": .int(1), "version": .int(1), "name": .string("original")])
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("submitted"))
    let beforeCommit = route.hasSuffix("-beforecommit"), edit = route.hasPrefix("edit-")
    let saving = Task {
      let audited = AuditedEntity(entity: entity, reason: "exercise the actual SQLite transaction")
      if beforeCommit {
        return try await context.executeGraphSave(comment: audited.reason, rootEntityType: SQLiteLifecycleEntity.descriptor.name,
          preparing: { context, _ in try audited.preflight(context) }) { context, session in
            let saved = try await audited.saveInGraph(context, session: session, scope: session.scope(key: entity.teaqlEntityKey))
            await pause.checkpoint()
            return saved
          }
      }
      return try await audited.save(context)
    }
    await pause.waitUntilArrived()
    if edit { entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("newer")) }
    else { saving.cancel() }
    await pause.release()
    let didCommit = route.hasSuffix("-commit")
    do {
      let saved = try await saving.value
      #expect(didCommit && !edit && saved.version == 2)
    } catch let error as GraphCommittedError {
      #expect(didCommit && edit && error.committed && error.causes.count == 1)
      let cause = try #require(error.causes.first as? EntityCommitStateConflict)
      #expect(cause.committedVersion == 2 && cause.persistedKey == entity.teaqlEntityKey)
    } catch is CancellationError { #expect(!didCommit && !edit) }
    catch let error as MutationPolicyError { #expect(!didCommit && edit && error == .operationOutsideReviewedPlan) }

    // Independent read-only connection: no fake provider state or hydration can
    // turn an uncommitted write into this oracle's persisted result.
    let persisted = try storedRow(path)
    #expect(persisted.name == (didCommit ? "submitted" : "original"))
    #expect(persisted.version == (didCommit ? 2 : 1))
    #expect(await provider.commits == (didCommit ? 1 : 0))
    #expect(await provider.rollbacks == (didCommit ? 0 : 1))
    #expect(await audit.count == (didCommit ? 1 : 0))
    #expect(try await service.auditEvents().count == initialAuditCount + (didCommit ? 1 : 0))
    let statements = await sql.snapshot()
    #expect(statements.contains { $0.operation == .update && $0.executionOutcome == "success" })
    #expect(statements.contains { $0.operation == .select && $0.executionOutcome == "success" })
    if edit || !didCommit {
      #expect(entity.teaqlEntityRoot.change(entity.teaqlEntityKey)["name"] == .string(edit ? "newer" : "submitted"))
      #expect(entity.teaqlEntityRoot.originalVersion(entity.teaqlEntityKey) == 1)
    } else {
      #expect(!entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
      #expect(entity.teaqlEntityRoot.originalVersion(entity.teaqlEntityKey) == 2)
    }
    if !didCommit {
      let saved = try await AuditedEntity(entity: entity, reason: "retry only after confirmed rollback").save(context)
      #expect(saved.version == 2 && saved.name == (edit ? "newer" : "submitted"))
      #expect(try storedRow(path).name == saved.name)
      #expect(await provider.commits == 1)
      #expect(await provider.rollbacks == 1)
      #expect(await audit.count == 1)
      #expect(try await service.auditEvents().count == initialAuditCount + 1)
    }
  }

  private func storedRow(_ path: String) throws -> (name: String, version: Int64) {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw TeaQLError.execution("lifecycle oracle open") }
    defer { sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, "SELECT name,version FROM lifecycle_probe WHERE id=1", -1, &statement, nil) == SQLITE_OK
    else { throw TeaQLError.execution("lifecycle oracle prepare") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw TeaQLError.execution("lifecycle oracle missing row") }
    #expect(sqlite3_column_type(statement, 1) == SQLITE_INTEGER)
    return (String(cString: sqlite3_column_text(statement, 0)), sqlite3_column_int64(statement, 1))
  }
}

private actor SQLiteLifecyclePause {
  private var arrived = false, released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var resume: CheckedContinuation<Void, Never>?
  func checkpoint() async {
    arrived = true; let ready = waiters; waiters = []; for waiter in ready { waiter.resume() }
    if !released { await withCheckedContinuation { resume = $0 } }
  }
  func waitUntilArrived() async { if !arrived { await withCheckedContinuation { waiters.append($0) } } }
  func release() { released = true; resume?.resume(); resume = nil }
}

private actor SQLiteLifecycleAudit: AuditSink {
  private(set) var count = 0
  func record(_ event: AuditEvent) { count += 1 }
}

private actor PausedSQLiteProvider: QueryExecutor, GraphTransactionExecutor {
  enum Phase: Sendable { case none, write, commit }
  let service: SQLiteDataService, pause: SQLiteLifecyclePause, phase: Phase
  private var writes = 0
  private(set) var commits = 0, rollbacks = 0
  init(service: SQLiteDataService, pause: SQLiteLifecyclePause, phase: Phase) {
    self.service = service; self.pause = pause; self.phase = phase
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult { try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    let result = try await service.execute(request); writes += 1
    if phase == .write && writes == 1 { await pause.checkpoint() }
    return result
  }
  func beginGraphTransaction() async throws { try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws {
    if phase == .commit && commits == 0 { await pause.checkpoint() }
    try await service.commitGraphTransaction(); commits += 1
  }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction(); rollbacks += 1 }
}

private struct SQLiteLifecycleEntity: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "SQLiteLifecycleProbe", table: "lifecycle_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  var id: Int64, version: Int64
  let name: String
  let teaqlEntityRoot: EntityRoot, teaqlLoadedSnapshot: LoadedEntitySnapshot?
  var teaqlEntityKey: EntityKey { EntityKey(entity: Self.descriptor.name, id: .int(id)) }
  init(record: TeaQLRecord) throws {
    id = try #require(record["id"]?.int64Value); version = try #require(record["version"]?.int64Value)
    name = try #require(record["name"]?.stringValue); teaqlEntityRoot = EntityRoot()
    let key = EntityKey(entity: Self.descriptor.name, id: .int(id))
    try teaqlEntityRoot.setOriginalVersion(key, version: version)
    teaqlLoadedSnapshot = LoadedEntitySnapshots().capture(key: key, version: version, record: record)
  }
  func toRecord() -> TeaQLRecord { ["id": .int(id), "version": .int(version), "name": .string(name)] }
  static func from(record: TeaQLRecord) throws -> Self { try Self(record: record) }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("native lifecycle fixture has no wire API") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("native lifecycle fixture has no wire API") }
}
