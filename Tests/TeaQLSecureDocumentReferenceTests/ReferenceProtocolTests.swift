import Crypto
import Foundation
import TeaQLCore
import TeaQLSecureDocumentReference
import TeaQLSQLite
import Testing

private let rustTQR1 = "tqr1.k2.MzMzMzMzMzMzMzMzmhCET15vBdSc1BbFJcrvMMnRP1wAyjunShYlFPnDZL7Gk5V1LuptWyrbiQ8LQSDHFUmN3o6vb-MEgXZuh3N-YkeO55CYLeVgiyBBYslzuSu-fvWC2KMZcnZ5D8BRmWpGYA2Ok5sWe1Fg1aIyadTjVoKB-H2vPW_0okj-"

@Test
func tqr1MatchesRustAndRejectsForeignContext() throws {
  let keys = try StaticReferenceKeyProvider(current: "k2", keys: [
    ReferenceKey(keyID: "k1", masterKey: Array(repeating: 0x11, count: 32)),
    ReferenceKey(keyID: "k2", masterKey: Array(repeating: 0x22, count: 32)),
  ])
  let runtime = try ContextBoundReferenceRuntime(service: "order-service", environment: "test-a",
    keys: keys, authorize: { actor, _, identity in
      actor.subject == "alice" && identity.entityType == "OrderItem" && identity.id == 42
    }, now: { Date(timeIntervalSince1970: 1_790_467_200) },
    nonce: { Array(repeating: 0x33, count: 12) })
  let actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Platform", domainRootID: 7)
  let scope = ReferenceDocumentScope(documentID: "doc-100", purpose: "edit-order",
    aggregateType: "Order", aggregateID: 100, aggregateRevision: 9)
  let identity = ReferenceIdentity(entityType: "OrderItem", id: 42, version: 3)
  let token = try runtime.issue(actor, scope: scope, identity: identity, lifetimeSeconds: 600)
  #expect(token == rustTQR1)
  #expect(try runtime.consume(actor, scope: scope, token: rustTQR1,
    expectedEntityType: "OrderItem").identity == identity)
  let bob = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "bob",
    domainRootType: "Platform", domainRootID: 7)
  do {
    _ = try runtime.consume(bob, scope: scope, token: token, expectedEntityType: "OrderItem")
    Issue.record("foreign actor consumed tqr1")
  } catch { #expect((error as? ReferenceError)?.code == "ROUND_TRIP_REFERENCE_SCOPE_MISMATCH") }
  do {
    _ = try runtime.consume(actor, scope: scope, token: token + "=", expectedEntityType: "OrderItem")
    Issue.record("noncanonical token consumed")
  } catch { #expect((error as? ReferenceError)?.code == "ROUND_TRIP_REFERENCE_INVALID") }
}

private func documentFixture() throws -> (ContextBoundReferenceRuntime, TrustedReferencePrincipal, DocumentSnapshot) {
  let keys = try StaticReferenceKeyProvider(current: "k1", keys: [
    ReferenceKey(keyID: "k1", masterKey: Array(repeating: 0x42, count: 32)),
  ])
  let runtime = try ContextBoundReferenceRuntime(service: "order-service", environment: "test",
    keys: keys, authorize: { _, _, _ in true },
    now: { Date(timeIntervalSince1970: 1_800_000_000) },
    nonce: { Array(repeating: 0x33, count: 12) })
  let actor = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "alice",
    domainRootType: "Merchant", domainRootID: 7)
  let scope = ReferenceDocumentScope(documentID: "doc-1", purpose: "edit-order",
    aggregateType: "Order", aggregateID: 10, aggregateRevision: 4)
  let snapshot = DocumentSnapshot(modelFingerprint: "model-v1", businessID: "ORD-X1",
    scope: scope, aggregate: ReferenceIdentity(entityType: "Order", id: 10, version: 4),
    entities: [DocumentEntitySnapshot(rowKey: "item:0",
      identity: ReferenceIdentity(entityType: "OrderItem", id: 20, version: 2),
      loadedFields: ["product_code", "quantity"], writableFields: ["quantity"],
      allowedMutations: ["UPDATE"])],
    relations: [DocumentRelationSnapshot(name: "items", rowKeys: ["item:0"],
      completeness: "COMPLETE", writable: true,
      allowedMutations: ["CREATE_CHILD", "REMOVE_CHILD"])])
  return (runtime, actor, snapshot)
}
private func sha(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test
func tqd1MatchesRustDocumentHash() throws {
  let (runtime, actor, snapshot) = try documentFixture()
  let token = try runtime.issueDocumentSnapshot(actor, snapshot: snapshot, lifetimeSeconds: 600)
  #expect(sha(token) == "69fee1ec01cd4a5b69dd3f795aeaffb3a3546e50d48e25cfc9b8f169a527b267")
  #expect(try runtime.consumeDocumentSnapshot(actor, token: token, aggregateType: "Order",
    purpose: "edit-order").document == snapshot)
  let bob = TrustedReferencePrincipal(authenticationRealm: "oidc", subject: "bob",
    domainRootType: "Merchant", domainRootID: 7)
  do {
    _ = try runtime.consumeDocumentSnapshot(bob, token: token, aggregateType: "Order", purpose: "edit-order")
    Issue.record("foreign actor consumed tqd1")
  } catch { #expect((error as? ReferenceError)?.code == "ROUND_TRIP_REFERENCE_SCOPE_MISMATCH") }
}

@Test
func tqd2AndTqs1MatchJavaRustHashes() throws {
  let (runtime, actor, original) = try documentFixture()
  let entity = original.entities[0]
  let snapshot = DocumentSnapshot(modelFingerprint: original.modelFingerprint, businessID: original.businessID,
    scope: original.scope, aggregate: original.aggregate,
    entities: [DocumentEntitySnapshot(rowKey: entity.rowKey, identity: entity.identity,
      loadedFields: ["attachment", "product_code", "quantity"], writableFields: ["attachment", "quantity"],
      allowedMutations: entity.allowedMutations)], relations: original.relations)
  let document = BoundDocumentSnapshot(snapshot: snapshot, bindings: [
    DocumentBlobBindingSnapshot(rowKey: "item:0", canonicalField: "attachment",
      entityType: "OrderItem", reference: try BlobRef("blob_A"), bindingVersion: UInt64.max,
      nullable: true, writable: true),
  ])
  let token = try runtime.issueBoundDocumentSnapshot(actor, document: document, lifetimeSeconds: 300)
  #expect(sha(token) == "e7c81ca089b0a3e0585faefcc275aeb44b456d666d9a4a17949c92b1891089d7")
  #expect(try runtime.consumeBoundDocumentSnapshot(actor, token: token, aggregateType: "Order",
    purpose: "edit-order").document == document)
  let target = BlobSelectionTarget(scope: snapshot.scope, targetEntity: "OrderItem", canonicalField: "attachment",
    kind: "EXISTING_ROW", targetKey: "item:0", commandID: "command-1")
  let claim = BlobSelectionClaim(target: target, reference: try BlobRef("blob_B"))
  let selection = try runtime.issueBlobSelection(actor, documentToken: token, claim: claim, lifetimeSeconds: 120)
  #expect(sha(selection) == "31303e3e251dd0e8963bf2a4d8897d1eccde63a485aaf287f88f29d40757ba96")
  #expect(try runtime.consumeBlobSelection(actor, documentToken: token,
    token: selection, expectedTarget: target).document == claim)
  let wrongTarget = BlobSelectionTarget(scope: snapshot.scope, targetEntity: "OrderItem",
    canonicalField: "attachment", kind: "EXISTING_ROW", targetKey: "item:0", commandID: "other-command")
  do {
    _ = try runtime.consumeBlobSelection(actor, documentToken: token, token: selection,
      expectedTarget: wrongTarget)
    Issue.record("wrong command consumed tqs1")
  } catch { #expect((error as? ReferenceError)?.code == "ROUND_TRIP_REFERENCE_SCOPE_MISMATCH") }
}

private struct SnapshotAssembly: SecureDocumentAssembly {
  let actor: TrustedReferencePrincipal
  let document: BoundDocumentSnapshot
  func principal(context: UserContext) throws -> TrustedReferencePrincipal { actor }
  func snapshot(context: UserContext, graph: AuthorizedResponseGraph) async throws -> PreparedBoundDocument {
    PreparedBoundDocument(document: document, lifetimeSeconds: 300)
  }
}

private struct SecureSyntheticReadiness: RuntimeCapabilityProvider {
  func checkReady(context: UserContext) async throws {}
}

@Test(arguments: ["foreign-module", "synthetic-capability"])
func swiftSecureModuleReadyRejectsUnrelatedInstallation(scenario: String) async throws {
  let (runtime, principal, snapshot) = try documentFixture()
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  let module = SecureDocumentReferenceModule(runtime: runtime)
  let foreign = SecureDocumentReferenceModule(runtime: runtime)
  let context = try module.install(on: base, assembly: SnapshotAssembly(actor: principal,
    document: BoundDocumentSnapshot(snapshot: snapshot, bindings: [])))
  try await module.ready(context: context)
  let copy = module
  try await copy.ready(context: context)
  let candidate = scenario == "foreign-module" ? foreign : module
  let target = scenario == "synthetic-capability"
    ? context.withRuntimeCapability("secure_document.v1", provider: SecureSyntheticReadiness()) : context
  do {
    try await candidate.ready(context: target)
    Issue.record("unrelated Secure module installation was accepted")
  } catch { #expect((error as? ViewPreparationError)?.code == "DOCUMENT_CONFIGURATION") }
}
private struct GraphAuthorizer: ResponseGraphAuthorizer {
  let slot: AuthorizedBlobSlot
  func authorize(context: UserContext, result: any Sendable, options: ViewOptions)
    async throws -> AuthorizedResponseGraph {
    AuthorizedResponseGraph(presentation: .object(["attachment": .blob(slot.reference)]), blobSlots: [slot])
  }
}
private struct URLContributor: BlobResponseContributor {
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph, expiresAt: Date?)
    async throws -> [ProjectedBlobURL] {
    [ProjectedBlobURL(url: "https://files.example.invalid/document",
      expiresAt: Date().addingTimeInterval(60))]
  }
}

@Test
func secureModuleRejectsWrongEncryptedBindingBeforeURLProjection() async throws {
  let (runtime, actor, original) = try documentFixture()
  let row = original.entities[0]
  let snapshot = DocumentSnapshot(modelFingerprint: original.modelFingerprint, businessID: original.businessID,
    scope: original.scope, aggregate: original.aggregate,
    entities: [DocumentEntitySnapshot(rowKey: row.rowKey, identity: row.identity,
      loadedFields: ["attachment", "product_code", "quantity"], writableFields: ["attachment", "quantity"],
      allowedMutations: row.allowedMutations)], relations: original.relations)
  let reference = try BlobRef("blob_A")
  let document = BoundDocumentSnapshot(snapshot: snapshot, bindings: [
    DocumentBlobBindingSnapshot(rowKey: "item:0", canonicalField: "attachment", entityType: "OrderItem",
      reference: reference, bindingVersion: 4, nullable: true, writable: true),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  let module = SecureDocumentReferenceModule(runtime: runtime)
  let installed = try module.install(on: base, assembly: SnapshotAssembly(actor: actor, document: document))
  try await module.ready(context: installed)
  let slot = AuthorizedBlobSlot(path: [.field("attachment")], entity: "OrderItem", entityID: "20",
    field: "attachment", scope: "tenant-a", bindingVersion: 4, reference: reference)
  let context = installed.withResponseGraphAuthorizer(GraphAuthorizer(slot: slot))
    .withBlobResponseContributor(URLContributor())
  let view = try await ViewPreparationService().prepare(context: context, result: ViewValue.null,
    options: ViewOptions(mode: .governed, businessOutcome: .committed))
  guard case .object(let body) = view.presentation,
    body["attachment"] == .string("https://files.example.invalid/document"),
    case .object(let envelope)? = view.document,
    envelope["businessId"] == .string("ORD-X1"),
    case .string(let token)? = envelope["documentToken"] else {
    Issue.record("governed view omitted URL or document token")
    return
  }
  #expect(try runtime.consumeBoundDocumentSnapshot(actor, token: token,
    aggregateType: "Order", purpose: "edit-order").document == document)
  let wrongSlot = AuthorizedBlobSlot(path: [.field("attachment")], entity: "OrderItem", entityID: "20",
    field: "attachment", scope: "tenant-a", bindingVersion: 5, reference: reference)
  let wrong = installed.withResponseGraphAuthorizer(GraphAuthorizer(slot: wrongSlot))
    .withBlobResponseContributor(URLContributor())
  do {
    _ = try await ViewPreparationService().prepare(context: wrong, result: ViewValue.null,
      options: ViewOptions(mode: .governed, businessOutcome: .committed))
    Issue.record("wrong Blob binding version prepared")
  } catch {
    #expect((error as? ViewPreparationError)?.code == "DOCUMENT_PROJECTION_VIOLATION")
    #expect((error as? ViewPreparationError)?.businessState == "committed")
  }
}


private func surfaceDocument(_ original: DocumentSnapshot, scenario: String = "valid") throws -> BoundDocumentSnapshot {
  let first = original.entities[0]
  var loaded = ["attachment", "product_code", "quantity"], writable = ["attachment", "quantity"]
  var rowKeys = ["item:0"], complete = "COMPLETE", relationWritable = true
  var relationMutations = ["CREATE_CHILD", "REMOVE_CHILD"], bindingWritable = true, bindingEntity = "OrderItem"
  switch scenario {
  case "writable-unloaded": writable = ["hidden"]
  case "orphan-relation": rowKeys = ["absent"]
  case "duplicate-relation-row": rowKeys = ["item:0", "item:0"]
  case "readonly-relation-mutation": relationWritable = false
  case "binding-unloaded": loaded = ["quantity"]; writable = ["quantity"]; bindingWritable = false
  case "binding-readonly": writable = ["quantity"]
  case "binding-foreign-entity": bindingEntity = "OtherItem"
  case "readonly-existing": writable = ["quantity"]; bindingWritable = false
  case "partial-child": complete = "PARTIAL"
  case "readonly-child": relationWritable = false; relationMutations = []
  case "no-create-child": relationMutations = ["REMOVE_CHILD"]
  default: break
  }
  let row = DocumentEntitySnapshot(rowKey: first.rowKey, identity: first.identity,
    loadedFields: loaded, writableFields: writable, allowedMutations: first.allowedMutations)
  let snapshot = DocumentSnapshot(modelFingerprint: original.modelFingerprint, businessID: original.businessID,
    scope: original.scope, aggregate: original.aggregate,
    entities: scenario == "duplicate-row" ? [row, row] : [row],
    relations: [DocumentRelationSnapshot(name: "items", rowKeys: rowKeys, completeness: complete,
      writable: relationWritable, allowedMutations: relationMutations)])
  let binding = DocumentBlobBindingSnapshot(rowKey: "item:0", canonicalField: "attachment", entityType: bindingEntity,
    reference: try BlobRef("blob_A"), bindingVersion: 4, nullable: true, writable: bindingWritable)
  return BoundDocumentSnapshot(snapshot: snapshot, bindings: scenario == "duplicate-binding" ? [binding, binding] : [binding])
}

@Test(arguments: ["writable-unloaded", "duplicate-row", "orphan-relation", "duplicate-relation-row",
  "readonly-relation-mutation", "binding-unloaded", "binding-readonly", "binding-foreign-entity", "duplicate-binding"])
func swiftIssuedProjectionRejectsInconsistentSnapshot(scenario: String) throws {
  let (runtime, actor, original) = try documentFixture()
  let d = try surfaceDocument(original, scenario: scenario)
  do {
    _ = try runtime.issueBoundDocumentSnapshot(actor, document: d, lifetimeSeconds: 60)
    Issue.record("inconsistent issued snapshot accepted")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_PROJECTION_VIOLATION") }
}

@Test(arguments: ["readonly-existing", "hidden-existing", "partial-child", "readonly-child", "no-create-child"])
func swiftSelectionCannotExpandIssuedSurface(scenario: String) throws {
  let (runtime, actor, original) = try documentFixture()
  let d = try surfaceDocument(original, scenario: scenario)
  let token = try runtime.issueBoundDocumentSnapshot(actor, document: d, lifetimeSeconds: 60)
  #expect(try runtime.consumeBoundDocumentSnapshot(actor, token: token, aggregateType: "Order", purpose: "edit-order").document == d)
  let child = scenario.hasSuffix("child")
  let target = BlobSelectionTarget(scope: d.snapshot.scope, targetEntity: "OrderItem",
    canonicalField: scenario == "hidden-existing" ? "hidden_attachment" : "attachment",
    kind: child ? "NEW_CLIENT_KEY" : "EXISTING_ROW", targetKey: child ? "client-hidden" : "item:0", commandID: "command-1")
  do {
    _ = try runtime.issueBlobSelection(actor, documentToken: token,
      claim: BlobSelectionClaim(target: target, reference: try BlobRef("blob_B")), lifetimeSeconds: 30)
    Issue.record("selection expanded issued surface")
  } catch { #expect((error as? ReferenceError)?.code == "DOCUMENT_PROJECTION_VIOLATION") }
}

private struct SurfaceAssembly: SecureDocumentAssembly {
  let actor: TrustedReferencePrincipal
  let document: BoundDocumentSnapshot
  func principal(context: UserContext) throws -> TrustedReferencePrincipal { actor }
  func snapshot(context: UserContext, graph: AuthorizedResponseGraph) async throws -> PreparedBoundDocument {
    PreparedBoundDocument(document: document, lifetimeSeconds: 60)
  }
}
private struct SurfaceSigner: BlobResponseContributor {
  let deadline: Date
  let late: Bool
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph, expiresAt: Date?) async throws -> [ProjectedBlobURL] {
    #expect(expiresAt == deadline)
    #expect(graph.blobSlots.map { $0.reference.key } == ["blob_A"])
    #expect(graph.presentation == .object(["attachment": .blob(try BlobRef("blob_A"))]))
    return [ProjectedBlobURL(url: "https://files.example.invalid/asset",
      expiresAt: deadline.addingTimeInterval(late ? 0.001 : -5))]
  }
}
@Test
func swiftGovernedViewHidesBlobAndBoundsURLByDocumentDeadline() async throws {
  let (_, actor, original) = try documentFixture()
  let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), deadline = now.addingTimeInterval(60)
  let keys = try StaticReferenceKeyProvider(current: "k1", keys: [ReferenceKey(keyID: "k1", masterKey: Array(repeating: 0x42, count: 32))])
  let runtime = try ContextBoundReferenceRuntime(service: "order-service", environment: "test", keys: keys,
    authorize: { _, _, _ in true }, now: { now }, nonce: { Array(repeating: 0x33, count: 12) })
  let module = SecureDocumentReferenceModule(runtime: runtime)
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(queryExecutor: database, mutationExecutor: database, requestPolicy: RequestPolicy { $0 })
  let installed = try module.install(on: base, assembly: SurfaceAssembly(actor: actor, document: try surfaceDocument(original)))
  let visible = try BlobRef("blob_A"), hidden = try BlobRef("blob_hidden")
  let source = ViewValue.object(["attachment": .blob(visible), "hidden_attachment": .blob(hidden)])
  let slot = AuthorizedBlobSlot(path: [.field("attachment")], entity: "OrderItem", entityID: "20", field: "attachment",
    scope: "tenant-a", bindingVersion: 4, reference: visible)
  let authorized = installed.withResponseGraphAuthorizer(GraphAuthorizer(slot: slot))
  let options = ViewOptions(mode: .governed, businessOutcome: .committed, expiresAt: now.addingTimeInterval(120))
  let view = try await ViewPreparationService().prepare(context: authorized.withBlobResponseContributor(SurfaceSigner(deadline: deadline, late: false)), result: source, options: options)
  #expect(view.presentation == .object(["attachment": .string("https://files.example.invalid/asset")]))
  #expect(view.expiresAt == deadline.addingTimeInterval(-5))
  #expect(source == .object(["attachment": .blob(visible), "hidden_attachment": .blob(hidden)]))
  do {
    _ = try await ViewPreparationService().prepare(context: authorized.withBlobResponseContributor(SurfaceSigner(deadline: deadline, late: true)), result: source, options: options)
    Issue.record("URL beyond actual document deadline accepted")
  } catch {
    #expect((error as? ViewPreparationError)?.code == "BLOB_SIGN_FAILED")
    #expect((error as? ViewPreparationError)?.businessState == "committed")
    #expect((error as? ViewPreparationError)?.retry == "read")
  }
}
