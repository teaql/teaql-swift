import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSecureDocumentReference
import TeaQLSQLite
import Testing

private struct OrderBlobAuthorization: BlobBindingAuthorization {
  let entity: String
  let entityID: String
  let expectedAction: String
  func scope(for actor: UserContext) throws -> String { "merchant:7" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool {
    target == BlobBindingTarget(entity: entity, entityID: entityID, field: "attachment") &&
      next != nil && action == expectedAction
  }
}

private actor SQLiteOrderHost: SQLiteContextBoundDocumentHost, SQLiteDocumentBlobSelectionHost,
  SQLiteDocumentNewBlobSelectionHost {
  private let blobEnabled: Bool
  private let childEnabled: Bool
  private var wrongResolve = false
  private var actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Merchant", domainRootID: 7)
  private var failPresent = false
  private var switchActorOnApply = false
  private var mutationCount = 0

  init(blobEnabled: Bool = false, childEnabled: Bool = false) {
    self.blobEnabled = blobEnabled; self.childEnabled = childEnabled
  }

  func principal(context: UserContext) throws -> TrustedReferencePrincipal { actor }
  func setPresentationFailure(_ value: Bool) { failPresent = value }
  func setActorDrift(_ value: Bool) { switchActorOnApply = value }
  func setWrongResolve(_ value: Bool) { wrongResolve = value }
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
    var snapshot = DocumentSnapshot(modelFingerprint: "model-v1", businessID: businessID,
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
    if childEnabled {
      let children = try await sql.query("""
        SELECT id,version,blob_key FROM document_order_line WHERE order_id=? ORDER BY id
        """, parameters: [.int(10)])
      var entities = snapshot.entities
      var rowKeys: [String] = []
      for child in children {
        guard let childID = child["id"]?.int64Value,
          let childVersion = child["version"]?.int64Value else {
          throw ReferenceError("DOCUMENT_PROJECTION_VIOLATION")
        }
        let rowKey = "line:\(childID)"
        rowKeys.append(rowKey)
        let linked = try await sql.query("""
          SELECT key,version FROM teaql_blob_binding WHERE scope=? AND entity=?
            AND entity_id=? AND field=?
          """, parameters: [.string("merchant:7"), .string("OrderLine"),
            .string(String(childID)), .string("attachment")])
        guard linked.count <= 1, child["blob_key"]?.stringValue == linked.first?["key"]?.stringValue else {
          throw ReferenceError("DOCUMENT_PROJECTION_VIOLATION")
        }
        let reference = try linked.first?["key"]?.stringValue.map { try BlobRef($0) }
        let bindingVersion = linked.first?["version"]?.int64Value ?? 0
        entities.append(DocumentEntitySnapshot(rowKey: rowKey,
          identity: ReferenceIdentity(entityType: "OrderLine", id: UInt64(childID),
            version: childVersion), loadedFields: ["attachment"], writableFields: ["attachment"],
          allowedMutations: ["UPDATE"]))
        bindings.append(DocumentBlobBindingSnapshot(rowKey: rowKey, canonicalField: "attachment",
          entityType: "OrderLine", reference: reference, bindingVersion: UInt64(bindingVersion),
          nullable: true, writable: true))
      }
      snapshot = DocumentSnapshot(modelFingerprint: snapshot.modelFingerprint,
        businessID: snapshot.businessID, scope: snapshot.scope, aggregate: snapshot.aggregate,
        entities: entities, relations: [DocumentRelationSnapshot(name: "lines", rowKeys: rowKeys,
          completeness: "COMPLETE", writable: true, allowedMutations: ["CREATE_CHILD"])])
      bindings.sort { left, right in
        if left.rowKey == right.rowKey { return left.canonicalField < right.canonicalField }
        return left.rowKey < right.rowKey
      }
    }
    return CurrentBoundDocument(document: BoundDocumentSnapshot(snapshot: snapshot, bindings: bindings),
      body: .object(["quantity": .int(quantity)]), lifetimeSeconds: 300)
  }

  func bindBlobSelection(context: UserContext, session: GraphMutationSession,
    selection: VerifiedDocumentBlobSelection, sql: any GraphPhysicalSQLLease) async throws {
    let child = selection.target.kind == "NEW_CLIENT_KEY" &&
      selection.target.targetEntity == "OrderLine" &&
      selection.rowKey == "line:" + selection.entityID
    let parent = selection.target.kind == "EXISTING_ROW" &&
      selection.target.targetEntity == "Order" && selection.target.targetKey == "order:10" &&
      selection.entityID == "10"
    guard blobEnabled, (parent || child), selection.target.canonicalField == "attachment" else {
      throw ReferenceError("BLOB_BIND_DENIED")
    }
    guard let persistedID = Int64(selection.entityID) else { throw ReferenceError("BLOB_BIND_DENIED") }
    let affected = try await sql.execute(child
      ? "UPDATE document_order_line SET blob_key=? WHERE id=?"
      : "UPDATE document_order SET blob_key=? WHERE id=?",
      parameters: [.string(selection.reference.key), .int(persistedID)])
    guard affected == 1 else { throw ReferenceError("BLOB_BIND_DENIED") }
    let entity = child ? "OrderLine" : "Order"
    let action = child ? "Create" : "Update"
    _ = try await SQLiteBlobCatalog().bindOnGraphLease(context, session: session, lease: sql,
      change: BlobBindingChange(target: BlobBindingTarget(entity: entity, entityID: selection.entityID,
        field: "attachment"), next: selection.reference,
        expectedVersion: selection.expectedVersion, nextVersion: selection.nextVersion,
        action: action), authorization: OrderBlobAuthorization(entity: entity,
          entityID: selection.entityID, expectedAction: action))
  }

  func resolveNewBlobSelection(context: UserContext, issued: BoundDocumentSnapshot,
    submitted: SubmittedDocumentCommand, selection: DocumentBlobSelectionClaim,
    sql: any GraphPhysicalSQLLease) async throws -> (rowKey: String, entityID: String) {
    if wrongResolve { return ("order:10", "10") }
    let rows = try await sql.query("""
      SELECT id FROM document_order_line WHERE order_id=? AND client_key=?
      """, parameters: [.int(10), .string(selection.target.targetKey)])
    guard rows.count == 1, let id = rows[0]["id"]?.int64Value else {
      throw ReferenceError("DOCUMENT_PROJECTION_VIOLATION")
    }
    return ("line:\(id)", String(id))
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
    if childEnabled {
      for selection in submitted.blobSelections ?? [] where selection.kind == "NEW_CLIENT_KEY" {
        guard selection.targetEntity == "OrderLine", selection.canonicalField == "attachment",
          ["client-line-1", "client-line-2"].contains(selection.targetKey) else {
          throw ReferenceError("DOCUMENT_PROJECTION_VIOLATION")
        }
        let childID: Int64 = selection.targetKey == "client-line-1" ? 21 : 22
        let inserted = try await sql.execute("""
          INSERT INTO document_order_line(id,order_id,client_key,version,blob_key)
          VALUES (?,?,?,1,NULL)
          """, parameters: [.int(childID), .int(10), .string(selection.targetKey)])
        guard inserted == 1 else { throw ReferenceError("DOCUMENT_PROJECTION_VIOLATION") }
      }
    }
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
      _ = try await sql.execute("""
        CREATE TABLE document_order_line(id INTEGER PRIMARY KEY,order_id INTEGER NOT NULL,
          client_key TEXT UNIQUE NOT NULL,version INTEGER NOT NULL,blob_key TEXT)
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
      for key in ["blob_A", "blob_B", "blob_C", "blob_D"] {
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
  let host = SQLiteOrderHost(blobEnabled: true, childEnabled: true)
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

  func childSelection(_ opened: ContextualDocument, commandID: String,
    clientKey: String, key: String) throws -> DocumentBlobSelectionSubmission {
    let issued = try runtime.consumeBoundDocumentSnapshot(principal,
      token: opened.documentToken, aggregateType: "Order", purpose: "edit-order").document
    let target = BlobSelectionTarget(scope: issued.snapshot.scope, targetEntity: "OrderLine",
      canonicalField: "attachment", kind: "NEW_CLIENT_KEY", targetKey: clientKey,
      commandID: commandID)
    let token = try runtime.issueBlobSelection(principal, documentToken: opened.documentToken,
      claim: BlobSelectionClaim(target: target, reference: BlobRef(key)), lifetimeSeconds: 60)
    return DocumentBlobSelectionSubmission(token: token, targetEntity: "OrderLine",
      canonicalField: "attachment", kind: "NEW_CLIENT_KEY", targetKey: clientKey)
  }
  func childState() async throws -> Bool {
    try await context.executeGraphSave(comment: "inspect new selected child") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let order = try await sql.query("SELECT version,quantity,blob_key FROM document_order", parameters: [])
        let children = try await sql.query("SELECT id,version,blob_key FROM document_order_line ORDER BY id",
          parameters: [])
        let bound = try await sql.query("""
          SELECT key,version FROM teaql_blob_binding WHERE entity='OrderLine' AND entity_id='21'
          """, parameters: [])
        let rejected = try await sql.query("""
          SELECT key FROM teaql_blob_binding WHERE entity='OrderLine' AND entity_id='22'
          """, parameters: [])
        let catalog = try await sql.query("SELECT key,status FROM teaql_blob_catalog ORDER BY key",
          parameters: [])
        let receipts = try await sql.query("SELECT command_id FROM teaql_document_command_receipt",
          parameters: [])
        return order.count == 1 && order[0]["version"]?.int64Value == 3 &&
          order[0]["quantity"]?.int64Value == 3 && order[0]["blob_key"]?.stringValue == "blob_A" &&
          children.count == 1 && children[0]["id"]?.int64Value == 21 &&
          children[0]["version"]?.int64Value == 1 &&
          children[0]["blob_key"]?.stringValue == "blob_C" &&
          bound.count == 1 && bound[0]["key"]?.stringValue == "blob_C" &&
          bound[0]["version"]?.int64Value == 1 && rejected.isEmpty &&
          catalog.first(where: { $0["key"]?.stringValue == "blob_C" })?["status"]?.stringValue == "available" &&
          catalog.first(where: { $0["key"]?.stringValue == "blob_D" })?["status"]?.stringValue == "uploaded_unbound" &&
          receipts.count == 2
      }
    }
  }

  let childOpen = try await service.open(openRequest)
  let childCommand = SubmittedDocumentCommand(businessID: "ORD-10",
    documentToken: childOpen.documentToken, commandID: "command-child-1",
    body: .object(["quantity": .int(3)]), blobSelections: [
      try childSelection(childOpen, commandID: "command-child-1",
        clientKey: "client-line-1", key: "blob_C"),
    ])
  await host.setWrongResolve(true)
  do { _ = try await accept(childCommand); Issue.record("old-row child mapping accepted") }
  catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_PROJECTION_VIOLATION") }
  #expect(try await selectedState())
  await host.setWrongResolve(false)
  let childAccepted = try await accept(childCommand)
  #expect(!childAccepted.replayed && childAccepted.previousRevision == 2 &&
    childAccepted.newRevision == 3)
  #expect(try await accept(childCommand).replayed)
  #expect(try await childState())

  let nextOpen = try await service.open(openRequest)
  let failedChild = SubmittedDocumentCommand(businessID: "ORD-10",
    documentToken: nextOpen.documentToken, commandID: "command-child-2",
    body: .object(["quantity": .int(3)]), blobSelections: [
      try childSelection(nextOpen, commandID: "command-child-2",
        clientKey: "client-line-2", key: "blob_D"),
    ])
  try await context.executeGraphSave(comment: "reject new child receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TRIGGER reject_child_receipt BEFORE INSERT ON teaql_document_command_receipt
        WHEN NEW.command_id='command-child-2'
        BEGIN SELECT RAISE(ABORT, 'receipt rejected'); END
        """, parameters: [])
    }
  }
  do { _ = try await accept(failedChild); Issue.record("failed child receipt committed") }
  catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_CATALOG_FAILED") }
  #expect(try await childState())
}
