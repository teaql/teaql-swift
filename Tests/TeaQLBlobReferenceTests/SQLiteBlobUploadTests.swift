import Crypto
import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct UploadPermission: BlobUploadAuthorization, BlobUploadPolicyAuthorization {
  let tenant: String
  let allowed: Bool
  var checkSQLPolicy = false
  var extensions = ["pdf"]
  func scope(for actor: UserContext) throws -> String { tenant }
  func field(for actor: UserContext, target: BlobUploadTarget) throws -> BlobFieldSpec {
    try BlobFieldSpec(entity: "Asset", field: "file", extensions: extensions,
      nullable: true, policyProfile: "default")
  }
  func authorize(actor: UserContext, target: BlobUploadTarget, action: String,
                 input: BlobUploadInput) async throws -> Bool {
    allowed && target.entity == "Asset" && target.field == "file"
      && ["Begin", "Write", "Confirm"].contains(action)
  }
  func currentOnLease(actor: UserContext, target: BlobUploadTarget, action: String,
                      input: BlobUploadInput, lease: any GraphPhysicalSQLLease)
    async throws -> BlobUploadAuthorizationSnapshot {
    var currentAllowed = try await authorize(actor: actor, target: target,
      action: action, input: input)
    if checkSQLPolicy {
      let rows = try await lease.query("SELECT allowed FROM upload_policy", parameters: [])
      currentAllowed = currentAllowed && rows.count == 1 && rows[0]["allowed"]?.int64Value == 1
    }
    return BlobUploadAuthorizationSnapshot(scope: try scope(for: actor),
      field: try field(for: actor, target: target), allowed: currentAllowed)
  }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobUploadTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
}

private struct UploadBindingPermission: BlobBindingAuthorization, BlobBindingPolicyAuthorization {
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool {
    target.entity == "Asset" && target.field == "file" && action == "Create"
  }
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy {
    try BlobRetentionPolicy(profile: "default", uploadMode: "server_stream",
      unboundRetentionSeconds: 86400, unreferencedRetentionSeconds: 604800,
      minimumRetentionSeconds: 3600)
  }
}

private struct ModuleReadPermission: BlobReadAuthorization {
  func authorize(actor: UserContext, slot: AuthorizedBlobSlot) async throws -> Bool { true }
}

@Test
func swiftBlobModuleRequiresInstalledProviderAndCatalogSchema() async throws {
  let database = try SQLiteDataService(path: ":memory:")
  let base = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  let upload = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  let module = try BlobReferenceModule(upload: upload, readAuthorization: ModuleReadPermission(),
    bindingAuthorization: UploadBindingPermission())
  let noProvider = try module.install(on: base)
  do { try await module.ready(context: noProvider); Issue.record("missing provider accepted") }
  catch { #expect((error as? ViewPreparationError)?.code == "BLOB_CAPABILITY_MISSING") }

  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-module-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let context = try module.install(on: base.withObjectStorage(store))
  do { try await module.ready(context: context); Issue.record("missing catalog accepted") }
  catch { #expect((error as? ViewPreparationError)?.code == "BLOB_SCHEMA_MISSING") }
  try await context.executeGraphSave(comment: "install Blob module catalog") { graph, session in
    try await module.catalog.installSchema(graph, session: session)
  }
  try await module.ready(context: context)
  do { _ = try module.install(on: context); Issue.record("duplicate Blob module accepted") }
  catch { #expect((error as? ViewPreparationError)?.code == "BLOB_CAPABILITY_MISSING") }
}

// The test verifier only checks a fixture PDF; it is not production format parsing.
private actor UploadVerifierCalls {
  private var count = 0
  func record() { count += 1 }
  func value() -> Int { count }
}

private actor UploadLatch {
  private var open = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if open { return }
    await withCheckedContinuation { continuation in waiters.append(continuation) }
  }
  func release() {
    open = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
  func isReleased() -> Bool { open }
}

private actor PausedUploadReader: ObjectByteReader {
  let entered = UploadLatch()
  let release = UploadLatch()
  private let source: ObjectDataReader
  private var paused = false
  init(_ bytes: Data) { source = ObjectDataReader(bytes) }
  func read(upToCount count: Int) async throws -> Data {
    if !paused {
      paused = true
      await entered.release()
      await release.wait()
    }
    return try await source.read(upToCount: count)
  }
  func close() async throws { await source.close() }
}

private actor CountingUploadReader: ObjectByteReader {
  private let source: ObjectDataReader
  private var reads = 0
  init(_ bytes: Data) { source = ObjectDataReader(bytes) }
  func read(upToCount count: Int) async throws -> Data {
    reads += 1
    return try await source.read(upToCount: count)
  }
  func count() -> Int { reads }
  func close() async throws { await source.close() }
}

private actor FailedReplayReader: ObjectByteReader {
  func read(upToCount: Int) async throws -> Data {
    throw TeaQLError.execution("PRIVATE-REPLAY-SOURCE-CANARY")
  }
  func close() async throws {}
}

private actor CountingUploadStore: ObjectStorageProvider {
  let file: FileObjectStorage
  private var writes = 0
  init(_ file: FileObjectStorage) { self.file = file }
  func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader,
           options: ObjectPutOptions) async throws -> ObjectMetadata {
    writes += 1
    return try await file.put(invocation, key: key, content: content, options: options)
  }
  func get(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectContent {
    try await file.get(invocation, key: key)
  }
  func head(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectMetadata? {
    try await file.head(invocation, key: key)
  }
  func delete(_ invocation: StorageInvocation, key: ObjectKey) async throws {
    try await file.delete(invocation, key: key)
  }
  func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey,
                  options: ObjectReadUrlOptions) async throws -> ObjectReadUrl {
    try await file.getReadUrl(invocation, key: key, options: options)
  }
  func count() -> Int { writes }
}

private actor CloseFailUploadReader: ObjectByteReader {
  let inner: any ObjectByteReader
  let store: CloseFailUploadStore
  init(_ inner: any ObjectByteReader, store: CloseFailUploadStore) {
    self.inner = inner
    self.store = store
  }
  func read(upToCount count: Int) async throws -> Data {
    try await inner.read(upToCount: count)
  }
  func close() async throws {
    try await inner.close()
    if await store.shouldFailClose() { throw TeaQLError.execution("PRIVATE-CLOSE-CANARY") }
  }
}

private actor CloseFailUploadStore: ObjectStorageProvider {
  let file: FileObjectStorage
  private var failClose = true
  init(_ file: FileObjectStorage) { self.file = file }
  func stopFailing() { failClose = false }
  func shouldFailClose() -> Bool { failClose }
  func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader,
           options: ObjectPutOptions) async throws -> ObjectMetadata {
    try await file.put(invocation, key: key, content: content, options: options)
  }
  func get(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectContent {
    let content = try await file.get(invocation, key: key)
    return ObjectContent(metadata: content.metadata,
      reader: CloseFailUploadReader(content.reader, store: self))
  }
  func head(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectMetadata? {
    try await file.head(invocation, key: key)
  }
  func delete(_ invocation: StorageInvocation, key: ObjectKey) async throws {
    try await file.delete(invocation, key: key)
  }
  func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey,
                  options: ObjectReadUrlOptions) async throws -> ObjectReadUrl {
    try await file.getReadUrl(invocation, key: key, options: options)
  }
}

private actor LostUploadCommitReply: MutationExecutor, GraphTransactionExecutor,
  GraphPhysicalSQLExecutor {
  let database: SQLiteDataService
  private var loseNext = false
  init(_ database: SQLiteDataService) { self.database = database }
  func loseNextCommitReply() { loseNext = true }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    try await database.execute(request)
  }
  func beginGraphTransaction() async throws { try await database.beginGraphTransaction() }
  func commitGraphTransaction() async throws {
    try await database.commitGraphTransaction()
    if loseNext {
      loseNext = false
      throw TeaQLError.execution("BLOB_CATALOG_FAILED")
    }
  }
  func rollbackGraphTransaction() async throws { try await database.rollbackGraphTransaction() }
  func withPhysicalSQL<T: Sendable>(
    _ work: @escaping @Sendable (any GraphPhysicalSQLLease) async throws -> T
  ) async throws -> T { try await database.withPhysicalSQL(work) }
  func isCurrentPhysicalSQLLease(_ lease: any GraphPhysicalSQLLease) async -> Bool {
    await database.isCurrentPhysicalSQLLease(lease)
  }
}

private struct PausedUploadVerifier: BlobContentVerifier {
  let entered: UploadLatch
  let release: UploadLatch
  let calls: UploadVerifierCalls
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    await calls.record()
    await entered.release()
    await release.wait()
    return try await FixturePDFVerifier().verify(reader: reader, extension: ext,
      maximumBytes: maximumBytes)
  }
}

private struct FixturePDFVerifier: BlobContentVerifier {
  let early: Bool
  let calls: UploadVerifierCalls?
  init(early: Bool = false, calls: UploadVerifierCalls? = nil) {
    self.early = early; self.calls = calls
  }
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    await calls?.record()
    if early { return BlobVerifiedContent(sizeBytes: 1, sha256: String(repeating: "0", count: 64),
      contentType: "application/pdf") }
    var data = Data()
    while true {
      let bytes = try await reader.read(upToCount: 4096)
      if bytes.isEmpty { break }
      data.append(bytes)
      guard Int64(data.count) <= maximumBytes else { throw TeaQLError.execution("invalid fixture") }
    }
    guard ext == "pdf", data.starts(with: Data("%PDF-".utf8)),
      String(data: data, encoding: .utf8)?.contains("%%EOF") == true else {
      throw TeaQLError.execution("invalid fixture")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest,
      contentType: "application/pdf")
  }
}

private func uploadCatalogValue(_ context: UserContext, sql: String,
                                key: String) async throws -> String? {
  try await context.executeGraphSave(comment: "inspect Blob upload") { graph, session in
    try await graph.withPhysicalSQL(session) { lease in
      let rows = try await lease.query(sql, parameters: [.string(key)])
      return rows.first?.values.first?.stringValue
    }
  }
}

@Test
func swiftLegacyUploadRequestHashReplaysAfterNumericABIMigration() async throws {
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install Blob upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  let input = BlobUploadInput(fileName: "sample.pdf", declaredSize: 42,
    declaredContentType: "application/pdf")
  let old = try await service.begin(actor, target: target, input: input,
    replayKey: "legacy-request")
  let legacyParts = ["Asset", "1", "file", "sample.pdf", "42", "application/pdf"]
  let legacyHash = SHA256.hash(data: try JSONEncoder().encode(legacyParts))
    .map { String(format: "%02x", $0) }.joined()
  try await actor.executeGraphSave(comment: "simulate prior Swift lease") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE teaql_blob_upload SET request_hash=? WHERE upload_id=?",
        parameters: [.string(legacyHash), .string(old.uploadID)])
    }
  }
  let replay = try await service.begin(actor, target: target, input: input,
    replayKey: "legacy-request")
  #expect(replay.uploadID == old.uploadID)
  #expect(replay.reference == old.reference)
  let fresh = try await service.begin(actor, target: target, input: input,
    replayKey: "numeric-request")
  let numericParts: [Any] = ["Asset", "1", "file", "sample.pdf", Int64(42), "application/pdf"]
  let numericHash = SHA256.hash(data: try JSONSerialization.data(withJSONObject: numericParts,
    options: [.withoutEscapingSlashes])).map { String(format: "%02x", $0) }.joined()
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT request_hash FROM teaql_blob_upload WHERE key=?", key: fresh.reference.key)
    == numericHash)
  let unicode = try await service.begin(actor, target: target,
    input: BlobUploadInput(fileName: "报告 & review.pdf", declaredSize: 42),
    replayKey: "unicode-no-mime")
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT request_hash FROM teaql_blob_upload WHERE key=?", key: unicode.reference.key)
    == "49326c668df787833da79c84aa49ae3951ce7604e79a359ffe27cb10e15aea48")
}

@Test
func swiftSQLiteUploadSerializesTwoConnectionsAcrossFileAndParserIO() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-upload-owner-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let path = parent.appendingPathComponent("upload.db").path
  let database1 = try SQLiteDataService(path: path)
  let database2 = try SQLiteDataService(path: path)
  let actor1 = UserContext(queryExecutor: database1, mutationExecutor: database1,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let actor2 = UserContext(queryExecutor: database2, mutationExecutor: database2,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor1.executeGraphSave(comment: "install upload journal") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("CREATE TABLE upload_policy (allowed INTEGER NOT NULL)", parameters: [])
      _ = try await sql.execute("INSERT INTO upload_policy VALUES (1)", parameters: [])
    }
  }
  let permission = UploadPermission(tenant: "tenant-a", allowed: true, checkSQLPolicy: true)
  let entered = UploadLatch(), release = UploadLatch(), calls = UploadVerifierCalls()
  let verifier = PausedUploadVerifier(entered: entered, release: release, calls: calls)
  let first = try SQLiteBlobUploadService(authorization: permission, verifier: verifier,
    maximumBytes: 10_000)
  let second = try SQLiteBlobUploadService(authorization: permission, verifier: verifier,
    maximumBytes: 10_000)
  let bytes = Data("%PDF-1.7\nconcurrent content\n%%EOF".utf8)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  let input = BlobUploadInput(fileName: "report.pdf", declaredSize: Int64(bytes.count))
  let denied = try await first.begin(actor1, target: target, input: input,
    replayKey: "policy-change")
  try await actor1.executeGraphSave(comment: "revoke upload") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE upload_policy SET allowed = 0", parameters: [])
    }
  }
  do {
    _ = try await first.write(actor1, uploadID: denied.uploadID, source: ObjectDataReader(bytes))
    Issue.record("revoked SQL policy wrote upload")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  try await actor1.executeGraphSave(comment: "restore upload") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("UPDATE upload_policy SET allowed = 1", parameters: [])
    }
  }
  let session = try await first.begin(actor1, target: target, input: input,
    replayKey: "concurrent")
  let pausedSource = PausedUploadReader(bytes)
  let firstWrite = Task { try await first.write(actor1, uploadID: session.uploadID,
    source: pausedSource) }
  await pausedSource.entered.wait()
  let secondSource = CountingUploadReader(bytes)
  let secondWrite = Task { try await second.write(actor2, uploadID: session.uploadID,
    source: secondSource) }
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(await secondSource.count() == 0)
  await pausedSource.release.release()
  #expect(try await firstWrite.value == Int64(bytes.count))
  #expect(try await secondWrite.value == Int64(bytes.count))

  let firstConfirm = Task { try await first.complete(actor1, uploadID: session.uploadID) }
  await entered.wait()
  let secondConfirm = Task { try await second.complete(actor2, uploadID: session.uploadID) }
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(await calls.value() == 1)
  await release.release()
  #expect(try await firstConfirm.value == session.reference)
  #expect(try await secondConfirm.value == session.reference)
  #expect(await calls.value() == 1)

  let revokeEntered = UploadLatch(), revokeRelease = UploadLatch()
  let revokeCalls = UploadVerifierCalls()
  let revokeVerifier = PausedUploadVerifier(entered: revokeEntered,
    release: revokeRelease, calls: revokeCalls)
  let revokeService = try SQLiteBlobUploadService(authorization: permission,
    verifier: revokeVerifier, maximumBytes: 10_000)
  let revokeSession = try await revokeService.begin(actor1, target: target, input: input,
    replayKey: "revoke-during-parser")
  #expect(try await revokeService.write(actor1, uploadID: revokeSession.uploadID,
    source: ObjectDataReader(bytes)) == Int64(bytes.count))
  let confirmation = Task { try await revokeService.complete(actor1,
    uploadID: revokeSession.uploadID) }
  await revokeEntered.wait()
  let revokeDone = UploadLatch()
  let revocation = Task {
    try await actor2.executeGraphSave(comment: "revoke during parser") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("UPDATE upload_policy SET allowed = 0", parameters: [])
      }
    }
    await revokeDone.release()
  }
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(await revokeDone.isReleased() == false)
  await revokeRelease.release()
  #expect(try await confirmation.value == revokeSession.reference)
  try await revocation.value
  do {
    _ = try await revokeService.complete(actor1, uploadID: revokeSession.uploadID)
    Issue.record("revoked completed replay accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  #expect(await revokeCalls.value() == 1)
  #expect(try await uploadCatalogValue(actor1,
    sql: "SELECT state FROM teaql_blob_upload WHERE key = ?",
    key: revokeSession.reference.key) == "completed")
  #expect(try await uploadCatalogValue(actor1,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?",
    key: revokeSession.reference.key) == "uploaded_unbound")
}

@Test
func swiftSQLiteConfirmCloseFailureKeepsWrittenUploadAndAllowsRetry() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-upload-close-fail-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? file.close() }
  let store = CloseFailUploadStore(file)
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install upload journal") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(authorization: UploadPermission(tenant: "tenant-a",
    allowed: true), verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  let bytes = Data("%PDF-1.7\nclose fails after full verification\n%%EOF".utf8)
  let session = try await service.begin(actor,
    target: BlobUploadTarget(entity: "Asset", entityID: "1", field: "file"),
    input: BlobUploadInput(fileName: "report.pdf", declaredSize: Int64(bytes.count)),
    replayKey: "close-fail-request")
  #expect(try await service.write(actor, uploadID: session.uploadID,
    source: ObjectDataReader(bytes)) == Int64(bytes.count))
  do {
    _ = try await service.complete(actor, uploadID: session.uploadID)
    Issue.record("failed close completed Blob upload")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT state FROM teaql_blob_upload WHERE key = ?", key: session.reference.key) == "written")
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key) == "initiated")
  await store.stopFailing()
  #expect(try await service.complete(actor, uploadID: session.uploadID) == session.reference)
}

@Test
func swiftSQLiteUploadRetryRecoversOnlyIdenticalFileAfterJournalRollback() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-upload-recover-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install upload journal") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let calls = UploadVerifierCalls()
  let service = try SQLiteBlobUploadService(authorization: UploadPermission(tenant: "tenant-a",
    allowed: true), verifier: FixturePDFVerifier(calls: calls), maximumBytes: 10_000)
  let bytes = Data("%PDF-1.7\nrecover committed File content\n%%EOF".utf8)
  let session = try await service.begin(actor,
    target: BlobUploadTarget(entity: "Asset", entityID: "1", field: "file"),
    input: BlobUploadInput(fileName: "report.pdf", declaredSize: Int64(bytes.count)),
    replayKey: "recovery-request")
  try await actor.executeGraphSave(comment: "inject promotion rollback") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TRIGGER reject_upload_write BEFORE UPDATE ON teaql_blob_upload
        WHEN NEW.state='written' BEGIN SELECT RAISE(ABORT, 'injected'); END
        """, parameters: [])
    }
  }
  do {
    _ = try await service.write(actor, uploadID: session.uploadID, source: ObjectDataReader(bytes))
    Issue.record("trigger accepted journal promotion")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_CATALOG_FAILED")) }
  let raw = try #require(await uploadCatalogValue(actor,
    sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key))
  let key = try ObjectKey(raw)
  let stable = try #require(await actor.objectStorage("check recovery candidate").head(key))
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT state FROM teaql_blob_upload WHERE key = ?", key: session.reference.key) == "initiated")
  try await actor.executeGraphSave(comment: "remove promotion failure") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("DROP TRIGGER reject_upload_write", parameters: [])
    }
  }
  do {
    _ = try await service.write(actor, uploadID: session.uploadID,
      source: ObjectDataReader(Data(repeating: 0x78, count: bytes.count)))
    Issue.record("different bytes adopted existing File object")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_STORE_FAILED")) }
  #expect(try await service.write(actor, uploadID: session.uploadID,
    source: ObjectDataReader(bytes)) == Int64(bytes.count))
  let after = try #require(await actor.objectStorage("check recovered generation").head(key))
  #expect(after.etag == stable.etag)
  #expect(try await service.complete(actor, uploadID: session.uploadID) == session.reference)
  #expect(await calls.value() == 1)
}

@Test
func swiftSQLiteCommittedUploadWriteReplaysOnlySameBytesAndGeneration() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-upload-commit-unknown-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? file.close() }
  let store = CountingUploadStore(file)
  let database = try SQLiteDataService(path: parent.appendingPathComponent("upload.db").path)
  let base = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 })
  let catalog = SQLiteBlobCatalog()
  try await base.executeGraphSave(comment: "install upload journal") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let transport = LostUploadCommitReply(database)
  let actor = UserContext(queryExecutor: database, mutationExecutor: transport,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let calls = UploadVerifierCalls()
  let service = try SQLiteBlobUploadService(authorization: UploadPermission(tenant: "tenant-a",
    allowed: true), verifier: FixturePDFVerifier(calls: calls), maximumBytes: 10_000)
  let bytes = Data("%PDF-1.7\nSQL commit succeeded, reply lost\n%%EOF".utf8)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  let input = BlobUploadInput(fileName: "report.pdf", declaredSize: Int64(bytes.count))
  await transport.loseNextCommitReply()
  do { _ = try await service.begin(actor, target: target, input: input, replayKey: "unknown-write")
    Issue.record("lost begin reply returned success") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_CATALOG_FAILED")) }
  let begunID = try #require(await uploadCatalogValue(base,
    sql: "SELECT upload_id FROM teaql_blob_upload WHERE replay_key=?", key: "unknown-write"))
  let begunKey = try #require(await uploadCatalogValue(base,
    sql: "SELECT key FROM teaql_blob_upload WHERE replay_key=?", key: "unknown-write"))
  let begunExpiry = try #require(await uploadCatalogValue(base,
    sql: "SELECT CAST(expires_ms AS TEXT) FROM teaql_blob_upload WHERE replay_key=?",
    key: "unknown-write"))
  let revoked = try SQLiteBlobUploadService(authorization: UploadPermission(tenant: "tenant-a",
    allowed: false), verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  do { _ = try await revoked.begin(actor, target: target, input: input, replayKey: "unknown-write")
    Issue.record("revoked begin replay accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  do { _ = try await service.begin(actor, target: target,
    input: BlobUploadInput(fileName: "changed.pdf", declaredSize: Int64(bytes.count)),
    replayKey: "unknown-write")
    Issue.record("changed begin replay accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_IDEMPOTENCY_CONFLICT")) }
  let session = try await service.begin(actor, target: target, input: input, replayKey: "unknown-write")
  #expect(session.uploadID == begunID && session.reference.key == begunKey)
  #expect(String(Int64((session.expiresAt.timeIntervalSince1970 * 1000).rounded())) == begunExpiry)
  await transport.loseNextCommitReply()
  do {
    _ = try await service.write(actor, uploadID: session.uploadID, source: ObjectDataReader(bytes))
    Issue.record("lost commit reply returned success")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_CATALOG_FAILED")) }
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT state FROM teaql_blob_upload WHERE key = ?", key: session.reference.key) == "written")
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key) == "initiated")
  #expect(await store.count() == 1)
  do { _ = try await revoked.write(actor, uploadID: session.uploadID, source: ObjectDataReader(bytes))
    Issue.record("revoked retry accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  do { _ = try await service.write(actor, uploadID: session.uploadID,
    source: ObjectDataReader(Data(repeating: 0x78, count: bytes.count)))
    Issue.record("changed bytes replayed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_IDEMPOTENCY_CONFLICT")) }
  do { _ = try await service.write(actor, uploadID: session.uploadID,
    source: ObjectDataReader(bytes.dropLast()))
    Issue.record("short source replayed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_IDEMPOTENCY_CONFLICT")) }
  do { _ = try await service.write(actor, uploadID: session.uploadID, source: FailedReplayReader())
    Issue.record("failing source replayed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_STORE_FAILED")) }
  #expect(try await service.write(actor, uploadID: session.uploadID,
    source: ObjectDataReader(bytes)) == Int64(bytes.count))
  #expect(await store.count() == 1)
  await transport.loseNextCommitReply()
  do { _ = try await service.complete(actor, uploadID: session.uploadID)
    Issue.record("lost confirmation reply returned success") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_CATALOG_FAILED")) }
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT state FROM teaql_blob_upload WHERE key = ?", key: session.reference.key) == "completed")
  do { _ = try await revoked.complete(actor, uploadID: session.uploadID)
    Issue.record("revoked confirmation replay accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  #expect(try await service.complete(actor, uploadID: session.uploadID) == session.reference)
  #expect(await calls.value() == 1)
  #expect(try await service.write(actor, uploadID: session.uploadID,
    source: ObjectDataReader(bytes)) == Int64(bytes.count))
  #expect(await calls.value() == 1)
  let raw = try #require(await uploadCatalogValue(actor,
    sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key))
  _ = try await actor.objectStorage("replace File generation").putBytes(try ObjectKey(raw), data: bytes,
    options: ObjectPutOptions(size: Int64(bytes.count), mode: .replace,
      contentType: "application/pdf"))
  do { _ = try await service.write(actor, uploadID: session.uploadID, source: ObjectDataReader(bytes))
    Issue.record("replaced generation replayed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_IDEMPOTENCY_CONFLICT")) }
}

@Test
func swiftSQLiteFileUploadNeedsFullVerificationBeforeNativeBind() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-upload-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let asset = EntityDescriptor(name: "Asset", table: "upload_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
    .withObjectStorageObserver { _ in }
  try await context.ensureSchema(RuntimeModule(name: "upload-test", entities: [asset]))
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install Blob upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await catalog.validateSchema(graph, session: session)
  }
  let calls = UploadVerifierCalls()
  let service = try SQLiteBlobUploadService(authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(calls: calls), maximumBytes: 10_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  let data = Data("%PDF-1.7\nreal file bytes\n%%EOF".utf8)
  let input = BlobUploadInput(fileName: "path/report.pdf", declaredSize: Int64(data.count),
    declaredContentType: "application/pdf")
  let session = try await service.begin(context, target: target, input: input, replayKey: "request-1")
  try await context.executeGraphSave(comment: "inspect snapshotted Blob policy") { graph, lease in
    try await graph.withPhysicalSQL(lease) { sql in
      let rows = try await sql.query("""
        SELECT policy_profile,upload_mode,unbound_retention_seconds,
          effective_unref_seconds,completed_at_ms FROM teaql_blob_catalog WHERE key=?
        """, parameters: [.string(session.reference.key)])
      #expect(rows.count == 1)
      #expect(rows.first?["policy_profile"]?.stringValue == "default")
      #expect(rows.first?["upload_mode"]?.stringValue == "server_stream")
      #expect(rows.first?["unbound_retention_seconds"]?.int64Value == 86400)
      #expect(rows.first?["effective_unref_seconds"]?.int64Value == 604800)
      #expect(rows.first?["completed_at_ms"] == .null)
    }
  }
  let replay = try await service.begin(context, target: target, input: input, replayKey: "request-1")
  #expect(replay.uploadID == session.uploadID)
  do {
    _ = try await service.begin(context, target: target,
      input: BlobUploadInput(fileName: "other.pdf", declaredSize: Int64(data.count)),
      replayKey: "request-1")
    Issue.record("changed replay accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_IDEMPOTENCY_CONFLICT")) }
  do { _ = try await service.complete(context, uploadID: session.uploadID); Issue.record("empty upload completed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }
  let wrongScope = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-b", allowed: true),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  do {
    _ = try await wrongScope.write(context, uploadID: session.uploadID, source: ObjectDataReader(data))
    Issue.record("foreign scope wrote upload")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  #expect(try await service.write(context, uploadID: session.uploadID,
    source: ObjectDataReader(data)) == Int64(data.count))
  #expect(try await uploadCatalogValue(context,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key) == "initiated")
  let revoked = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: false),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  do { _ = try await revoked.complete(context, uploadID: session.uploadID); Issue.record("revoked confirmed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  let reference = try await service.complete(context, uploadID: session.uploadID)
  #expect(reference == session.reference)
  #expect(await calls.value() == 1)
  let completedAt = try await context.executeGraphSave(comment: "inspect Blob completion time") { graph, lease in
    try await graph.withPhysicalSQL(lease) { sql in
      let rows = try await sql.query(
        "SELECT completed_at_ms FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(reference.key)])
      return rows.first?["completed_at_ms"]?.int64Value
    }
  }
  #expect(completedAt != nil)
  #expect(try await service.complete(context, uploadID: session.uploadID) == reference)
  #expect(try await context.executeGraphSave(comment: "inspect replayed Blob completion time") { graph, lease in
    try await graph.withPhysicalSQL(lease) { sql in
      let rows = try await sql.query(
        "SELECT completed_at_ms FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(reference.key)])
      return rows.first?["completed_at_ms"]?.int64Value
    }
  } == completedAt)
  #expect(await calls.value() == 1)
  do { _ = try await revoked.complete(context, uploadID: session.uploadID); Issue.record("revoked replayed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  #expect(try await uploadCatalogValue(context,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: reference.key) == "uploaded_unbound")
  try await context.executeGraphSave(comment: "bind verified upload") { actor, session in
    _ = try await actor.execute(Mutation(kind: .create, entity: asset,
      values: ["id": .int(1), "name": .string("document")], auditReason: session.intent.comment))
    _ = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "1", field: "file"),
        next: reference, expectedVersion: 0, nextVersion: 1, action: "Create"),
      authorization: UploadBindingPermission())
  }
  #expect(try await uploadCatalogValue(context,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: reference.key) == "available")
  #expect(try await service.complete(context, uploadID: session.uploadID) == reference)
  #expect(await calls.value() == 1)
  let completedKey = try #require(await uploadCatalogValue(context,
    sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: reference.key))
  _ = try await context.objectStorage("replace completed generation").putBytes(
    try ObjectKey(completedKey), data: data,
    options: ObjectPutOptions(size: Int64(data.count), mode: .replace, contentType: "application/pdf"))
  do { _ = try await service.complete(context, uploadID: session.uploadID); Issue.record("replaced replayed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }
  #expect(await calls.value() == 1)

  let second = try await service.begin(context, target: target, input: input, replayKey: "request-2")
  _ = try await service.write(context, uploadID: second.uploadID, source: ObjectDataReader(data))
  let raw = try #require(await uploadCatalogValue(context,
    sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: second.reference.key))
  _ = try await context.objectStorage("replace same bytes").putBytes(try ObjectKey(raw), data: data,
    options: ObjectPutOptions(size: Int64(data.count), mode: .replace, contentType: "application/pdf"))
  do { _ = try await service.complete(context, uploadID: second.uploadID); Issue.record("replacement confirmed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }

  let third = try await service.begin(context, target: target, input: input, replayKey: "request-3")
  _ = try await service.write(context, uploadID: third.uploadID, source: ObjectDataReader(data))
  let early = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(early: true), maximumBytes: 10_000)
  do { _ = try await early.complete(context, uploadID: third.uploadID); Issue.record("early verifier confirmed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }

  let fourth = try await service.begin(context, target: target, input: input, replayKey: "request-4")
  do {
    _ = try await service.write(context, uploadID: fourth.uploadID,
      source: ObjectDataReader(data + Data("x".utf8)))
    Issue.record("oversized upload accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_STORE_FAILED")) }
  let fifth = try await service.begin(context, target: target, input: input, replayKey: "request-5")
  do {
    _ = try await service.write(context, uploadID: fifth.uploadID,
      source: ObjectDataReader(Data(data.dropLast())))
    Issue.record("short upload accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_STORE_FAILED")) }

  let expiring = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000, leaseSeconds: 1)
  let old = try await expiring.begin(context, target: target, input: input,
    replayKey: "expired-request")
  #expect(try await expiring.begin(context, target: target, input: input,
    replayKey: "expired-request").uploadID == old.uploadID)
  try await Task.sleep(nanoseconds: 1_100_000_000)
  do {
    _ = try await expiring.begin(context, target: target, input: input,
      replayKey: "expired-request")
    Issue.record("expired replay recovered its old session")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_EXPIRED")) }
  let fresh = try await expiring.begin(context, target: target, input: input,
    replayKey: "fresh-request")
  #expect(fresh.uploadID != old.uploadID)
  do {
    _ = try await expiring.write(context, uploadID: old.uploadID, source: ObjectDataReader(data))
    Issue.record("expired session wrote bytes")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_EXPIRED")) }
}

private func imageFixture(_ ext: String) throws -> Data {
  let actual = ext == "jpeg" ? "jpg" : ext
  let url = try #require(Bundle.module.url(forResource: "sample", withExtension: actual,
    subdirectory: "fixtures"))
  return try Data(contentsOf: url)
}

@Test
func swiftRealOfficeVerifierChecksCompletePackagesAndBounds() async throws {
  let verifier = try OfficeBlobContentVerifier()
  for (ext, mime) in [
    ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
  ] {
    let data = try imageFixture(ext)
    let verified = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
      maximumBytes: 100_000)
    #expect(verified.sizeBytes == Int64(data.count))
    #expect(verified.contentType == mime)
    #expect(verified.sha256 == SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }.joined())
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(Data(data.dropLast(2))),
        extension: ext, maximumBytes: 100_000)
      Issue.record("truncated Office ZIP accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
        maximumBytes: Int64(data.count - 1))
      Issue.record("oversized Office ZIP accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_SIZE_EXCEEDED")) }
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(data),
        extension: ext == "docx" ? "xlsx" : "docx", maximumBytes: 100_000)
      Issue.record("wrong Office package type accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    var damaged = data
    damaged[damaged.count / 2] ^= 1
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(damaged), extension: ext,
        maximumBytes: 100_000)
      Issue.record("damaged Office ZIP accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    var ambiguousHeader = data
    ambiguousHeader[6] ^= 1 // Mismatch between first local and central ZIP flags.
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(ambiguousHeader), extension: ext,
        maximumBytes: 100_000)
      Issue.record("inconsistent ZIP local header accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    let tiny = try OfficeBlobContentVerifier(maximumDecodedBytes: 1)
    do {
      _ = try await tiny.verify(reader: ObjectDataReader(data), extension: ext,
        maximumBytes: 100_000)
      Issue.record("expanded ZIP bound bypassed")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  }
}

@Test
func swiftRealOfficeVerifierRejectsBusyAdmission() async throws {
  let data = try imageFixture("docx")
  let verifier = try OfficeBlobContentVerifier(concurrentVerifications: 1)
  let slow = PausedUploadReader(data)
  let first = Task { try await verifier.verify(reader: slow, extension: "docx",
    maximumBytes: 100_000) }
  await slow.entered.wait()
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "docx",
      maximumBytes: 100_000)
    Issue.record("busy Office verifier admitted another package")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_VERIFICATION_BUSY")) }
  await slow.release.release()
  #expect(try await first.value.sizeBytes == Int64(data.count))
}

@Test
func swiftRealOfficeVerifierRejectsValidZipWithDTD() async throws {
  let url = try #require(Bundle.module.url(forResource: "sample-dtd", withExtension: "docx",
    subdirectory: "fixtures"))
  let data = try Data(contentsOf: url)
  do {
    _ = try await OfficeBlobContentVerifier().verify(reader: ObjectDataReader(data),
      extension: "docx", maximumBytes: 100_000)
    Issue.record("valid ZIP containing XML DTD was accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
}

@Test
func swiftCompositeVerifierDispatchesOfficeBesideImage() async throws {
  let verifier = try CompositeBlobContentVerifier(routes: [
    BlobVerifierRoute(extensions: ["jpg", "png"], verifier: StbImageBlobContentVerifier()),
    BlobVerifierRoute(extensions: ["docx", "xlsx"], verifier: OfficeBlobContentVerifier()),
  ])
  #expect(verifier.supportedExtensions == ["docx", "jpg", "png", "xlsx"])
  for ext in ["jpg", "docx", "xlsx"] {
    let data = try imageFixture(ext)
    let actual = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
      maximumBytes: 100_000)
    #expect(actual.sizeBytes == Int64(data.count))
  }
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(try imageFixture("docx")),
      extension: "pdf", maximumBytes: 100_000)
    Issue.record("unregistered PDF route accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
}

@Test
func swiftSQLiteFileOfficeUploadRequiresFullDecode() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-office-upload-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try FileObjectStorage(root: root.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install Office upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true,
      extensions: ["docx", "xlsx"]), verifier: OfficeBlobContentVerifier(),
    maximumBytes: 100_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  for ext in ["docx", "xlsx"] {
    let data = try imageFixture(ext)
    let good = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(data.count)),
      replayKey: "office-valid-\(ext)")
    _ = try await service.write(actor, uploadID: good.uploadID, source: ObjectDataReader(data))
    #expect(try await service.complete(actor, uploadID: good.uploadID) == good.reference)
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
      == "uploaded_unbound")
    let truncated = Data(data.dropLast(2))
    let bad = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(truncated.count)),
      replayKey: "office-truncated-\(ext)")
    _ = try await service.write(actor, uploadID: bad.uploadID, source: ObjectDataReader(truncated))
    do { _ = try await service.complete(actor, uploadID: bad.uploadID)
      Issue.record("truncated Office upload promoted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: bad.reference.key)
      == "initiated")
  }
}

#if os(Linux)
private func legacyOfficeVerifier(scratch: String,
                                  maximumConvertedBytes: Int64 = 10 * 1024 * 1024,
                                  concurrentVerifications: Int = 2) throws
  -> LegacyOfficeBlobContentVerifier {
  try LegacyOfficeBlobContentVerifier(sofficePath: "/usr/bin/soffice",
    bwrapPath: "/usr/bin/bwrap", limitPath: "/usr/bin/prlimit", scratchRoot: scratch,
    maximumInputBytes: 100_000, maximumConvertedBytes: maximumConvertedBytes,
    concurrentVerifications: concurrentVerifications)
}

@Test
func swiftLegacyOfficeVerifierChecksOriginalBytesAndBounds() async throws {
  let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-legacy-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: scratch) }
  let verifier = try legacyOfficeVerifier(scratch: scratch.path)
  try await verifier.validateReady()
  for (ext, mime, digest) in [
    ("doc", "application/msword",
     "9fca8d262d2aa905d58b1cc1c8914d1a8069c16c340f24cd3c4a77daff9c8b73"),
    ("xls", "application/vnd.ms-excel",
     "7f387858aaa3ed39d3c7c692aa865b36ac6620462714f3d0daa96388424cf75d"),
  ] {
    let data = try imageFixture(ext)
    let verified = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
      maximumBytes: Int64(data.count))
    #expect(verified.sizeBytes == Int64(data.count))
    #expect(verified.sha256 == digest)
    #expect(verified.contentType == mime)
    for invalid in [Data(data.dropLast(1)), Data(data.prefix(600))] {
      do {
        _ = try await verifier.verify(reader: ObjectDataReader(invalid), extension: ext,
          maximumBytes: Int64(invalid.count))
        Issue.record("truncated CFB accepted")
      } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    }
    var tampered = data; tampered[0] ^= 1
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(tampered), extension: ext,
        maximumBytes: Int64(tampered.count))
      Issue.record("tampered CFB header accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
        maximumBytes: Int64(data.count - 1))
      Issue.record("oversize CFB accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_SIZE_EXCEEDED")) }
    do {
      _ = try await legacyOfficeVerifier(scratch: scratch.path,
        maximumConvertedBytes: 1).verify(reader: ObjectDataReader(data),
          extension: ext, maximumBytes: Int64(data.count))
      Issue.record("converted size limit bypassed")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
}

@Test
func swiftLegacyOfficeVerifierChecksAdmissionReadinessAndComposite() async throws {
  let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-legacy-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: scratch) }
  let data = try imageFixture("doc")
  let verifier = try legacyOfficeVerifier(scratch: scratch.path, concurrentVerifications: 1)
  let slow = PausedUploadReader(data)
  let first = Task { try await verifier.verify(reader: slow, extension: "doc",
    maximumBytes: Int64(data.count)) }
  await slow.entered.wait()
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "doc",
      maximumBytes: Int64(data.count))
    Issue.record("busy legacy Office verifier admitted another upload")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_VERIFICATION_BUSY")) }
  await slow.release.release()
  #expect(try await first.value.sizeBytes == Int64(data.count))
  let missing = try LegacyOfficeBlobContentVerifier(sofficePath: "/missing/soffice",
    bwrapPath: "/usr/bin/bwrap", limitPath: "/usr/bin/prlimit",
    scratchRoot: scratch.path)
  do { try await missing.validateReady(); Issue.record("missing LibreOffice accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_CAPABILITY_MISSING")) }
  let composite = try CompositeBlobContentVerifier(routes: [
    BlobVerifierRoute(extensions: ["jpg"], verifier: StbImageBlobContentVerifier()),
    BlobVerifierRoute(extensions: ["doc", "xls"], verifier: verifier),
  ])
  try await composite.validateReady()
  #expect(try await composite.verify(reader: ObjectDataReader(data), extension: "doc",
    maximumBytes: Int64(data.count)).contentType == "application/msword")
}

@Test
func swiftSQLiteFileLegacyOfficeUploadRequiresFullDecode() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-legacy-upload-\(UUID().uuidString)",
      isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let scratch = root.appendingPathComponent("scratch", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700])
  let store = try FileObjectStorage(root: root.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install legacy Office upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true,
      extensions: ["doc", "xls"]), verifier: legacyOfficeVerifier(scratch: scratch.path),
    maximumBytes: 100_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  for (ext, mime) in [("doc", "application/msword"),
                       ("xls", "application/vnd.ms-excel")] {
    let data = try imageFixture(ext)
    let good = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(data.count)),
      replayKey: "legacy-valid-\(ext)")
    _ = try await service.write(actor, uploadID: good.uploadID, source: ObjectDataReader(data))
    #expect(try await service.complete(actor, uploadID: good.uploadID) == good.reference)
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
      == "uploaded_unbound")
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT content_type FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
      == mime)
    let truncated = Data(data.dropLast(1))
    let bad = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "broken.\(ext)", declaredSize: Int64(truncated.count)),
      replayKey: "legacy-bad-\(ext)")
    _ = try await service.write(actor, uploadID: bad.uploadID,
      source: ObjectDataReader(truncated))
    do { _ = try await service.complete(actor, uploadID: bad.uploadID)
      Issue.record("truncated legacy Office upload promoted") }
    catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: bad.reference.key)
      == "initiated")
  }
}

private func pdfVerifier(maximumPages: Int = 100, maximumRenderedBytes: Int = 4 * 1024 * 1024,
                         concurrentVerifications: Int = 2) throws -> PopplerBlobContentVerifier {
  try PopplerBlobContentVerifier(infoPath: "/usr/bin/pdfinfo",
    renderPath: "/usr/bin/pdftoppm", limitPath: "/usr/bin/prlimit",
    maximumInputBytes: 100_000, maximumPages: maximumPages,
    maximumRenderedBytes: maximumRenderedBytes,
    concurrentVerifications: concurrentVerifications)
}

@Test
func swiftRealPDFVerifierRendersAllPagesAndRejectsInvalidFiles() async throws {
  let data = try imageFixture("pdf")
  let verifier = try pdfVerifier()
  try await verifier.validateReady()
  let verified = try await verifier.verify(reader: ObjectDataReader(data), extension: "pdf",
    maximumBytes: Int64(data.count))
  #expect(verified.sizeBytes == Int64(data.count))
  #expect(verified.sha256 == "4b6a645a3ed4736baaa092cffa6e06fd3176866f589edd2b748565ad6487731b")
  #expect(verified.contentType == "application/pdf")
  var trailing = data; trailing.append(0x78)
  for invalid in [Data(data.dropLast(2)), trailing,
                  Data("%PDF-1.7\nstartxref\n0\n%%EOF".utf8)] {
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(invalid), extension: "pdf",
        maximumBytes: Int64(invalid.count))
      Issue.record("malformed PDF accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  }
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "docx",
      maximumBytes: Int64(data.count))
    Issue.record("wrong PDF extension accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "pdf",
      maximumBytes: Int64(data.count - 1))
    Issue.record("oversize PDF accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_SIZE_EXCEEDED")) }
  do {
    _ = try await pdfVerifier(maximumRenderedBytes: 1).verify(
      reader: ObjectDataReader(data), extension: "pdf", maximumBytes: Int64(data.count))
    Issue.record("render output cap bypassed")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  let url = try #require(Bundle.module.url(forResource: "two-page", withExtension: "pdf",
    subdirectory: "fixtures"))
  let two = try Data(contentsOf: url)
  #expect(try await verifier.verify(reader: ObjectDataReader(two), extension: "pdf",
    maximumBytes: Int64(two.count)).sizeBytes == Int64(two.count))
  do {
    _ = try await pdfVerifier(maximumPages: 1).verify(reader: ObjectDataReader(two),
      extension: "pdf", maximumBytes: Int64(two.count))
    Issue.record("page cap bypassed")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
}

@Test
func swiftRealPDFVerifierChecksBusyReadinessAndComposite() async throws {
  let data = try imageFixture("pdf")
  let verifier = try pdfVerifier(concurrentVerifications: 1)
  let slow = PausedUploadReader(data)
  let first = Task { try await verifier.verify(reader: slow, extension: "pdf",
    maximumBytes: Int64(data.count)) }
  await slow.entered.wait()
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "pdf",
      maximumBytes: Int64(data.count))
    Issue.record("busy PDF verifier admitted another upload")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_VERIFICATION_BUSY")) }
  await slow.release.release()
  #expect(try await first.value.sizeBytes == Int64(data.count))
  let missing = try PopplerBlobContentVerifier(infoPath: "/missing/pdfinfo",
    renderPath: "/usr/bin/pdftoppm", limitPath: "/usr/bin/prlimit")
  do { try await missing.validateReady(); Issue.record("missing PDF tool accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_CAPABILITY_MISSING")) }
  let composite = try CompositeBlobContentVerifier(routes: [
    BlobVerifierRoute(extensions: ["jpg"], verifier: StbImageBlobContentVerifier()),
    BlobVerifierRoute(extensions: ["pdf"], verifier: verifier),
  ])
  try await composite.validateReady()
  #expect(try await composite.verify(reader: ObjectDataReader(data), extension: "pdf",
    maximumBytes: Int64(data.count)).contentType == "application/pdf")
}

@Test
func swiftSQLiteFilePDFUploadRequiresFullDecode() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-pdf-upload-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try FileObjectStorage(root: root.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install PDF upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true,
      extensions: ["pdf"]), verifier: pdfVerifier(), maximumBytes: 100_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  let data = try imageFixture("pdf")
  let good = try await service.begin(actor, target: target,
    input: BlobUploadInput(fileName: "sample.pdf", declaredSize: Int64(data.count)),
    replayKey: "pdf-valid")
  _ = try await service.write(actor, uploadID: good.uploadID, source: ObjectDataReader(data))
  #expect(try await service.complete(actor, uploadID: good.uploadID) == good.reference)
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
    == "uploaded_unbound")
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT content_type FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
    == "application/pdf")
  let truncated = Data(data.dropLast(12))
  let bad = try await service.begin(actor, target: target,
    input: BlobUploadInput(fileName: "broken.pdf", declaredSize: Int64(truncated.count)),
    replayKey: "pdf-truncated")
  _ = try await service.write(actor, uploadID: bad.uploadID,
    source: ObjectDataReader(truncated))
  do { _ = try await service.complete(actor, uploadID: bad.uploadID)
    Issue.record("truncated PDF upload promoted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  #expect(try await uploadCatalogValue(actor,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: bad.reference.key)
    == "initiated")
}

private func mediaVerifier(maximumFrames: Int = 100_000, maximumVideoPixels: Int64 = 16_000_000,
                           concurrentVerifications: Int = 2) throws -> FfmpegBlobContentVerifier {
  try FfmpegBlobContentVerifier(probePath: "/usr/bin/ffprobe", decodePath: "/usr/bin/ffmpeg",
    limitPath: "/usr/bin/prlimit", maximumFrames: maximumFrames,
    maximumVideoPixels: maximumVideoPixels, concurrentVerifications: concurrentVerifications)
}

@Test
func swiftRealMediaVerifierFullyDecodesAndBoundsSharedFixtures() async throws {
  let verifier = try mediaVerifier()
  try await verifier.validateReady()
  for (ext, mime) in [("mp3", "audio/mpeg"), ("mp4", "video/mp4")] {
    let data = try imageFixture(ext)
    let verified = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
      maximumBytes: 100_000)
    #expect(verified.sizeBytes == Int64(data.count))
    #expect(verified.contentType == mime)
    #expect(verified.sha256 == SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }.joined())
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(Data(data.dropLast(2))),
        extension: ext, maximumBytes: 100_000)
      Issue.record("truncated media accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
        maximumBytes: Int64(data.count - 1))
      Issue.record("oversized media accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_SIZE_EXCEEDED")) }
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(data),
        extension: ext == "mp3" ? "mp4" : "mp3", maximumBytes: 100_000)
      Issue.record("wrong media format accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  }
  let audioOnly = try #require(Bundle.module.url(forResource: "audio-only",
    withExtension: "mp4", subdirectory: "fixtures"))
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(Data(contentsOf: audioOnly)),
      extension: "mp4", maximumBytes: 100_000)
    Issue.record("audio-only MP4 accepted as video")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  do {
    _ = try await mediaVerifier(maximumFrames: 1).verify(
      reader: ObjectDataReader(try imageFixture("mp3")), extension: "mp3",
      maximumBytes: 100_000)
    Issue.record("frame bound bypassed")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  do {
    _ = try await mediaVerifier(maximumVideoPixels: 1).verify(
      reader: ObjectDataReader(try imageFixture("mp4")), extension: "mp4",
      maximumBytes: 100_000)
    Issue.record("pixel bound bypassed")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
}

@Test
func swiftRealMediaVerifierRejectsBusyAndMissingHostBinary() async throws {
  let data = try imageFixture("mp3")
  let verifier = try mediaVerifier(concurrentVerifications: 1)
  let slow = PausedUploadReader(data)
  let first = Task { try await verifier.verify(reader: slow, extension: "mp3", maximumBytes: 100_000) }
  await slow.entered.wait()
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "mp3",
      maximumBytes: 100_000)
    Issue.record("busy media verifier admitted another decode")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_VERIFICATION_BUSY")) }
  await slow.release.release()
  #expect(try await first.value.sizeBytes == Int64(data.count))
  let missing = try FfmpegBlobContentVerifier(probePath: "/missing/ffprobe",
    decodePath: "/usr/bin/ffmpeg", limitPath: "/usr/bin/prlimit")
  do { try await missing.validateReady(); Issue.record("missing binary was ready") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_CAPABILITY_MISSING")) }
}

@Test
func swiftSQLiteFileMediaUploadRequiresFullDecode() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-media-upload-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try FileObjectStorage(root: root.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install media upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true,
      extensions: ["mp3", "mp4"]), verifier: mediaVerifier(), maximumBytes: 100_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  for ext in ["mp3", "mp4"] {
    let data = try imageFixture(ext)
    let good = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(data.count)),
      replayKey: "media-valid-\(ext)")
    _ = try await service.write(actor, uploadID: good.uploadID, source: ObjectDataReader(data))
    #expect(try await service.complete(actor, uploadID: good.uploadID) == good.reference)
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
      == "uploaded_unbound")
    let truncated = Data(data.dropLast(2))
    let bad = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(truncated.count)),
      replayKey: "media-truncated-\(ext)")
    _ = try await service.write(actor, uploadID: bad.uploadID, source: ObjectDataReader(truncated))
    do { _ = try await service.complete(actor, uploadID: bad.uploadID)
      Issue.record("truncated media upload promoted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: bad.reference.key)
      == "initiated")
  }
}

private actor UnreadableCompositeSource: ObjectByteReader {
  func read(upToCount: Int) throws -> Data { throw TeaQLError.execution("SOURCE_READ") }
  func close() {}
}

@Test
func swiftCompositeVerifierDispatchesRealImageAndMedia() async throws {
  let image = try StbImageBlobContentVerifier()
  let media = try mediaVerifier()
  let verifier = try CompositeBlobContentVerifier(routes: [
    BlobVerifierRoute(extensions: ["jpg", "jpeg", "png"], verifier: image),
    BlobVerifierRoute(extensions: ["mp3", "mp4"], verifier: media),
  ])
  #expect(verifier.supportedExtensions == ["jpeg", "jpg", "mp3", "mp4", "png"])
  try await verifier.validateReady()
  for (ext, mime) in [("jpg", "image/jpeg"), ("mp3", "audio/mpeg")] {
    let data = try imageFixture(ext)
    let actual = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
      maximumBytes: Int64(data.count))
    #expect(actual.sizeBytes == Int64(data.count))
    #expect(actual.contentType == mime)
    #expect(actual.sha256 == SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }.joined())
  }
  do {
    _ = try await verifier.verify(reader: UnreadableCompositeSource(), extension: "docx",
      maximumBytes: 1024)
    Issue.record("unregistered route accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  do {
    _ = try CompositeBlobContentVerifier(routes: [
      BlobVerifierRoute(extensions: ["jpg"], verifier: image),
      BlobVerifierRoute(extensions: ["jpg"], verifier: media),
    ])
    Issue.record("duplicate route accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_POLICY_INVALID")) }
}
#endif

@Test
func swiftRealImageVerifierDecodesAndBoundsSharedFixtures() async throws {
  let verifier = try StbImageBlobContentVerifier()
  for ext in ["jpg", "jpeg", "png"] {
    let data = try imageFixture(ext)
    let verified = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
      maximumBytes: 100_000)
    #expect(verified.sizeBytes == Int64(data.count))
    #expect(verified.contentType == (ext == "png" ? "image/png" : "image/jpeg"))
    #expect(verified.sha256 == SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }.joined())
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(Data(data.dropLast(2))),
        extension: ext, maximumBytes: 100_000)
      Issue.record("truncated image accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    do {
      _ = try await verifier.verify(reader: ObjectDataReader(data), extension: ext,
        maximumBytes: Int64(data.count - 1))
      Issue.record("oversized image accepted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_SIZE_EXCEEDED")) }
  }
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(try imageFixture("png")),
      extension: "jpg", maximumBytes: 100_000)
    Issue.record("wrong image format accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  var damaged = try imageFixture("png")
  damaged[41] ^= 1 // First IDAT payload byte of the pinned 16x16 fixture.
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(damaged), extension: "png",
      maximumBytes: 100_000)
    Issue.record("corrupt PNG CRC accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
  let tinyPixels = try StbImageBlobContentVerifier(maximumDecodedBytes: 4)
  do {
    _ = try await tinyPixels.verify(reader: ObjectDataReader(try imageFixture("png")),
      extension: "png", maximumBytes: 100_000)
    Issue.record("decoded pixel limit bypassed")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
}

@Test
func swiftRealImageVerifierRejectsBusyAdmissionAndReleasesSlot() async throws {
  let data = try imageFixture("png")
  let verifier = try StbImageBlobContentVerifier(concurrentVerifications: 1)
  let slow = PausedUploadReader(data)
  let first = Task { try await verifier.verify(reader: slow, extension: "png", maximumBytes: 100_000) }
  await slow.entered.wait()
  do {
    _ = try await verifier.verify(reader: ObjectDataReader(data), extension: "png",
      maximumBytes: 100_000)
    Issue.record("busy verifier admitted another decode")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_VERIFICATION_BUSY")) }
  await slow.release.release()
  #expect(try await first.value.sizeBytes == Int64(data.count))
  #expect(try await verifier.verify(reader: ObjectDataReader(data), extension: "png",
    maximumBytes: 100_000).sizeBytes == Int64(data.count))
}

@Test
func swiftSQLiteFileImageUploadRequiresFullDecode() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-image-upload-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try FileObjectStorage(root: root.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let database = try SQLiteDataService(path: ":memory:")
  let actor = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
  let catalog = SQLiteBlobCatalog()
  try await actor.executeGraphSave(comment: "install image upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true,
      extensions: ["jpg", "png"]),
    verifier: StbImageBlobContentVerifier(), maximumBytes: 100_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  for ext in ["jpg", "png"] {
    let data = try imageFixture(ext)
    let input = BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(data.count))
    let good = try await service.begin(actor, target: target, input: input,
      replayKey: "image-valid-\(ext)")
    _ = try await service.write(actor, uploadID: good.uploadID, source: ObjectDataReader(data))
    #expect(try await service.complete(actor, uploadID: good.uploadID) == good.reference)
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: good.reference.key)
      == "uploaded_unbound")

    let truncated = Data(data.dropLast(2))
    let bad = try await service.begin(actor, target: target,
      input: BlobUploadInput(fileName: "sample.\(ext)", declaredSize: Int64(truncated.count)),
      replayKey: "image-truncated-\(ext)")
    _ = try await service.write(actor, uploadID: bad.uploadID, source: ObjectDataReader(truncated))
    do {
      _ = try await service.complete(actor, uploadID: bad.uploadID)
      Issue.record("truncated upload promoted")
    } catch { #expect(error as? TeaQLError == .execution("BLOB_FORMAT_NOT_ALLOWED")) }
    #expect(try await uploadCatalogValue(actor,
      sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: bad.reference.key)
      == "initiated")
  }
}
