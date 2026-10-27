import Foundation
import TeaQLCore
import TeaQLSecureDocumentReference
import TeaQLSQLite
import Testing

private actor SQLiteOrderHost: SQLiteContextBoundDocumentHost {
  private var actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Merchant", domainRootID: 7)
  private var failPresent = false
  private var switchActorOnApply = false
  private var mutationCount = 0

  func principal(context: UserContext) throws -> TrustedReferencePrincipal { actor }
  func setPresentationFailure(_ value: Bool) { failPresent = value }
  func setActorDrift(_ value: Bool) { switchActorOnApply = value }
  func restoreActor() {
    actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
      domainRootType: "Merchant", domainRootID: 7)
  }
  func mutations() -> Int { mutationCount }

  func authorize(context: UserContext, principal: TrustedReferencePrincipal,
                 scope: ReferenceDocumentScope, sql: any GraphPhysicalSQLLease) async throws {
    let rows = try await sql.query("SELECT can_edit FROM document_permission WHERE subject=?",
      parameters: [.string(principal.subject)])
    guard rows.count == 1, rows[0]["can_edit"]?.int64Value == 1 else {
      throw ReferenceError("revoked")
    }
  }

  func load(context: UserContext, businessID: String,
            sql: any GraphPhysicalSQLLease) async throws -> CurrentBoundDocument {
    let rows = try await sql.query("""
      SELECT id,version,quantity FROM document_order WHERE business_id=?
      """, parameters: [.string(businessID)])
    guard rows.count == 1, let id = rows[0]["id"]?.int64Value,
      let version = rows[0]["version"]?.int64Value,
      let quantity = rows[0]["quantity"]?.int64Value else { throw ReferenceError("missing order") }
    let scope = ReferenceDocumentScope(documentID: "edit-10", purpose: "edit-order",
      aggregateType: "Order", aggregateID: UInt64(id), aggregateRevision: version)
    let identity = ReferenceIdentity(entityType: "Order", id: UInt64(id), version: version)
    let snapshot = DocumentSnapshot(modelFingerprint: "model-v1", businessID: businessID,
      scope: scope, aggregate: identity, entities: [DocumentEntitySnapshot(rowKey: "order:10",
        identity: identity, loadedFields: ["quantity"], writableFields: ["quantity"],
        allowedMutations: ["UPDATE"])], relations: [])
    return CurrentBoundDocument(document: BoundDocumentSnapshot(snapshot: snapshot, bindings: []),
      body: .object(["quantity": .int(quantity)]), lifetimeSeconds: 300)
  }

  func apply(context: UserContext, issued: BoundDocumentSnapshot,
             submitted: SubmittedDocumentCommand, sql: any GraphPhysicalSQLLease) async throws {
    mutationCount += 1
    guard submitted.body == .object(["quantity": .int(3)]) else {
      throw ReferenceError("invalid quantity")
    }
    let changed = try await sql.execute("""
      UPDATE document_order SET quantity=?,version=version+1 WHERE id=? AND version=?
      """, parameters: [.int(3), .int(10), .int(issued.snapshot.scope.aggregateRevision)])
    guard changed == 1 else { throw ReferenceError("stale order") }
    if switchActorOnApply {
      actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "bob",
        domainRootType: "Merchant", domainRootID: 7)
    }
  }

  func present(context: UserContext, document: ContextualDocument) throws {
    guard document.businessID == "ORD-10" else { throw ReferenceError("wrong document") }
    if failPresent { throw ReferenceError("presentation failed") }
  }
}

private func serviceState(_ context: UserContext) async throws -> (Int64, Int64, Int) {
  try await context.executeGraphSave(comment: "inspect protected order") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let row = try await sql.query("SELECT version,quantity FROM document_order WHERE id=10", parameters: [])
      let receipts = try await sql.query("SELECT command_id FROM teaql_document_command_receipt", parameters: [])
      return (row[0]["version"]!.int64Value!, row[0]["quantity"]!.int64Value!, receipts.count)
    }
  }
}

@Test
func swiftSQLiteSecureDocumentOpenAcceptAndReplay() async throws {
  let database = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  try await context.executeGraphSave(comment: "install protected order") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TABLE document_order(id INTEGER PRIMARY KEY,business_id TEXT NOT NULL UNIQUE,
          version INTEGER NOT NULL,quantity INTEGER NOT NULL)
        """, parameters: [])
      _ = try await sql.execute("CREATE TABLE document_permission(subject TEXT PRIMARY KEY,can_edit INTEGER NOT NULL)",
        parameters: [])
      _ = try await sql.execute("INSERT INTO document_order VALUES(10,'ORD-10',1,1)", parameters: [])
      _ = try await sql.execute("INSERT INTO document_permission VALUES('alice',1)", parameters: [])
    }
  }
  let keys = try StaticReferenceKeyProvider(current: "k1", keys: [
    ReferenceKey(keyID: "k1", masterKey: Array(repeating: 0x42, count: 32)),
  ])
  let runtime = try ContextBoundReferenceRuntime(service: "order-service", environment: "test",
    keys: keys, authorize: { _, _, _ in true })
  let module = SecureDocumentReferenceModule(runtime: runtime)
  let journal = SQLiteDocumentCommandJournal()
  try await journal.installSchema(context)
  try await journal.validateSchema(context)
  let host = SQLiteOrderHost()
  let service = SQLiteContextBoundDocumentService(actor: context, module: module,
    journal: journal, host: host)
  let open = DocumentOpenRequest(aggregateType: "Order", businessID: "ORD-10",
    purpose: "edit-order", lifetimeSeconds: 60)
  let firstOpen = try await service.open(open)
  #expect(firstOpen.documentToken.hasPrefix("tqd2."))
  #expect(firstOpen.body == .object(["quantity": .int(1)]))
  #expect(!firstOpen.description.contains(firstOpen.documentToken))
  let command = SubmittedDocumentCommand(businessID: "ORD-10", documentToken: firstOpen.documentToken,
    commandID: "command-1", body: .object(["quantity": .int(3)]))
  let request = DocumentAcceptRequest(aggregateType: "Order", purpose: "edit-order", submitted: command)
  let first = try await service.accept(request)
  #expect(!first.replayed && first.previousRevision == 1 && first.newRevision == 2)
  #expect(first.document.body == .object(["quantity": .int(3)]))
  #expect(!first.description.contains(first.document.documentToken))
  #expect(try await serviceState(context) == (2, 3, 1))
  let replay = try await service.accept(request)
  #expect(replay.replayed && replay.document.documentToken == first.document.documentToken)
  #expect(await host.mutations() == 1)
  do {
    let changed = SubmittedDocumentCommand(businessID: command.businessID,
      documentToken: command.documentToken, commandID: command.commandID,
      body: .object(["quantity": .int(4)]))
    _ = try await service.accept(DocumentAcceptRequest(aggregateType: "Order",
      purpose: "edit-order", submitted: changed))
    Issue.record("changed command replayed")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_REPLAY_CONFLICT") }
  do {
    let stale = SubmittedDocumentCommand(businessID: command.businessID,
      documentToken: command.documentToken, commandID: "command-stale", body: command.body)
    _ = try await service.accept(DocumentAcceptRequest(aggregateType: "Order",
      purpose: "edit-order", submitted: stale))
    Issue.record("stale document accepted")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_REVISION_CONFLICT") }
  try await context.executeGraphSave(comment: "revoke protected order") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE document_permission SET can_edit=0 WHERE subject='alice'", parameters: [])
    }
  }
  do { _ = try await service.accept(request); Issue.record("revoked command replayed") }
  catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_AUTHORIZATION_REQUIRED") }
  do { _ = try await service.open(open); Issue.record("revoked document opened") }
  catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_AUTHORIZATION_REQUIRED") }
  try await context.executeGraphSave(comment: "restore protected order") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE document_permission SET can_edit=1 WHERE subject='alice'", parameters: [])
    }
  }
  let latest = try await service.open(open)
  let followup = SubmittedDocumentCommand(businessID: "ORD-10",
    documentToken: latest.documentToken, commandID: "command-2", body: .object(["quantity": .int(3)]))
  let followupRequest = DocumentAcceptRequest(aggregateType: "Order", purpose: "edit-order",
    submitted: followup)
  await host.setPresentationFailure(true)
  do { _ = try await service.accept(followupRequest); Issue.record("presentation failure lost") }
  catch { #expect(error is GraphCommittedError) }
  await host.setPresentationFailure(false)
  let recovered = try await service.accept(followupRequest)
  #expect(recovered.replayed && recovered.newRevision == 3)
  #expect(await host.mutations() == 2)
  try await context.executeGraphSave(comment: "reject protected receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TRIGGER reject_document_receipt BEFORE INSERT ON teaql_document_command_receipt
        WHEN NEW.command_id='command-trigger' BEGIN SELECT RAISE(ABORT, 'receipt rejected'); END
        """, parameters: [])
    }
  }
  let newest = try await service.open(open)
  do {
    let triggered = SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: newest.documentToken, commandID: "command-trigger",
      body: .object(["quantity": .int(3)]))
    _ = try await service.accept(DocumentAcceptRequest(aggregateType: "Order",
      purpose: "edit-order", submitted: triggered))
    Issue.record("receipt failure committed protected order")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_CATALOG_FAILED") }
  #expect(try await serviceState(context) == (3, 3, 2))
  await host.setActorDrift(true)
  do {
    let drifting = SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: newest.documentToken, commandID: "command-actor-drift",
      body: .object(["quantity": .int(3)]))
    _ = try await service.accept(DocumentAcceptRequest(aggregateType: "Order",
      purpose: "edit-order", submitted: drifting))
    Issue.record("actor drift committed protected order")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_AUTHORIZATION_REQUIRED") }
  await host.restoreActor()
  #expect(try await serviceState(context) == (3, 3, 2))
}
