import Crypto
import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct NativeBindingAuthorization: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  let scope: String
  let allowed: Bool
  var policy: BlobRetentionPolicy? = nil
  func scope(for actor: UserContext) throws -> String { scope }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool { allowed }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    if let policy { return policy }
    return try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
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

private struct NativeUploadAuthorization: BlobUploadAuthorization, BlobUploadPolicyAuthorization {
  var policy: BlobRetentionPolicy? = nil
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
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobUploadTarget) async throws -> BlobRetentionPolicy {
    if let policy { return policy }
    return try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
}

private struct NativeFixturePDFVerifier: BlobContentVerifier {
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    var data = Data()
    while true {
      let chunk = try await reader.read(upToCount: 4096)
      if chunk.isEmpty { break }
      data.append(chunk)
      guard Int64(data.count) <= maximumBytes else { throw TeaQLError.execution("invalid fixture") }
    }
    guard ext == "pdf", data.starts(with: Data("%PDF-".utf8)),
      String(data: data, encoding: .utf8)?.contains("%%EOF") == true else {
      throw TeaQLError.execution("invalid fixture")
    }
    return BlobVerifiedContent(sizeBytes: Int64(data.count),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      contentType: "application/pdf")
  }
}

private struct NativeMaintenancePermission: BlobMaintenanceAuthorization {
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func canMaintain(actor: UserContext, scope: String) async throws -> Bool { true }
}

private final class NativeSharedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_700_000_000)
  func now() -> Date { lock.withLock { date } }
  func advance(_ interval: TimeInterval) { lock.withLock { date = date.addingTimeInterval(interval) } }
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
    PropertyDescriptor(name: "caption", type: .string, nullable: true),
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

  try await context.executeGraphSave(comment: "seed non-null orphan without binding") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("INSERT INTO native_blob_asset(id,version,document) VALUES (7,1,?)",
        parameters: [.string(first.key)])
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

  let bindingBefore = try await context.executeGraphSave(comment: "snapshot omitted Blob binding") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      try await sql.query("SELECT * FROM teaql_blob_binding WHERE entity_id=?",
        parameters: [.string(String(committedID))])
    }
  }
  let catalogBefore = try await context.executeGraphSave(comment: "snapshot omitted Blob catalog") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      try await sql.query("SELECT * FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(ledgerRef.key)])
    }
  }
  let partial = EntityRoot()
  let partialKey = EntityKey(entity: "Asset", id: .int(committedID))
  partial.set(partialKey, field: "caption", value: .string("after"))
  #expect(partial.change(partialKey)["document"] == nil)
  try await context.executeGraphSave(comment: "update caption with unloaded Blob") { actor, session in
    _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(committedID),
      values: partial.change(partialKey), expectedVersion: 1, auditReason: session.intent.comment),
      ledgerRoot: partial, ledgerKey: partialKey)
  }
  try await context.executeGraphSave(comment: "verify omitted Blob unchanged") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let business = try await sql.query(
        "SELECT document,caption,version FROM native_blob_asset WHERE id=?",
        parameters: [.int(committedID)])
      #expect(business.first?["document"] == .string(ledgerRef.key))
      #expect(business.first?["caption"] == .string("after"))
      #expect(business.first?["version"] == .int(2))
      let bindings = try await sql.query("SELECT * FROM teaql_blob_binding WHERE entity_id=?",
        parameters: [.string(String(committedID))])
      let catalog = try await sql.query("SELECT * FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(ledgerRef.key)])
      #expect(bindings == bindingBefore)
      #expect(catalog == catalogBefore)
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
func swiftNativeSharedBlobFinalUnbindRetainsRealFileUntilDeadline() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-shared-blob-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? file.close() }
  let spec = try BlobFieldSpec(entity: "Asset", field: "document", extensions: ["pdf"],
    nullable: true, policyProfile: "default")
  let asset = EntityDescriptor(name: "Asset", table: "shared_blob_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "document", type: .blobRef, nullable: true, blobSpec: spec),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(actor: "alice", queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(file)
  let clock = NativeSharedClock()
  let policy = try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
    unboundRetentionSeconds: 10, unreferencedRetentionSeconds: 20,
    minimumRetentionSeconds: 0)
  let catalog = SQLiteBlobCatalog(now: { clock.now() })
  let upload = try SQLiteBlobUploadService(authorization: NativeUploadAuthorization(policy: policy),
    verifier: NativeFixturePDFVerifier(), maximumBytes: 1024, now: { clock.now() })
  let maintenance = try SQLiteBlobMaintenanceService(catalog: catalog,
    authorization: NativeMaintenancePermission(), now: { clock.now() })
  let module = try BlobReferenceModule(catalog: catalog, upload: upload,
    readAuthorization: NativeReadAuthorization(),
    bindingAuthorization: NativeBindingAuthorization(scope: "tenant-a", allowed: true,
      policy: policy), maintenance: maintenance)
  let context = try module.install(on: base)
  try await context.ensureSchema(RuntimeModule(name: "shared-blob-test", entities: [asset]))
  try await context.executeGraphSave(comment: "install shared Blob catalog") { actor, session in
    try await catalog.installSchema(actor, session: session)
  }
  try await module.ready(context: context)

  let bytes = Data("%PDF-1.7\nshared native graph\n%%EOF".utf8)
  let uploadSession = try await upload.begin(context,
    target: BlobUploadTarget(entity: "Asset", entityID: "1", field: "document"),
    input: BlobUploadInput(fileName: "shared.pdf", declaredSize: Int64(bytes.count),
      declaredContentType: "application/pdf"), replayKey: "shared-native")
  #expect(try await upload.write(context, uploadID: uploadSession.uploadID,
    source: ObjectDataReader(bytes)) == Int64(bytes.count))
  let reference = try await upload.complete(context, uploadID: uploadSession.uploadID)
  #expect(reference == uploadSession.reference)
  let objectKey = try await context.executeGraphSave(comment: "inspect shared object key") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT object_key FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(reference.key)])
      return try ObjectKey(#require(rows.first?["object_key"]?.stringValue))
    }
  }
  let storage = try context.objectStorage("shared native graph")
  #expect(try await storage.head(objectKey) != nil)

  let ledger = EntityRoot()
  let provisional = [EntityKey(entity: "Asset", id: .int(-1)),
    EntityKey(entity: "Asset", id: .int(-2))]
  for key in provisional {
    ledger.markAsNew(key)
    ledger.set(key, field: "document", value: .blobRef(reference))
  }
  let ids = try await context.executeGraphSave(comment: "bind shared native Blob") { actor, session in
    var allocated: [Int64] = []
    for key in provisional {
      let result = try await actor.execute(Mutation(kind: .create, entity: asset,
        values: ledger.change(key), auditReason: session.intent.comment),
        ledgerRoot: ledger, ledgerKey: key)
      guard case .int(let id) = result.generatedValues["id"], id > 0 else {
        throw TeaQLError.execution("allocated Blob ID missing")
      }
      try ledger.rekey(key, to: EntityKey(entity: "Asset", id: .int(id)))
      allocated.append(id)
    }
    return allocated
  }
  #expect(ids.count == 2 && ids[0] != ids[1])

  func snapshot() async throws -> (String, Int64?, Int64) {
    try await context.executeGraphSave(comment: "inspect shared native Blob") { actor, session in
      try await actor.withPhysicalSQL(session) { sql in
        let catalogRows = try await sql.query(
          "SELECT status,last_unbound_at_ms FROM teaql_blob_catalog WHERE key=?",
          parameters: [.string(reference.key)])
        let bindingRows = try await sql.query(
          "SELECT COUNT(*) AS n FROM teaql_blob_binding WHERE key=?",
          parameters: [.string(reference.key)])
        return (try #require(catalogRows.first?["status"]?.stringValue),
          catalogRows.first?["last_unbound_at_ms"]?.int64Value,
          try #require(bindingRows.first?["n"]?.int64Value))
      }
    }
  }
  let bound = try await snapshot()
  #expect(bound.0 == "available" && bound.1 == nil && bound.2 == 2)

  func unbind(_ id: Int64, rejectOuter: Bool = false) async throws {
    try await context.executeGraphSave(comment: "unbind shared native Blob") { actor, session in
      _ = try await actor.execute(Mutation(kind: .update, entity: asset, id: .int(id),
        values: ["document": .null], expectedVersion: 1,
        auditReason: session.intent.comment))
      if rejectOuter { throw TeaQLError.execution("outer owner rejected final unbind") }
    }
  }
  try await unbind(ids[0])
  let firstUnbound = try await snapshot()
  #expect(firstUnbound.0 == "available" && firstUnbound.1 == nil && firstUnbound.2 == 1)
  clock.advance(40)
  #expect(try await maintenance.runBatch(context).outcomes.isEmpty)
  #expect(try await storage.head(objectKey) != nil)

  do {
    try await unbind(ids[1], rejectOuter: true)
    Issue.record("outer owner committed final unbind")
  } catch { #expect(error as? TeaQLError == .execution("outer owner rejected final unbind")) }
  let rolledBack = try await snapshot()
  #expect(rolledBack.0 == "available" && rolledBack.1 == nil && rolledBack.2 == 1)
  try await context.executeGraphSave(comment: "inspect rejected final unbind") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT document FROM shared_blob_asset WHERE id=?",
        parameters: [.int(ids[1])])
      #expect(rows.first?["document"] == .string(reference.key))
    }
  }
  #expect(try await maintenance.runBatch(context).outcomes.isEmpty)
  #expect(try await storage.head(objectKey) != nil)

  try await unbind(ids[1])
  let final = try await snapshot()
  #expect(final.0 == "available" && final.1 == Int64(clock.now().timeIntervalSince1970 * 1000)
    && final.2 == 0)
  clock.advance(19.999)
  #expect(try await maintenance.runBatch(context).outcomes.isEmpty)
  #expect(try await storage.head(objectKey) != nil)
  clock.advance(0.001)
  let deletion = try await maintenance.runBatch(context)
  #expect(deletion.outcomes.map(\.status) == ["deleted"])
  #expect(try await snapshot().0 == "deleted")
  #expect(try await storage.head(objectKey) == nil)
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

private actor LegacyNullBindingPermission: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  private var allowed = true
  nonisolated func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func setAllowed(_ value: Bool) { allowed = value }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
    next: BlobRef?, action: String) async throws -> Bool { allowed }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
}

private actor LegacyNullAudit: AuditSink {
  private var events: [AuditEvent] = []
  func record(_ event: AuditEvent) { events.append(event) }
  func count() -> Int { events.count }
}

@Test(arguments: ["attach", "outer-reject", "clear-null", "delete-null", "non-null-orphan"])
func swiftFirstMutationOfMigratedNullColumnUsesNativeOwner(scenario: String) async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-legacy-null-\(UUID())", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try FileObjectStorage(root: root.appendingPathComponent("objects").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let spec = try BlobFieldSpec(entity: "Asset", field: "document", extensions: ["pdf"],
    nullable: true, policyProfile: "default")
  let entity = EntityDescriptor(name: "Asset", table: "migrated_null_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "document", type: .blobRef, nullable: true, blobSpec: spec),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let audit = LegacyNullAudit(), permission = LegacyNullBindingPermission()
  let base = UserContext(actor: "alice", queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit).withObjectStorage(store)
  let upload = try SQLiteBlobUploadService(authorization: NativeUploadAuthorization(),
    verifier: NativeVerifier(), maximumBytes: 1024)
  let module = try BlobReferenceModule(upload: upload, readAuthorization: NativeReadAuthorization(),
    bindingAuthorization: permission)
  let context = try module.install(on: base)
  try await context.ensureSchema(RuntimeModule(name: "legacy-null-test", entities: [entity]))
  let reference = try BlobRef("blob_legacy_null_first")
  try await context.executeGraphSave(comment: "seed migrated old SQL row") { actor, session in
    try await module.catalog.installSchema(actor, session: session)
    try await actor.withPhysicalSQL(session) { sql in
      // No binding backfill: the actual old row has SQL NULL in its added column.
      _ = try await sql.execute("INSERT INTO migrated_null_asset(id,version,document) VALUES (7,1,?)",
        parameters: [scenario == "non-null-orphan" ? .string(reference.key) : .null])
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_catalog
          (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,
           completed_at_ms,policy_profile,upload_mode,unbound_retention_seconds,effective_unref_seconds)
        VALUES (?,'tenant-a',?,'v1','report.pdf','application/pdf',7,'uploaded_unbound',
          CAST(strftime('%s','now') AS INTEGER)*1000,'default','server_stream',86400,604800)
        """, parameters: [.string(reference.key), .string("objects/\(reference.key)")])
    }
  }
  try await module.ready(context: context)
  func save(reject: Bool = false) async throws {
    try await context.executeGraphSave(comment: "first migrated Blob mutation") { actor, session in
      _ = try await actor.execute(Mutation(kind: scenario == "delete-null" ? .delete : .update,
        entity: entity, id: .int(7),
        values: scenario == "delete-null" ? [:] : ["document":
          scenario == "clear-null" || scenario == "non-null-orphan" ? .null : .blobRef(reference)],
        expectedVersion: 1, auditReason: session.intent.comment))
      #expect(await audit.count() == 0)
      if reject { throw TeaQLError.execution("outer owner rejected first legacy bind") }
    }
  }
  if scenario == "attach" {
    await permission.setAllowed(false)
    do { try await save(); Issue.record("revoked first legacy bind accepted") }
    catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }
    #expect(await audit.count() == 0)
    await permission.setAllowed(true)
  }
  let rollback = scenario == "outer-reject" || scenario == "non-null-orphan"
  if scenario == "outer-reject" {
    do { try await save(reject: true); Issue.record("outer rejection committed first bind") }
    catch { #expect(error as? TeaQLError == .execution("outer owner rejected first legacy bind")) }
  } else if scenario == "non-null-orphan" {
    do { try await save(); Issue.record("non-null orphan accepted") }
    catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }
  } else { try await save() }
  #expect(await audit.count() == (rollback ? 0 : 1))
  try await context.executeGraphSave(comment: "inspect migrated Blob result") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT version,document FROM migrated_null_asset WHERE id=7", parameters: [])
      #expect(rows.count == 1)
      #expect(rows.first?["version"] == .int(rollback ? 1 : scenario == "delete-null" ? -2 : 2))
      #expect(rows.first?["document"] ==
        (scenario == "attach" || scenario == "non-null-orphan" ? .string(reference.key) : .null))
      let bindings = try await sql.query("SELECT key,version FROM teaql_blob_binding", parameters: [])
      #expect(bindings.count == (rollback ? 0 : 1))
      if !rollback {
        #expect(bindings.first?["version"] == .int(1))
        #expect(bindings.first?["key"] == (scenario == "attach" ? .string(reference.key) : .null))
      }
      let catalog = try await sql.query("SELECT status FROM teaql_blob_catalog", parameters: [])
      #expect(catalog.first?["status"] == .string(scenario == "attach" ? "available" : "uploaded_unbound"))
    }
  }
}
