import Foundation
import XCTest
import TeaQLCore
import TeaQLSQLite

/// TC-REQ-13: deliberate caller route-tail stimuli, not generated graph proof.
final class BlankRouteTailTests: XCTestCase {
  func testExplicitRootCommentSurvivesEveryBlankRouteTailAtRealSinks() async throws {
    for logging in [false, true] {
      let descriptor = EntityDescriptor(name: "School", table: "blank_tail_school", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true),
        PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "name", type: .string),
      ])
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("teaql-swift-blank-tail-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let path = directory.appendingPathComponent("trace.sqlite").path
      let service = try SQLiteDataService(path: path)
      let independent = try SQLiteDataService(path: path)
      let provider = BlankTailProvider(service: service)
      let audit = BlankTailAudit(independent: independent, descriptor: descriptor)
      let sql = SQLExecutionEvidenceStore(), diagnostic = BlankTailDiagnostic()
      let context = UserContext(queryExecutor: service, mutationExecutor: provider,
        requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
        diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging, mutationSQLLogEnabled: logging)
      try await context.ensureSchema(RuntimeModule(name: "blank route tails", entities: [descriptor]))

      for (index, kind) in ["entity", "provider", "sql"].enumerated() {
        let id = TeaQLValue.int(Int64(401 + index)), comment = "explicit root comment"
        let source = [
          TraceNode(entity: "School", comment: comment, purpose: "", kind: "auditReason", entityID: id),
          TraceNode(entity: "School", comment: "", purpose: "", level: 1, kind: kind,
            name: kind == "entity" ? "School" : kind == "provider" ? "sqlite" : "insert"),
        ]
        let mutation = Mutation(kind: .create, entity: descriptor,
          values: ["id": id, "name": .string("route fixture")],
          auditReason: comment, mutationLineage: source)
        let request = try MutationRequest(mutation: mutation)
        XCTAssertEqual(request.mutation.mutationLineage?.last?.kind, kind)
        XCTAssertEqual(request.mutation.mutationLineage?.last?.comment, "")
        XCTAssertEqual(request.intent.comment, comment)

        try await context.executeGraphSave(comment: comment) { graphContext, _ in
          let before = await audit.snapshot()
          let result = try await graphContext.execute(request)
          XCTAssertEqual(result.affectedRows, 1)
          XCTAssertEqual(result.persistedRecord?["id"], id)
          XCTAssertEqual(result.persistedRecord?["version"], .int(1))
          let pending = await audit.snapshot()
          XCTAssertEqual(pending.count, before.count, "no audit event before graph commit")
        }
        let commands = await provider.snapshot(), events = await audit.snapshot()
        XCTAssertEqual(commands.count, index + 1)
        XCTAssertEqual(events.count, index + 1)
        XCTAssertEqual(commands[index].intent.comment, comment)
        XCTAssertEqual(commands[index].mutation.mutationLineage, source)
        XCTAssertEqual(events[index].entityID, id)
        XCTAssertEqual(events[index].reason, comment)
        XCTAssertEqual(events[index].mutationLineage, source)
        let physical = await sql.snapshot()
        XCTAssertEqual(physical.count, 2 * (index + 1))
        let pair = Array(physical.suffix(2))
        XCTAssertEqual(pair.map(\.operation), [.insert, .select])
        XCTAssertEqual(pair[0].affectedRows, 1)
        XCTAssertEqual(pair[1].resultCount, 1)
        for statement in pair {
          XCTAssertEqual(statement.auditReason, comment)
          XCTAssertEqual(statement.mutationLineage, source)
          XCTAssertEqual(statement.executionOutcome, "success")
          XCTAssertEqual(statement.tracePath.first?.name, "School")
          XCTAssertFalse(statement.tracePath.contains { $0.kind.lowercased() == "auditreason" })
        }
        XCTAssertEqual(pair[0].tracePath.last?.name, "insert")
        XCTAssertEqual(pair[1].tracePath.last?.name, "select")
        XCTAssertEqual(pair[1].comment, comment)
        let diagnostics = await diagnostic.snapshot()
        XCTAssertEqual(diagnostics.count, logging ? physical.count : 0)
      }
      print("TC-REQ-13 SWIFT REAL SINKS PASSED logging=\(logging) database=\(path)")
    }
  }
}

private actor BlankTailProvider: GraphTransactionExecutor {
  let service: SQLiteDataService
  private var commands: [MutationRequest] = []
  init(service: SQLiteDataService) { self.service = service }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    commands.append(request)
    return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
  func snapshot() -> [MutationRequest] { commands }
}

private actor BlankTailAudit: AuditSink {
  let independent: SQLiteDataService
  let descriptor: EntityDescriptor
  private var events: [AuditEvent] = []
  init(independent: SQLiteDataService, descriptor: EntityDescriptor) {
    self.independent = independent; self.descriptor = descriptor
  }
  func record(_ event: AuditEvent) async throws {
    let id = try XCTUnwrap(event.entityID)
    var query = SelectQuery(entity: descriptor)
    query.filter = .equal("id", id)
    query.limit = 1; query.comment = "inspect committed audit target"; query.purpose = "prove post-commit visibility"
    let persisted = try await independent.execute(QueryRequest(query: query))
    XCTAssertEqual(persisted.records.count, 1, "audit must see the row through a separate connection after commit")
    XCTAssertEqual(persisted.records.first?["id"], id)
    XCTAssertEqual(persisted.records.first?["version"], .int(1))
    events.append(event)
  }
  func snapshot() -> [AuditEvent] { events }
}

private actor BlankTailDiagnostic: DiagnosticSQLLogSink {
  private var entries: [SQLExecutionMetadata] = []
  func write(_ metadata: SQLExecutionMetadata) { entries.append(metadata) }
  func snapshot() -> [SQLExecutionMetadata] { entries }
}
