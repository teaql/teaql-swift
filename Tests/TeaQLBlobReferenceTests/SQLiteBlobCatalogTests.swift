import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct CatalogAuthorization: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  let tenant: String
  let allowed: Bool

  init(_ tenant: String, allowed: Bool = true) {
    self.tenant = tenant
    self.allowed = allowed
  }

  func scope(for actor: UserContext) throws -> String { tenant }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool { allowed }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
}

private final class RetentionTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var milliseconds: Int64
  init(_ milliseconds: Int64) { self.milliseconds = milliseconds }
  func date() -> Date {
    lock.lock(); defer { lock.unlock() }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }
  func set(_ value: Int64) { lock.lock(); milliseconds = value; lock.unlock() }
}

private struct RetentionAuthorization: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  let seconds: Int64
  let minimum: Int64
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
    next: BlobRef?, action: String) async throws -> Bool { true }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 1, unreferencedRetentionSeconds: seconds,
      minimumRetentionSeconds: minimum)
  }
}

private struct CatalogReadPermission: BlobReadAuthorization {
  let allowed: Bool
  func authorize(actor: UserContext, slot: AuthorizedBlobSlot) async throws -> Bool { allowed }
}

private struct CatalogViewAuthorizer: ResponseGraphAuthorizer {
  let reference: BlobRef
  let slot: AuthorizedBlobSlot
  func authorize(context: UserContext, result: any Sendable, options: ViewOptions)
    async throws -> AuthorizedResponseGraph {
    AuthorizedResponseGraph(presentation: .object(["document": .blob(reference)]), blobSlots: [slot])
  }
}

private actor CatalogSigningStore: ObjectStorageProvider {
  var calls = 0
  var key: String?
  var header: String?

  func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader,
           options: ObjectPutOptions) throws -> ObjectMetadata { throw StorageError(.unsupported) }
  func get(_ invocation: StorageInvocation, key: ObjectKey) throws -> ObjectContent {
    throw StorageError(.unsupported)
  }
  func head(_ invocation: StorageInvocation, key: ObjectKey) throws -> ObjectMetadata? {
    throw StorageError(.unsupported)
  }
  func delete(_ invocation: StorageInvocation, key: ObjectKey) throws {
    throw StorageError(.unsupported)
  }
  func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey,
                  options: ObjectReadUrlOptions) throws -> ObjectReadUrl {
    calls += 1
    self.key = key.value
    header = options.contentDisposition
    return ObjectReadUrl(url: URL(string: "https://example.invalid/opaque-ticket")!,
      expiresAt: Date().addingTimeInterval(30))
  }
}

private func catalogFixture() async throws -> (UserContext, SQLiteDataService, EntityDescriptor) {
  let asset = EntityDescriptor(name: "Asset", table: "catalog_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "catalog-test", entities: [asset]))
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install blob catalog") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await catalog.validateSchema(graph, session: session)
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_catalog
        (key, scope, object_key, content_version, file_name, content_type, size_bytes, status,
         completed_at_ms,policy_profile,upload_mode,unbound_retention_seconds,effective_unref_seconds)
        VALUES ('blob_abc', 'tenant-a', 'objects/abc', 'v1', 'report.pdf', 'application/pdf', 7,
          'uploaded_unbound',CAST(strftime('%s','now') AS INTEGER)*1000,
          'default','server_stream',86400,604800)
        """, parameters: [])
    }
  }
  return (context, service, asset)
}

private func catalogCounts(_ context: UserContext) async throws -> (Int, Int) {
  try await context.executeGraphSave(comment: "inspect catalog") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let assets = try await sql.query("SELECT id FROM catalog_asset", parameters: [])
      let bindings = try await sql.query("SELECT key FROM teaql_blob_binding", parameters: [])
      return (assets.count, bindings.count)
    }
  }
}

private func insertAsset(_ actor: UserContext, _ session: GraphMutationSession,
                         _ asset: EntityDescriptor, id: Int64) async throws {
  _ = try await actor.execute(Mutation(kind: .create, entity: asset,
    values: ["id": .int(id), "name": .string("document")], auditReason: session.intent.comment))
}

@Test
func swiftBlobAdditiveMigrationKeepsLegacyPolicyUnknownAndRejectsBinding() async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "seed old Blob schema") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TABLE teaql_blob_catalog (key TEXT PRIMARY KEY, scope TEXT NOT NULL,
          object_key TEXT NOT NULL, content_version TEXT NOT NULL, file_name TEXT NOT NULL,
          content_type TEXT NOT NULL, size_bytes BIGINT NOT NULL, status TEXT NOT NULL)
        """, parameters: [])
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_catalog VALUES
          ('blob_legacy','tenant-a','objects/legacy','v1','old.pdf','application/pdf',5,'available')
        """, parameters: [])
    }
  }
  try await context.executeGraphSave(comment: "migrate old Blob schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await catalog.installSchema(graph, session: session)
    try await catalog.validateSchema(graph, session: session)
    try await graph.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("""
        SELECT completed_at_ms,last_unbound_at_ms,policy_profile,upload_mode,
          unbound_retention_seconds,effective_unref_seconds,retention_floor_until_ms
        FROM teaql_blob_catalog WHERE key='blob_legacy'
        """, parameters: [])
      #expect(rows.count == 1)
      for name in ["completed_at_ms", "last_unbound_at_ms", "policy_profile", "upload_mode",
                   "unbound_retention_seconds", "effective_unref_seconds", "retention_floor_until_ms"] {
        #expect(rows.first?[name] == .null)
      }
    }
  }
  do {
    try await context.executeGraphSave(comment: "reject legacy Blob binding") { graph, session in
      _ = try await catalog.bind(graph, session: session,
        change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "1", field: "file"),
          next: BlobRef("blob_legacy"), expectedVersion: 0, nextVersion: 1, action: "Create"),
        authorization: RetentionAuthorization(seconds: 2, minimum: 1))
    }
    Issue.record("legacy Blob was bound")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }
}

@Test
func swiftGraphBindingEnforcesDeadlineMaximumRetentionAndFloor() async throws {
  let clock = RetentionTestClock(10_000)
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  let catalog = SQLiteBlobCatalog(now: { clock.date() })
  try await context.executeGraphSave(comment: "seed retained Blob") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_catalog
        (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,
         completed_at_ms,policy_profile,upload_mode,unbound_retention_seconds,effective_unref_seconds)
        VALUES('blob_retained','tenant-a','objects/retained','v1','file.pdf','application/pdf',5,
          'uploaded_unbound',9000,'default','server_stream',1,2)
        """, parameters: [])
    }
  }
  let reference = try BlobRef("blob_retained")
  let first = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  let second = BlobBindingTarget(entity: "Asset", entityID: "2", field: "file")
  func change(_ target: BlobBindingTarget, _ next: BlobRef?, _ before: Int64, _ after: Int64,
    _ authorization: RetentionAuthorization) async throws {
    try await context.executeGraphSave(comment: "bind retained Blob") { graph, session in
      _ = try await catalog.bind(graph, session: session,
        change: BlobBindingChange(target: target, next: next,
          expectedVersion: before, nextVersion: after, action: before == 0 ? "Create" : "Update"),
        authorization: authorization)
    }
  }
  do {
    try await change(first, reference, 0, 1, RetentionAuthorization(seconds: 2, minimum: 1))
    Issue.record("expired completed Blob was bound")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_REFERENCE_EXPIRED")) }
  try await context.executeGraphSave(comment: "move retained Blob completion") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE teaql_blob_catalog SET completed_at_ms=9999",
        parameters: [])
    }
  }
  try await change(first, reference, 0, 1, RetentionAuthorization(seconds: 2, minimum: 1))
  try await change(second, reference, 0, 1, RetentionAuthorization(seconds: 30, minimum: 40))
  try await change(first, nil, 1, 2, RetentionAuthorization(seconds: 2, minimum: 1))
  try await change(second, nil, 1, 2, RetentionAuthorization(seconds: 2, minimum: 1))
  try await context.executeGraphSave(comment: "inspect retained Blob floor") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("""
        SELECT status,last_unbound_at_ms,effective_unref_seconds,retention_floor_until_ms
        FROM teaql_blob_catalog WHERE key='blob_retained'
        """, parameters: [])
      #expect(rows.first?["status"]?.stringValue == "available")
      #expect(rows.first?["last_unbound_at_ms"]?.int64Value == 10_000)
      #expect(rows.first?["effective_unref_seconds"]?.int64Value == 30)
      #expect(rows.first?["retention_floor_until_ms"]?.int64Value == 50_000)
    }
  }
  clock.set(49_999)
  try await change(first, reference, 2, 3, RetentionAuthorization(seconds: 1, minimum: 0))
  try await change(first, nil, 3, 4, RetentionAuthorization(seconds: 1, minimum: 0))
  clock.set(80_000)
  do {
    try await change(first, reference, 4, 5, RetentionAuthorization(seconds: 1, minimum: 0))
    Issue.record("expired formerly bound Blob was rebound")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_REFERENCE_EXPIRED")) }
}

@Test
func swiftCatalogBindingSharesNativeGraphCommitRollback() async throws {
  let (context, _, asset) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog(), reference = try BlobRef("blob_abc")
  let allowed = CatalogAuthorization("tenant-a")
  let target = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  try await context.executeGraphSave(comment: "save asset") { actor, session in
    try await insertAsset(actor, session, asset, id: 1)
    let version = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 0, nextVersion: 1, action: "Create"), authorization: allowed)
    #expect(version == 1)
  }
  #expect(try await catalogCounts(context) == (1, 1))
  try await context.executeGraphSave(comment: "inspect available content") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT status FROM teaql_blob_catalog", parameters: [])
      #expect(rows.first?["status"]?.stringValue == "available")
    }
  }

  do {
    try await context.executeGraphSave(comment: "rollback asset") { actor, session in
      try await insertAsset(actor, session, asset, id: 2)
      _ = try await catalog.bind(actor, session: session,
        change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "2", field: "file"),
          next: reference, expectedVersion: 0, nextVersion: 1, action: "Create"), authorization: allowed)
      throw TeaQLError.execution("abort graph")
    }
    Issue.record("graph should roll back")
  } catch { #expect(error as? TeaQLError == .execution("abort graph")) }
  #expect(try await catalogCounts(context) == (1, 1))

  do {
    try await context.executeGraphSave(comment: "revoked binding") { actor, session in
      try await insertAsset(actor, session, asset, id: 3)
      do {
        _ = try await catalog.bind(actor, session: session,
          change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "3", field: "file"),
            next: reference, expectedVersion: 0, nextVersion: 1, action: "Create"),
          authorization: CatalogAuthorization("tenant-a", allowed: false))
      } catch { #expect(error as? TeaQLError == .execution("BLOB_BIND_DENIED")) }
    }
    Issue.record("caught denial should poison the graph")
  } catch { #expect(error as? TeaQLError == .execution("GRAPH_TRANSACTION_ROLLBACK_ONLY")) }
  #expect(try await catalogCounts(context) == (1, 1))
}

@Test
func swiftCatalogVersionScopeAndTombstoneAreAuthoritative() async throws {
  let (context, service, _) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog(), reference = try BlobRef("blob_abc")
  let target = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  let allowed = CatalogAuthorization("tenant-a")
  try await context.executeGraphSave(comment: "bind") { actor, session in
    _ = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 0, nextVersion: 1, action: "Create"), authorization: allowed)
  }
  for (change, auth) in [
    (BlobBindingChange(target: target, next: reference,
      expectedVersion: 0, nextVersion: 2, action: "Update"), allowed),
    (BlobBindingChange(target: target, next: reference,
      expectedVersion: 1, nextVersion: 2, action: "Update"), CatalogAuthorization("tenant-b")),
    (BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "01", field: "file"),
      next: reference, expectedVersion: 1, nextVersion: 2, action: "Update"), allowed),
  ] {
    do {
      try await context.executeGraphSave(comment: "reject binding") { actor, session in
        _ = try await catalog.bind(actor, session: session, change: change, authorization: auth)
      }
      Issue.record("invalid binding was accepted")
    } catch { #expect(error as? TeaQLError != nil) }
  }
  let other = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  do {
    try await context.executeGraphSave(comment: "foreign actor") { actor, session in
      _ = try await catalog.bind(other, session: session,
        change: BlobBindingChange(target: target, next: reference,
          expectedVersion: 1, nextVersion: 2, action: "Update"), authorization: allowed)
    }
    Issue.record("foreign actor was accepted")
  } catch { #expect(error as? TeaQLError != nil) }
  try await context.executeGraphSave(comment: "clear binding") { actor, session in
    let cleared = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: nil,
        expectedVersion: 1, nextVersion: 2, action: "Delete"), authorization: allowed)
    #expect(cleared == 2)
  }
  try await context.executeGraphSave(comment: "inspect unbound content") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT status FROM teaql_blob_catalog", parameters: [])
      #expect(rows.first?["status"]?.stringValue == "available")
    }
  }
  try await context.executeGraphSave(comment: "rebind") { actor, session in
    let rebound = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 2, nextVersion: 3, action: "Update"), authorization: allowed)
    #expect(rebound == 3)
  }
  try await context.executeGraphSave(comment: "inspect binding") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT key,version FROM teaql_blob_binding", parameters: [])
      #expect(rows.count == 1)
      #expect(rows.first?["key"]?.stringValue == reference.key)
      #expect(rows.first?["version"]?.int64Value == 3)
      let catalog = try await sql.query("SELECT status FROM teaql_blob_catalog", parameters: [])
      #expect(catalog.first?["status"]?.stringValue == "available")
    }
  }
}

@Test
func swiftCatalogRejectsLegacyNonnullableKeySchema() async throws {
  let (context, _, _) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog()
  do {
    try await context.executeGraphSave(comment: "inspect legacy schema") { actor, session in
      try await actor.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("DROP TABLE teaql_blob_binding", parameters: [])
        _ = try await sql.execute("""
          CREATE TABLE teaql_blob_binding
          (scope TEXT, entity TEXT, entity_id TEXT, field TEXT, key TEXT NOT NULL, version BIGINT NOT NULL)
          """, parameters: [])
      }
      try await catalog.validateSchema(actor, session: session)
    }
    Issue.record("legacy schema was accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_SCHEMA_MISSING")) }
}

@Test
func swiftCurrentBindingReadPrecedesViewURLProjection() async throws {
  let (context, _, _) = try await catalogFixture()
  let catalog = SQLiteBlobCatalog(), reference = try BlobRef("blob_abc")
  let target = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  try await context.executeGraphSave(comment: "bind read fixture") { actor, session in
    _ = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 0, nextVersion: 1, action: "Create"),
      authorization: CatalogAuthorization("tenant-a"))
  }
  let slot = AuthorizedBlobSlot(path: [.field("document")], entity: "Asset", entityID: "1",
    field: "file", scope: "tenant-a", bindingVersion: 1, reference: reference)
  let record = try await catalog.currentRead(context, slot: slot)
  #expect(record.objectKey == "objects/abc")
  #expect(record.contentVersion == "v1")
  #expect(record.sizeBytes == 7)

  for invalid in [
    AuthorizedBlobSlot(path: slot.path, entity: slot.entity, entityID: slot.entityID,
      field: slot.field, scope: slot.scope, bindingVersion: 2, reference: reference),
    AuthorizedBlobSlot(path: slot.path, entity: slot.entity, entityID: slot.entityID,
      field: slot.field, scope: "tenant-b", bindingVersion: 1, reference: reference),
    AuthorizedBlobSlot(path: slot.path, entity: slot.entity, entityID: slot.entityID,
      field: slot.field, scope: slot.scope, bindingVersion: 1, reference: try BlobRef("blob_old")),
  ] {
    do { _ = try await catalog.currentRead(context, slot: invalid); Issue.record("stale read accepted") }
    catch let error as ViewPreparationError { #expect(error.code == "BLOB_READ_DENIED") }
  }

  let store = CatalogSigningStore()
  let authorizer = CatalogViewAuthorizer(reference: reference, slot: slot)
  let permitted = context.withObjectStorage(store).withResponseGraphAuthorizer(authorizer)
    .withBlobResponseContributor(try SQLiteBlobResponseContributor(catalog: catalog,
      authorization: CatalogReadPermission(allowed: true)))
  let prepared = try await ViewPreparationService().prepare(context: permitted, result: "unused",
    options: ViewOptions(mode: .ordinary, businessOutcome: .readOnly,
      expiresAt: Date().addingTimeInterval(60)))
  #expect(prepared.presentation == .object(["document": .string("https://example.invalid/opaque-ticket")]))
  #expect(await store.calls == 1)
  #expect(await store.key == "objects/abc")
  #expect(await store.header == "inline; filename=\"report.pdf\"")

  let revoked = permitted.withBlobResponseContributor(try SQLiteBlobResponseContributor(
    catalog: catalog, authorization: CatalogReadPermission(allowed: false)))
  do {
    _ = try await ViewPreparationService().prepare(context: revoked, result: "unused",
      options: ViewOptions(mode: .ordinary, businessOutcome: .readOnly,
        expiresAt: Date().addingTimeInterval(60)))
    Issue.record("revoked read signed")
  } catch let error as ViewPreparationError { #expect(error.code == "BLOB_READ_DENIED") }
  #expect(await store.calls == 1)

  try await context.executeGraphSave(comment: "delete content") { actor, session in
    try await actor.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE teaql_blob_catalog SET status = 'deleted' WHERE key = ?",
        parameters: [.string(reference.key)])
    }
  }
  do { _ = try await catalog.currentRead(context, slot: slot); Issue.record("deleted content accepted") }
  catch let error as ViewPreparationError { #expect(error.code == "BLOB_READ_DENIED") }
}

@Test
func swiftAuthorizedViewProjectsRealFileURLAndDeniesRevokedRefresh() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-view-file-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  _ = try store.start()
  let (context, _, _) = try await catalogFixture()
  let storage = try context.withObjectStorage(store).objectStorage("publish current file")
  let bytes = Data("%PDF-1x".utf8)
  _ = try await storage.putBytes(try ObjectKey("objects/abc"), data: bytes,
    options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly,
      contentType: "application/pdf"))
  let catalog = SQLiteBlobCatalog(), reference = try BlobRef("blob_abc")
  let target = BlobBindingTarget(entity: "Asset", entityID: "1", field: "file")
  try await context.executeGraphSave(comment: "bind real file") { actor, session in
    _ = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: target, next: reference,
        expectedVersion: 0, nextVersion: 1, action: "Create"),
      authorization: CatalogAuthorization("tenant-a"))
  }
  let slot = AuthorizedBlobSlot(path: [.field("document")], entity: "Asset", entityID: "1",
    field: "file", scope: "tenant-a", bindingVersion: 1, reference: reference)
  let authorizer = CatalogViewAuthorizer(reference: reference, slot: slot)
  let permitted = context.withObjectStorage(store).withResponseGraphAuthorizer(authorizer)
    .withBlobResponseContributor(try SQLiteBlobResponseContributor(catalog: catalog,
      authorization: CatalogReadPermission(allowed: true)))
  let options = ViewOptions(mode: .ordinary, businessOutcome: .readOnly,
    expiresAt: Date().addingTimeInterval(60))
  let prepared = try await ViewPreparationService().prepare(context: permitted,
    result: "unused", options: options)
  guard case let .object(fields) = prepared.presentation,
    let document = fields["document"], case let .string(urlText) = document,
    let url = URL(string: urlText) else { Issue.record("File URL not projected"); return }
  #expect(!urlText.contains("objects/abc"))
  let session = URLSession(configuration: .ephemeral)
  defer { session.invalidateAndCancel() }
  let (body, response) = try await session.data(from: url)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(body == bytes)
  #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
  #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ==
    "inline; filename=\"report.pdf\"")
  let revoked = permitted.withBlobResponseContributor(try SQLiteBlobResponseContributor(
    catalog: catalog, authorization: CatalogReadPermission(allowed: false)))
  do {
    _ = try await ViewPreparationService().prepare(context: revoked,
      result: "unused", options: options)
    Issue.record("revoked URL refresh accepted")
  } catch let error as ViewPreparationError { #expect(error.code == "BLOB_READ_DENIED") }
}
