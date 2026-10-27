import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSecureDocumentReference
import TeaQLSQLite
import Testing

private struct OrderBlobAuthorization: BlobBindingAuthorization {
  func scope(for actor: UserContext) throws -> String { "merchant:7" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool {
    target == BlobBindingTarget(entity: "Order", entityID: "10", field: "attachment") &&
      next != nil && action == "Update"
  }
}

private actor SQLiteOrderHost: SQLiteContextBoundDocumentHost, SQLiteDocumentBlobSelectionHost {
  private let blobEnabled: Bool
  private var actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Merchant", domainRootID: 7)
  private var failPresent = false
  private var switchActorOnApply = false
  private var mutationCount = 0

  init(blobEnabled: Bool = false) { self.blobEnabled = blobEnabled }

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
    let projection = blobEnabled
      ? "SELECT id,version,quantity,blob_key FROM document_order WHERE business_id=?"
      : "SELECT id,version,quantity FROM document_order WHERE business_id=?"
    let rows = try await sql.query(projection, parameters: [.string(businessID)])
    guard rows.count == 1, let id = rows[0]["id"]?.int64Value,
      let version = rows[0]["version"]?.int64Value,
      let quantity = rows[0]["quantity"]?.int64Value else { throw ReferenceError("missing order") }
    let scope = ReferenceDocumentScope(documentID: "edit-10", purpose: "edit-order",
      aggregateType: "Order", aggregateID: UInt64(id), aggregateRevision: version)
    let identity = ReferenceIdentity(entityType: "Order", id: UInt64(id), version: version)
    let fields = blobEnabled ? ["attachment", "quantity"] : ["quantity"]
    let snapshot = DocumentSnapshot(modelFingerprint: "model-v1", businessID: businessID,
      scope: scope, aggregate: identity, entities: [DocumentEntitySnapshot(rowKey: "order:10",
        identity: identity, loadedFields: fields, writableFields: fields,
        allowedMutations: ["UPDATE"])], relations: [])
    var bindings: [DocumentBlobBindingSnapshot] = []
    if blobEnabled {
      let bound = try await sql.query("""
        SELECT key,version FROM teaql_blob_binding WHERE scope=? AND entity=?
          AND entity_id=? AND field=?
        """, parameters: [.string("merchant:7"), .string("Order"),
          .string("10"), .string("attachment")])
      guard bound.count <= 1 else { throw ReferenceError("bad binding") }
      let key = bound.first?["key"]?.stringValue
      guard key == rows[0]["blob_key"]?.stringValue else {
        throw ReferenceError("business binding mismatch")
      }
      let reference = try key.map { try BlobRef($0) }
      let version = bound.first?["version"]?.int64Value ?? 0
      bindings = [DocumentBlobBindingSnapshot(rowKey: "order:10", canonicalField: "attachment",
        entityType: "Order", reference: reference, bindingVersion: UInt64(version),
        nullable: true, writable: true)]
    }
    return CurrentBoundDocument(document: BoundDocumentSnapshot(snapshot: snapshot, bindings: bindings),
      body: .object(["quantity": .int(quantity)]), lifetimeSeconds: 300)
  }

  func bindBlobSelection(context: UserContext, session: GraphMutationSession,
    selection: VerifiedDocumentBlobSelection, sql: any GraphPhysicalSQLLease) async throws {
    guard blobEnabled, selection.target.targetEntity == "Order",
      selection.target.targetKey == "order:10",
      selection.target.canonicalField == "attachment", selection.entityID == "10" else {
      throw ReferenceError("BLOB_BIND_DENIED")
    }
    let affected = try await sql.execute("UPDATE document_order SET blob_key=? WHERE id=?",
      parameters: [.string(selection.reference.key), .int(10)])
    guard affected == 1 else { throw ReferenceError("BLOB_BIND_DENIED") }
    _ = try await SQLiteBlobCatalog().bindOnGraphLease(context, session: session, lease: sql,
      change: BlobBindingChange(target: BlobBindingTarget(entity: "Order", entityID: "10",
        field: "attachment"), next: selection.reference,
        expectedVersion: selection.expectedVersion, nextVersion: selection.nextVersion,
        action: "Update"), authorization: OrderBlobAuthorization())
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

@Test
func swiftSQLiteDocumentBlobSelectionSharesBusinessBindingAndReceipt() async throws {
  let database = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  try await context.executeGraphSave(comment: "install selected order") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TABLE document_order(id INTEGER PRIMARY KEY,business_id TEXT NOT NULL UNIQUE,
          version INTEGER NOT NULL,quantity INTEGER NOT NULL,blob_key TEXT)
        """, parameters: [])
      _ = try await sql.execute("CREATE TABLE document_permission(subject TEXT PRIMARY KEY,can_edit INTEGER NOT NULL)",
        parameters: [])
      _ = try await sql.execute("INSERT INTO document_order VALUES(10,'ORD-10',1,1,NULL)", parameters: [])
      _ = try await sql.execute("INSERT INTO document_permission VALUES('alice',1)", parameters: [])
    }
    try await SQLiteBlobCatalog().installSchema(graph, session: session)
  }
  try await context.executeGraphSave(comment: "stage selected blobs") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      for key in ["blob_A", "blob_B"] {
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_catalog
          (key,scope,object_key,content_version,file_name,content_type,size_bytes,status)
          VALUES (?,?,?,?,?,?,?,'uploaded_unbound')
          """, parameters: [.string(key), .string("merchant:7"), .string("objects/" + key),
            .string("v1"), .string(key + ".pdf"), .string("application/pdf"), .int(3)])
      }
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
  let host = SQLiteOrderHost(blobEnabled: true)
  let service = SQLiteContextBoundDocumentService(actor: context, module: module,
    journal: journal, host: host)
  let openRequest = DocumentOpenRequest(aggregateType: "Order", businessID: "ORD-10",
    purpose: "edit-order", lifetimeSeconds: 60)
  let principal = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Merchant", domainRootID: 7)
  func selection(_ opened: ContextualDocument, commandID: String, key: String) throws
    -> DocumentBlobSelectionSubmission {
    let issued = try runtime.consumeBoundDocumentSnapshot(principal,
      token: opened.documentToken, aggregateType: "Order", purpose: "edit-order").document
    let target = BlobSelectionTarget(scope: issued.snapshot.scope, targetEntity: "Order",
      canonicalField: "attachment", kind: "EXISTING_ROW", targetKey: "order:10",
      commandID: commandID)
    let token = try runtime.issueBlobSelection(principal, documentToken: opened.documentToken,
      claim: BlobSelectionClaim(target: target, reference: BlobRef(key)), lifetimeSeconds: 60)
    return DocumentBlobSelectionSubmission(token: token, targetEntity: "Order",
      canonicalField: "attachment", kind: "EXISTING_ROW", targetKey: "order:10")
  }
  func accept(_ command: SubmittedDocumentCommand) async throws -> AcceptedDocument {
    try await service.accept(DocumentAcceptRequest(aggregateType: "Order",
      purpose: "edit-order", submitted: command))
  }
  func bindingState() async throws -> (Int64, String, String, Int64, String, String, Int) {
    try await context.executeGraphSave(comment: "inspect selected order") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let order = try await sql.query("SELECT version,blob_key FROM document_order", parameters: [])
        let binding = try await sql.query("SELECT key,version FROM teaql_blob_binding", parameters: [])
        let catalog = try await sql.query("SELECT key,status FROM teaql_blob_catalog ORDER BY key",
          parameters: [])
        let receipts = try await sql.query("SELECT command_id FROM teaql_document_command_receipt",
          parameters: [])
        return (order[0]["version"]!.int64Value!, order[0]["blob_key"]!.stringValue!,
          binding[0]["key"]!.stringValue!, binding[0]["version"]!.int64Value!,
          catalog[0]["status"]!.stringValue!, catalog[1]["status"]!.stringValue!, receipts.count)
      }
    }
  }
  func selectedState() async throws -> Bool {
    let state = try await bindingState()
    return state.0 == 2 && state.1 == "blob_A" && state.2 == "blob_A" &&
      state.3 == 1 && state.4 == "available" &&
      state.5 == "uploaded_unbound" && state.6 == 1
  }

  let opened = try await service.open(openRequest)
  let command = SubmittedDocumentCommand(businessID: "ORD-10", documentToken: opened.documentToken,
    commandID: "command-1", body: .object(["quantity": .int(3)]),
    blobSelections: [try selection(opened, commandID: "command-1", key: "blob_A")])
  let first = try await accept(command)
  #expect(!first.replayed && first.previousRevision == 1 && first.newRevision == 2)
  #expect(try await selectedState())
  #expect(try await accept(command).replayed)
  #expect(await host.mutations() == 1)
  do {
    _ = try await accept(SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: opened.documentToken, commandID: "command-1", body: command.body))
    Issue.record("changed selection replayed")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_REPLAY_CONFLICT") }

  let fresh = try await service.open(openRequest)
  do {
    _ = try await accept(SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: fresh.documentToken, commandID: "command-wrong",
      body: .object(["quantity": .int(3)]), blobSelections: [
        try selection(fresh, commandID: "other-command", key: "blob_A"),
      ]))
    Issue.record("wrong-command selection accepted")
  } catch { #expect((error as? ReferenceError)?.code == "ROUND_TRIP_REFERENCE_SCOPE_MISMATCH") }
  let duplicate = try selection(fresh, commandID: "command-duplicate", key: "blob_A")
  do {
    _ = try await accept(SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: fresh.documentToken, commandID: "command-duplicate",
      body: .object(["quantity": .int(3)]), blobSelections: [duplicate, duplicate]))
    Issue.record("duplicate selection accepted")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_COMMAND_INVALID") }
  do {
    _ = try await accept(SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: fresh.documentToken, commandID: "command-missing",
      body: .object(["quantity": .int(3)]), blobSelections: [
        try selection(fresh, commandID: "command-missing", key: "blob_missing"),
      ]))
    Issue.record("missing catalog content accepted")
  } catch { #expect(String(describing: error).contains("BLOB_BIND_DENIED")) }
  #expect(try await selectedState())

  try await context.executeGraphSave(comment: "reject selected receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TRIGGER reject_selected_receipt BEFORE INSERT ON teaql_document_command_receipt
        WHEN NEW.command_id='command-receipt-fail'
        BEGIN SELECT RAISE(ABORT, 'receipt rejected'); END
        """, parameters: [])
    }
  }
  do {
    _ = try await accept(SubmittedDocumentCommand(businessID: "ORD-10",
      documentToken: fresh.documentToken, commandID: "command-receipt-fail",
      body: .object(["quantity": .int(3)]), blobSelections: [
        try selection(fresh, commandID: "command-receipt-fail", key: "blob_B"),
      ]))
    Issue.record("selected receipt failure committed")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_CATALOG_FAILED") }
  #expect(try await selectedState())
}
