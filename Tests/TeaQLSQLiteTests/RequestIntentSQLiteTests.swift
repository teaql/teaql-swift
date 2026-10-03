import Foundation
import XCTest
import TeaQLCore
import TeaQLSQLite

final class RequestIntentSQLiteTests: XCTestCase {
  func testExplicitMutationCommentSurvivesBlankTypedRouteTailsAtRealSinks() async throws {
    for logging in [false, true] {
      for kind in ["entity", "provider", "sql"] {
        let entity = EntityDescriptor(name: "School", table: "request_tail_school", properties: [
          PropertyDescriptor(name: "id", type: .int, isID: true),
          PropertyDescriptor(name: "version", type: .int, isVersion: true),
          PropertyDescriptor(name: "name", type: .string),
        ])
        let service = try SQLiteDataService(path: ":memory:")
        let audit = IntentTailAudit(), sql = SQLExecutionEvidenceStore(), diagnostic = IntentTailDiagnostic()
        let provider = IntentTailProvider(service: service, audit: audit)
        let plans = IntentTailPlans()
        let policy = IntentTailPolicy(plans: plans)
        let context = UserContext(queryExecutor: service, mutationExecutor: provider,
          requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
          diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging, mutationSQLLogEnabled: logging,
          mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy },
          mutationPolicyApprovalProvider: DelegatingMutationPolicyApprovalProvider {
            MutationPolicyApproval(policy: $0, approvedBy: "native request test", approvedAt: Date())
          })
        try await context.ensureSchema(RuntimeModule(name: "request tail", entities: [entity]))
        let comment = "  explicit mutation request reason  "
        let tailName = kind == "entity" ? "School" : kind == "provider" ? "sqlite" : "insert"
        // TC-REQ-13 deliberately supplies diagnostic input; this does not prove
        // that generated traversal constructs the supplied route frames.
        let lineage = [
          TraceNode(entity: "School", comment: comment, purpose: "", kind: "auditReason", entityID: .int(802)),
          TraceNode(entity: tailName, comment: "", purpose: "", kind: kind),
        ]
        let mutation = Mutation(kind: .create, entity: entity,
          values: ["id": .int(802), "name": .string("stored school")],
          auditReason: comment, mutationLineage: lineage)
        let request = try MutationRequest(mutation: mutation)
        XCTAssertEqual(request.intent.comment, comment)
        XCTAssertEqual(try request.intent.readbackIntent().comment, comment)
        XCTAssertEqual(request.mutation.mutationLineage?.last?.kind, kind)
        XCTAssertEqual(request.mutation.mutationLineage?.last?.comment, "")
        let result = try await context.execute(request)
        XCTAssertEqual(result.persistedRecord?["name"], .string("stored school"))
        XCTAssertEqual(result.persistedRecord?["version"], .int(1))
        XCTAssertEqual(plans.snapshot().map(\.auditReason), [comment])
        let (commands, prematureAudit) = await provider.snapshot()
        XCTAssertEqual(commands.count, 1)
        XCTAssertFalse(prematureAudit)
        XCTAssertEqual(commands.first?.intent.comment, comment)
        XCTAssertEqual(commands.first?.mutation.auditReason, comment)
        XCTAssertEqual(commands.first?.mutation.mutationLineage, lineage)
        let metadata = try XCTUnwrap(result.metadata)
        XCTAssertEqual(metadata.statements.map(\.operation), [.insert, .select])
        let physical = await sql.snapshot(), diagnostics = await diagnostic.snapshot()
        XCTAssertEqual(physical.count, 2)
        XCTAssertEqual(diagnostics.count, logging ? 2 : 0)
        for statement in metadata.statements + physical + diagnostics {
          XCTAssertEqual(statement.executionOutcome, "success")
          XCTAssertEqual(statement.auditReason, comment)
          XCTAssertEqual(statement.mutationLineage, lineage)
        }
        let events = await audit.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, comment)
        XCTAssertEqual(events.first?.mutationLineage, lineage)
        XCTAssertEqual(request.intent.comment, comment)
        XCTAssertEqual(mutation.mutationLineage, lineage)
      }
    }
  }

  func testAnnotatedChildrenCannotSupplyMissingBatchRootIntent() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let absent = EntityDescriptor(name: "School", table: "absent_batch_table",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    do {
      let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
        requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
      _ = try await context.execute(MutationBatchRequest(mutations: [
        Mutation(kind: .create, entity: absent, auditReason: "valid first child"),
        Mutation(kind: .create, entity: absent, auditReason: "valid second child"),
      ], comment: nil))
      XCTFail("annotated child array accepted without root comment")
    } catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.field, "comment")
    } catch {
      XCTFail("missing root intent reached SQLite instead of request gate: \(error)")
    }
  }

  func testDirectProviderRejectsMissingIntentWithoutSchemaOrStatementExecution() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let entity = EntityDescriptor(name: "AbsentTable", table: "absent_table",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    let query = SelectQuery(entity: entity)
    do { _ = try await provider.execute(query); XCTFail("query reached absent table") }
    catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.field, "comment")
    }
    do { _ = try await provider.count(query); XCTFail("count reached absent table") }
    catch let error as RequestIntentError { XCTAssertEqual(error.field, "comment") }
    do { _ = try await provider.execute(Mutation(kind: .create, entity: entity)); XCTFail("mutation reached absent table") }
    catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.requestKind, "mutation")
    }
    try await provider.beginGraphTransaction()
    do {
      do { _ = try await provider.execute(Mutation(kind: .update, entity: entity)); XCTFail("transaction bypassed gate") }
      catch let error as RequestIntentError { XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED") }
      try await provider.rollbackGraphTransaction()
    } catch {
      try? await provider.rollbackGraphTransaction()
      throw error
    }
  }
}

private actor IntentTailAudit: AuditSink {
  private var events: [AuditEvent] = []
  func record(_ event: AuditEvent) { events.append(event) }
  func snapshot() -> [AuditEvent] { events }
}

private actor IntentTailDiagnostic: DiagnosticSQLLogSink {
  private var entries: [SQLExecutionMetadata] = []
  func write(_ metadata: SQLExecutionMetadata) { entries.append(metadata) }
  func snapshot() -> [SQLExecutionMetadata] { entries }
}

private actor IntentTailProvider: MutationExecutor {
  let service: SQLiteDataService
  let audit: IntentTailAudit
  private var commands: [MutationRequest] = []
  private var prematureAudit = false
  init(service: SQLiteDataService, audit: IntentTailAudit) { self.service = service; self.audit = audit }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    commands.append(request)
    let result = try await service.execute(request)
    prematureAudit = !(await audit.snapshot()).isEmpty
    return result
  }
  func snapshot() -> ([MutationRequest], Bool) { (commands, prematureAudit) }
}

private final class IntentTailPlans: @unchecked Sendable {
  private let lock = NSLock()
  private var plans: [MutationPlan] = []
  func append(_ plan: MutationPlan) { lock.withLock { plans.append(plan) } }
  func snapshot() -> [MutationPlan] { lock.withLock { plans } }
}

private struct IntentTailPolicy: MutationPolicy {
  let plans: IntentTailPlans
  let identity = MutationPolicyIdentity(policyID: "request-tail", version: "1", fingerprint: "request-tail-v1")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    plans.append(plan)
    return MutationPolicyDecision(verdict: .allow)
  }
}
