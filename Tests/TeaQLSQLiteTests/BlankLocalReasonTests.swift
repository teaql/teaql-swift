import Foundation
import XCTest
import TeaQLCore
import TeaQLSQLite

/// TC-MUT-11: native runtime composition and real SQLite, not generated API proof.
final class BlankLocalReasonTests: XCTestCase {
  func testBlankLocalReasonsInheritAtCommandSQLAndCommittedAuditWithBothLoggingModes() async throws {
    for logging in [false, true] {
      func descriptor(_ name: String) -> EntityDescriptor {
        EntityDescriptor(name: name, table: "blank_local_\(name.lowercased())", properties: [
          PropertyDescriptor(name: "id", type: .int, isID: true),
          PropertyDescriptor(name: "version", type: .int, isVersion: true),
          PropertyDescriptor(name: "name", type: .string),
        ])
      }
      let child = descriptor("PaymentAttempt"), sibling = descriptor("Shipment")
      let service = try SQLiteDataService(path: ":memory:")
      let audit = BlankLocalAudit(), sql = SQLExecutionEvidenceStore(), diagnostic = BlankLocalDiagnostic()
      let provider = BlankLocalProvider(service: service)
      let context = UserContext(queryExecutor: service, mutationExecutor: provider,
        requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
        diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging, mutationSQLLogEnabled: logging)
      try await context.ensureSchema(RuntimeModule(name: "blank local reasons", entities: [child, sibling]))
      let blanks: [String?] = [nil, "", " \t\r\n", "\u{0085}", "\u{00a0}", "\u{2003}"]
      for blank in blanks {
        do {
          _ = try await context.execute(Mutation(kind: .create, entity: child,
            values: ["id": .int(999), "name": .string("must not persist")], auditReason: blank))
          XCTFail("public request accepted blank intent")
        } catch let error as RequestIntentError {
          XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
          XCTAssertEqual(error.field, "comment")
          XCTAssertEqual(error.requestKind, "mutation")
        }
      }
      let rejected = await provider.snapshot()
      XCTAssertEqual(rejected.0.count, 0)
      XCTAssertEqual(rejected.1, 0)
      let rejectedSQL = await sql.snapshot(), rejectedAudit = await audit.snapshot()
      let rejectedDiagnostics = await diagnostic.snapshot()
      XCTAssertTrue(rejectedSQL.isEmpty && rejectedAudit.isEmpty && rejectedDiagnostics.isEmpty)

      try await context.executeGraphSave(comment: "submit order") { graphContext, session in
        let root = try session.scope(key: EntityKey(entity: "CustomerOrder", id: .int(100)))
        let payment = try session.scope(key: EntityKey(entity: "Payment", id: .int(201)),
          localReason: "authorize payment", parent: root)
        let shipment = try session.scope(key: EntityKey(entity: "Shipment", id: .int(301)),
          localReason: "dispatch shipment", parent: root)
        for (index, blank) in blanks.enumerated() {
          // Feed the original blank into the runtime. No test-side coalescing,
          // filtering, expected-lineage injection or caller-owned fallback.
          let inherited = try session.scope(key: EntityKey(entity: child.name, id: .int(Int64(400 + index))),
            localReason: blank, parent: payment)
          XCTAssertTrue(inherited === payment)
          let result = try await graphContext.execute(Mutation(kind: .create, entity: child,
            values: ["id": .int(Int64(400 + index)), "name": .string("attempt-\(index)")],
            auditReason: session.intent.comment, mutationLineage: inherited.recover()))
          XCTAssertEqual(result.persistedRecord?["name"], .string("attempt-\(index)"))
          XCTAssertEqual(result.metadata?.statements.map(\.operation), [.insert, .select])
          XCTAssertEqual(result.metadata?.statements.first?.mutationLineage, payment.recover())
          let pending = await audit.snapshot()
          XCTAssertTrue(pending.isEmpty, "graph audit escaped before commit")
        }
        _ = try await graphContext.execute(Mutation(kind: .create, entity: sibling,
          values: ["id": .int(301), "name": .string("sibling")],
          auditReason: session.intent.comment, mutationLineage: shipment.recover()))
        XCTAssertEqual(root.recover().map(\.comment), ["submit order"])
        XCTAssertEqual(payment.recover().map(\.comment), ["submit order", "authorize payment"])
        let pending = await audit.snapshot()
        XCTAssertTrue(pending.isEmpty)
      }
      let (commands, begins) = await provider.snapshot()
      XCTAssertEqual(begins, 1)
      XCTAssertEqual(commands.count, blanks.count + 1)
      let events = await audit.snapshot(), physical = await sql.snapshot(), diagnostics = await diagnostic.snapshot()
      XCTAssertEqual(events.count, blanks.count + 1)
      XCTAssertEqual(physical.count, 2 * (blanks.count + 1))
      XCTAssertEqual(diagnostics.count, logging ? physical.count : 0)
      for (index, command) in commands.enumerated() {
        let isSibling = index == blanks.count
        let expectedNames = ["CustomerOrder", isSibling ? "Shipment" : "Payment"]
        let expectedIDs: [TeaQLValue?] = [.int(100), .int(isSibling ? 301 : 201)]
        let expectedReasons = ["submit order", isSibling ? "dispatch shipment" : "authorize payment"]
        XCTAssertEqual(command.mutation.mutationLineage?.map(\.name), expectedNames)
        XCTAssertEqual(command.mutation.mutationLineage?.map(\.entityID), expectedIDs)
        XCTAssertEqual(command.mutation.mutationLineage?.map(\.comment), expectedReasons)
        XCTAssertEqual(events[index].entity, command.mutation.entity.name)
        XCTAssertEqual(events[index].entityID, command.mutation.values["id"])
        XCTAssertEqual(events[index].mutationLineage, command.mutation.mutationLineage)
        XCTAssertEqual(events[index].reason, "submit order")
        for statement in physical[(index * 2)...(index * 2 + 1)] {
          XCTAssertEqual(statement.mutationLineage, command.mutation.mutationLineage)
          XCTAssertEqual(statement.auditReason, "submit order")
          XCTAssertEqual(statement.executionOutcome, "success")
        }
      }
      var query = SelectQuery(entity: child)
      query.limit = 10; query.comment = "inspect committed attempts"; query.purpose = "verify inherited writes"
      let persisted = try await context.execute(query)
      XCTAssertEqual(Set(persisted.records.compactMap { $0["id"]?.int64Value }), Set((400..<406).map(Int64.init)))
    }
  }
}

private actor BlankLocalAudit: AuditSink {
  private var events: [AuditEvent] = []
  func record(_ event: AuditEvent) { events.append(event) }
  func snapshot() -> [AuditEvent] { events }
}

private actor BlankLocalDiagnostic: DiagnosticSQLLogSink {
  private var entries: [SQLExecutionMetadata] = []
  func write(_ metadata: SQLExecutionMetadata) { entries.append(metadata) }
  func snapshot() -> [SQLExecutionMetadata] { entries }
}

private actor BlankLocalProvider: GraphTransactionExecutor {
  let service: SQLiteDataService
  private var commands: [MutationRequest] = []
  private var begins = 0
  init(service: SQLiteDataService) { self.service = service }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    commands.append(request)
    return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
  func snapshot() -> ([MutationRequest], Int) { (commands, begins) }
}
