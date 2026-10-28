import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct NativeBindingAuthorization: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  let scope: String
  let allowed: Bool
  func scope(for actor: UserContext) throws -> String { scope }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool { allowed }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
}

private actor MultiGraphBindingAuthorization: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  private var denyThirdReference = false
  private var nonNullReferences = 0
  private var visited: [BlobBindingTarget] = []
  private var didDeny = false

  nonisolated func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool {
    visited.append(target)
    if next != nil { nonNullReferences += 1 }
    if denyThirdReference && nonNullReferences == 3 && target.field == "legacy_document" {
      didDeny = true
      return false
    }
    return true
  }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
  func configure(denyThirdReference: Bool) {
    self.denyThirdReference = denyThirdReference
    nonNullReferences = 0
    visited = []
    didDeny = false
  }
  func snapshot() -> (visited: [BlobBindingTarget], denied: Bool) { (visited, didDeny) }
}

private struct NativeReadAuthorization: BlobReadAuthorization {
  func authorize(actor: UserContext, slot: AuthorizedBlobSlot) async throws -> Bool { true }
}

private struct NativeUploadAuthorization: BlobUploadAuthorization {
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func field(for actor: UserContext, target: BlobUploadTarget) throws -> BlobFieldSpec {
    try BlobFieldSpec(entity: "Asset", field: "document", extensions: ["pdf"],
      nullable: true, policyProfile: "default")
  }
  func authorize(actor: UserContext, target: BlobUploadTarget, action: String,
                 input: BlobUploadInput) async throws -> Bool { true }
  func currentOnLease(actor: UserContext, target: BlobUploadTarget, action: String,
                      input: BlobUploadInput, lease: any GraphPhysicalSQLLease)
    async throws -> BlobUploadAuthorizationSnapshot {
    BlobUploadAuthorizationSnapshot(scope: try scope(for: actor),
      field: try field(for: actor, target: target), allowed: true)
  }
}

private struct NativeVerifier: BlobContentVerifier {
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    throw TeaQLError.execution("fixture verifier is not used")
  }
}

@Test
func swiftModeledBlobMutationAutomaticallyBindsInOwnerTransaction() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-native-blob-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let spec = try BlobFieldSpec(entity: "Asset", field: "document", extensions: ["pdf"],
    nullable: true, policyProfile: "default")
  let asset = EntityDescriptor(name: "Asset", table: "native_blob_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "document", type: .blobRef, nullable: true, blobSpec: spec),
  ])
  let control = EntityDescriptor(name: "Control", table: "native_blob_control", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(actor: "alice", queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let upload = try SQLiteBlobUploadService(authorization: NativeUploadAuthorization(),
    verifier: NativeVerifier(), maximumBytes: 1024)
  let module = try BlobReferenceModule(upload: upload, readAuthorization: NativeReadAuthorization(),
    bindingAuthorization: NativeBindingAuthorization(scope: "tenant-a", allowed: true))
  let context = try module.install(on: base)
  try await context.ensureSchema(RuntimeModule(name: "native-blob-test", entities: [asset, control]))
  let first = try BlobRef("blob_native_first")
  let second = try BlobRef("blob_native_second")
  let ledgerRef = try BlobRef("blob_native_ledger")
  try await context.executeGraphSave(comment: "install native Blob catalog") { actor, session in
    try await module.catalog.installSchema(actor, session: session)
    try await actor.withPhysicalSQL(session) { sql in
      for key in [first.key, second.key, ledgerRef.key] {
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_catalog
            (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,
             completed_at_ms,policy_profile,upload_mode,unbound_retention_seconds,effective_unref_seconds)
          VALUES (?,'tenant-a',?,'v1','report.pdf','application/pdf',7,'uploaded_unbound',
            CAST(strftime('%s','now') AS INTEGER)*1000,'default','server_stream',86400,604800)
          """, parameters: [.string(key), .string("objects/\(key)")])
      }
    }
  }
  try await module.ready(context: context)

  try await context.executeGraphSave(comment: "create modeled Blob") { actor, session in
    _ = try await actor.execute(Mutation(kind: .create, entity: asset,
      values: ["id": .int(1), "document": .blobRef(first)],
      auditReason: session.intent.comment))
  }
  try await context.executeGraphSave(comment: "rebind modeled Blob") { actor, session in
    _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(1),
      values: ["document": .blobRef(second)], expectedVersion: 1,
      auditReason: session.intent.comment))
  }
  try await context.executeGraphSave(comment: "clear modeled Blob") { actor, session in
    _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(1),
      values: ["document": .null], expectedVersion: 2,
      auditReason: session.intent.comment))
  }
  try await context.executeGraphSave(comment: "verify clear") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("""
        SELECT b.key,b.version,a.document FROM teaql_blob_binding b
        JOIN native_blob_asset a ON a.id=1
        WHERE b.scope='tenant-a' AND b.entity='Asset' AND b.entity_id='1' AND b.field='document'
        """, parameters: [])
      #expect(rows.count == 1)
      #expect(rows.first?["key"] == .null)
      #expect(rows.first?["version"] == .int(3))
      #expect(rows.first?["document"] == .null)
    }
  }

  let denied = try BlobReferenceModule(upload: upload, readAuthorization: NativeReadAuthorization(),
    bindingAuthorization: NativeBindingAuthorization(scope: "tenant-a", allowed: false))
  let deniedContext = try denied.install(on: base)
  do {
    try await deniedContext.executeGraphSave(comment: "caught revoked binding") { actor, session in
      _ = try await actor.execute(Mutation(kind: .create, entity: control,
        values: ["id": .int(9)], auditReason: session.intent.comment))
      do {
        _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(1),
          values: ["document": .blobRef(first)], expectedVersion: 3,
          auditReason: session.intent.comment))
        Issue.record("revoked binding accepted")
      } catch { }
    }
    Issue.record("caught binding denial committed")
  } catch { #expect(error as? TeaQLError == .execution("GRAPH_TRANSACTION_ROLLBACK_ONLY")) }
  try await context.executeGraphSave(comment: "verify rollback") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let controls = try await sql.query("SELECT id FROM native_blob_control", parameters: [])
      #expect(controls.isEmpty)
      let rows = try await sql.query("SELECT key,version FROM teaql_blob_binding WHERE entity_id='1'",
        parameters: [])
      #expect(rows.first?["key"] == .null)
      #expect(rows.first?["version"] == .int(3))
    }
  }

  do {
    try await context.executeGraphSave(comment: "reject raw Key") { actor, session in
      _ = try await actor.execute(Mutation(kind: .create, entity: asset,
        values: ["id": .int(2), "document": .string(first.key)],
        auditReason: session.intent.comment))
    }
    Issue.record("raw Key accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_REFERENCE_INVALID")) }

  try await context.executeGraphSave(comment: "seed legacy row without binding") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("INSERT INTO native_blob_asset(id,version,document) VALUES (7,1,NULL)",
        parameters: [])
    }
  }
  do {
    try await context.executeGraphSave(comment: "reject missing previous binding") { actor, session in
      _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(7),
        values: ["document": .blobRef(first)], expectedVersion: 1,
        auditReason: session.intent.comment))
    }
    Issue.record("legacy row without binding accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }

  let otherModule = try BlobReferenceModule(upload: upload,
    readAuthorization: NativeReadAuthorization(),
    bindingAuthorization: NativeBindingAuthorization(scope: "tenant-b", allowed: true))
  let otherScope = try otherModule.install(on: base)
  do {
    try await otherScope.executeGraphSave(comment: "reject cross-scope rebind") { actor, session in
      _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(1),
        values: ["document": .blobRef(first)], expectedVersion: 3,
        auditReason: session.intent.comment))
    }
    Issue.record("cross-scope rebind accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }

  try await context.executeGraphSave(comment: "delete modeled Blob") { actor, session in
    _ = try await actor.execute(Mutation(kind: .delete, entity: asset, id: .int(1),
      expectedVersion: 3, auditReason: session.intent.comment))
  }
  try await context.executeGraphSave(comment: "verify delete tombstone") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("""
        SELECT b.key,b.version,a.version AS row_version FROM teaql_blob_binding b
        JOIN native_blob_asset a ON a.id=1 WHERE b.entity_id='1'
        """, parameters: [])
      #expect(rows.first?["key"] == .null)
      #expect(rows.first?["version"] == .int(4))
      #expect(rows.first?["row_version"] == .int(-4))
    }
  }

  func saveAllocated(_ abort: Bool) async throws -> Int64 {
    let ledger = EntityRoot()
    let provisional = EntityKey(entity: "Asset", id: .int(-1))
    ledger.markAsNew(provisional)
    ledger.set(provisional, field: "document", value: .blobRef(ledgerRef))
    return try await context.executeGraphSave(comment: "save allocated ledger Blob") { actor, session in
      let result = try await actor.execute(Mutation(kind: .create, entity: asset,
        values: ledger.change(provisional), auditReason: session.intent.comment),
        ledgerRoot: ledger, ledgerKey: provisional)
      guard case .int(let id) = result.generatedValues["id"], id > 0 else {
        throw TeaQLError.execution("allocated Blob ID missing")
      }
      let actual = EntityKey(entity: "Asset", id: .int(id))
      try ledger.rekey(provisional, to: actual)
      #expect(ledger.isNew(actual))
      #expect(ledger.change(actual)["document"] == .blobRef(ledgerRef))
      if abort { throw TeaQLError.execution("outer owner rejected") }
      return id
    }
  }
  do {
    _ = try await saveAllocated(true)
    Issue.record("outer owner rejection committed the Blob")
  } catch { #expect(error as? TeaQLError == .execution("outer owner rejected")) }
  try await context.executeGraphSave(comment: "inspect allocated rollback") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let business = try await sql.query(
        "SELECT COUNT(*) AS n FROM native_blob_asset WHERE document=?",
        parameters: [.string(ledgerRef.key)])
      let bindings = try await sql.query(
        "SELECT COUNT(*) AS n FROM teaql_blob_binding WHERE key=?",
        parameters: [.string(ledgerRef.key)])
      let catalog = try await sql.query(
        "SELECT status FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(ledgerRef.key)])
      #expect(business.first?["n"] == .int(0))
      #expect(bindings.first?["n"] == .int(0))
      #expect(catalog.first?["status"] == .string("uploaded_unbound"))
    }
  }
  let committedID = try await saveAllocated(false)
  try await context.executeGraphSave(comment: "inspect allocated commit") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let business = try await sql.query(
        "SELECT document FROM native_blob_asset WHERE id=?", parameters: [.int(committedID)])
      let bindings = try await sql.query(
        "SELECT key FROM teaql_blob_binding WHERE entity_id=?",
        parameters: [.string(String(committedID))])
      let catalog = try await sql.query(
        "SELECT status FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(ledgerRef.key)])
      #expect(business.first?["document"] == .string(ledgerRef.key))
      #expect(bindings.first?["key"] == .string(ledgerRef.key))
      #expect(catalog.first?["status"] == .string("available"))
    }
  }

  var generatedRuntime = TeaQLRuntime()
  try generatedRuntime.install(RuntimeModule(name: "native-blob-generated", entities: [asset],
    requiredCapabilities: ["blob.v1"]))
  let generatedBase = UserContext(runtime: generatedRuntime, actor: "alice",
    queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let generatedContext = try module.install(on: generatedBase)
  try await module.ready(context: generatedContext)
}

@Test
func swiftMultiEntityBlobGraphRollsBackLateDenialAndOuterRejection() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-multi-blob-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let document = try BlobFieldSpec(entity: "Asset", field: "document", extensions: ["pdf"],
    nullable: true, policyProfile: "default")
  let legacy = try BlobFieldSpec(entity: "Asset", field: "legacy_document", extensions: ["pdf"],
    nullable: true, policyProfile: "default")
  let asset = EntityDescriptor(name: "Asset", table: "multi_blob_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "document", type: .blobRef, nullable: true, blobSpec: document),
    PropertyDescriptor(name: "legacy_document", type: .blobRef, nullable: true, blobSpec: legacy),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(actor: "alice", queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let upload = try SQLiteBlobUploadService(authorization: NativeUploadAuthorization(),
    verifier: NativeVerifier(), maximumBytes: 1024)
  let permission = MultiGraphBindingAuthorization()
  let module = try BlobReferenceModule(upload: upload, readAuthorization: NativeReadAuthorization(),
    bindingAuthorization: permission)
  let context = try module.install(on: base)
  try await context.ensureSchema(RuntimeModule(name: "multi-blob-test", entities: [asset]))
  let references = try [BlobRef("blob_multi_first"), BlobRef("blob_multi_second"),
    BlobRef("blob_multi_third")]
  try await context.executeGraphSave(comment: "install multi-Blob catalog") { actor, session in
    try await module.catalog.installSchema(actor, session: session)
    try await actor.withPhysicalSQL(session) { sql in
      for key in references.map(\.key) {
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_catalog
            (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,
             completed_at_ms,policy_profile,upload_mode,unbound_retention_seconds,effective_unref_seconds)
          VALUES (?,'tenant-a',?,'v1','report.pdf','application/pdf',7,'uploaded_unbound',
            CAST(strftime('%s','now') AS INTEGER)*1000,'default','server_stream',86400,604800)
          """, parameters: [.string(key), .string("objects/\(key)")])
      }
    }
  }
  try await module.ready(context: context)

  func save(denyThird: Bool = false, outerReject: Bool = false) async throws -> [Int64] {
    await permission.configure(denyThirdReference: denyThird)
    let ledger = EntityRoot()
    let provisional = [EntityKey(entity: "Asset", id: .int(-1)),
      EntityKey(entity: "Asset", id: .int(-2))]
    provisional.forEach { ledger.markAsNew($0) }
    ledger.set(provisional[0], field: "document", value: .blobRef(references[0]))
    ledger.set(provisional[1], field: "document", value: .blobRef(references[1]))
    ledger.set(provisional[1], field: "legacy_document", value: .blobRef(references[2]))
    return try await context.executeGraphSave(comment: "save multi-entity Blob graph") { actor, session in
      var ids: [Int64] = []
      for (index, key) in provisional.enumerated() {
        let result: MutationResult
        do {
          result = try await actor.execute(Mutation(kind: .create, entity: asset,
            values: ledger.change(key), auditReason: session.intent.comment),
            ledgerRoot: ledger, ledgerKey: key)
        } catch {
          if denyThird { return ids } // Caught denial must still poison the owner.
          throw error
        }
        guard case .int(let id) = result.generatedValues["id"], id > 0 else {
          throw TeaQLError.execution("allocated Blob ID missing")
        }
        let actual = EntityKey(entity: "Asset", id: .int(id))
        try ledger.rekey(key, to: actual)
        #expect(ledger.isNew(actual))
        #expect(ledger.change(actual)["document"] == .blobRef(references[index]))
        ids.append(id)
      }
      if outerReject { throw TeaQLError.execution("outer owner rejected") }
      return ids
    }
  }

  func assertRolledBack() async throws {
    try await context.executeGraphSave(comment: "inspect multi-Blob rollback") { actor, session in
      try await actor.withPhysicalSQL(session) { sql in
        let rows = try await sql.query("SELECT COUNT(*) AS n FROM multi_blob_asset", parameters: [])
        let bindings = try await sql.query("SELECT COUNT(*) AS n FROM teaql_blob_binding", parameters: [])
        let catalog = try await sql.query("SELECT COUNT(*) AS n FROM teaql_blob_catalog " +
          "WHERE status='uploaded_unbound'", parameters: [])
        #expect(rows.first?["n"] == .int(0))
        #expect(bindings.first?["n"] == .int(0))
        #expect(catalog.first?["n"] == .int(3))
      }
    }
  }

  do {
    _ = try await save(denyThird: true)
    Issue.record("caught third-reference denial committed")
  } catch { #expect(error as? TeaQLError == .execution("GRAPH_TRANSACTION_ROLLBACK_ONLY")) }
  let denied = await permission.snapshot()
  #expect(denied.denied)
  #expect(denied.visited.map(\.field) ==
    ["document", "legacy_document", "document", "legacy_document"])
  #expect(denied.visited.count == 4 && denied.visited[0].entityID != denied.visited[2].entityID)
  try await assertRolledBack()

  do {
    _ = try await save(outerReject: true)
    Issue.record("outer owner rejection committed the multi-Blob graph")
  } catch { #expect(error as? TeaQLError == .execution("outer owner rejected")) }
  try await assertRolledBack()

  let committed = try await save()
  #expect(committed.count == 2)
  let accepted = await permission.snapshot()
  #expect(accepted.visited.map(\.field) ==
    ["document", "legacy_document", "document", "legacy_document"])
  try await context.executeGraphSave(comment: "inspect multi-Blob commit") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query(
        "SELECT id,document,legacy_document FROM multi_blob_asset ORDER BY id", parameters: [])
      #expect(rows.count == 2)
      #expect(rows[0]["id"] == .int(committed[0]))
      #expect(rows[0]["document"] == .string(references[0].key))
      #expect(rows[0]["legacy_document"] == .null)
      #expect(rows[1]["id"] == .int(committed[1]))
      #expect(rows[1]["document"] == .string(references[1].key))
      #expect(rows[1]["legacy_document"] == .string(references[2].key))
      let bindings = try await sql.query(
        "SELECT entity_id,field,key FROM teaql_blob_binding ORDER BY entity_id,field",
        parameters: [])
      #expect(bindings.count == 4)
      #expect(bindings[0]["key"] == .string(references[0].key))
      #expect(bindings[1]["key"] == .null)
      #expect(bindings[2]["key"] == .string(references[1].key))
      #expect(bindings[3]["key"] == .string(references[2].key))
      let catalog = try await sql.query("SELECT key,status FROM teaql_blob_catalog ORDER BY key",
        parameters: [])
      #expect(catalog.count == 3)
      for (index, reference) in references.enumerated() {
        #expect(catalog[index]["key"] == .string(reference.key))
        #expect(catalog[index]["status"] == .string("available"))
      }
    }
  }
}
