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
  try await context.executeGraphSave(comment: "install native Blob catalog") { actor, session in
    try await module.catalog.installSchema(actor, session: session)
    try await actor.withPhysicalSQL(session) { sql in
      for key in [first.key, second.key] {
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

  var generatedRuntime = TeaQLRuntime()
  try generatedRuntime.install(RuntimeModule(name: "native-blob-generated", entities: [asset],
    requiredCapabilities: ["blob.v1"]))
  let generatedBase = UserContext(runtime: generatedRuntime, actor: "alice",
    queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let generatedContext = try module.install(on: generatedBase)
  try await module.ready(context: generatedContext)
}
