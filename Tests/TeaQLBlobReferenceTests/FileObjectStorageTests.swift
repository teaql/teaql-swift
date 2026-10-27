import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct FileUnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw StorageError(.unsupported) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw StorageError(.unsupported) }
}

private func expectStoreError(_ code: StorageErrorCode, _ work: () async throws -> Void) async {
  do { try await work(); Issue.record("Expected \(code)") }
  catch let error as StorageError { #expect(error.code == code) }
  catch { Issue.record("Unexpected storage error type") }
}

@Test
func swiftFileStoreServesAuthenticatedRealBytesOverLoopback() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-file-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let context = UserContext(queryExecutor: FileUnusedExecutor(), mutationExecutor: FileUnusedExecutor(),
    requestPolicy: RequestPolicy { $0 })
  let storage = try context.withObjectStorage(store).objectStorage("verify real File and HTTP")
  let key = try ObjectKey("private/report.pdf")
  await expectStoreError(.notConfigured) { _ = try await storage.getReadUrl(key) }
  #expect(try store.start().host == "127.0.0.1")
  #expect(try await storage.head(key)?.size == nil)
  let bytes = Data("%PDF-1.4\nreal bytes\n%%EOF".utf8)
  let create = try ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly,
    contentType: "application/pdf")
  let metadata = try await storage.putBytes(key, data: bytes, options: create)
  #expect(metadata.size == Int64(bytes.count))
  await expectStoreError(.conflict) { _ = try await storage.putBytes(key, data: bytes, options: create) }
  let short = try ObjectPutOptions(size: Int64(bytes.count + 1), mode: .replace)
  await expectStoreError(.invalidInput) { _ = try await storage.putBytes(key, data: bytes, options: short) }
  #expect(try await storage.getBytes(key, maximumBytes: 100) == bytes)

  let options = try ObjectReadUrlOptions(seconds: 5, disposition: "attachment", filename: "report.pdf")
  let link = try await storage.getReadUrl(key, options: options)
  #expect(!link.url.absoluteString.contains(key.value))
  let session = URLSession(configuration: .ephemeral)
  defer { session.invalidateAndCancel() }
  let (body, got) = try await session.data(from: link.url)
  #expect((got as? HTTPURLResponse)?.statusCode == 200)
  #expect(body == bytes)
  #expect((got as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
  #expect((got as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ==
    "attachment; filename=\"report.pdf\"")
  var head = URLRequest(url: link.url); head.httpMethod = "HEAD"
  let (_, headResponse) = try await session.data(for: head)
  #expect((headResponse as? HTTPURLResponse)?.statusCode == 200)
  #expect((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == "\(bytes.count)")
  var range = URLRequest(url: link.url); range.setValue("bytes=0-3", forHTTPHeaderField: "Range")
  let (prefix, partial) = try await session.data(for: range)
  #expect((partial as? HTTPURLResponse)?.statusCode == 206)
  #expect(prefix == Data(bytes.prefix(4)))
  #expect((partial as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes 0-3/\(bytes.count)")
  var suffix = URLRequest(url: link.url); suffix.setValue("bytes=-3", forHTTPHeaderField: "Range")
  let (ending, suffixResponse) = try await session.data(for: suffix)
  #expect((suffixResponse as? HTTPURLResponse)?.statusCode == 206)
  #expect(ending == Data(bytes.suffix(3)))
  var badRange = URLRequest(url: link.url)
  badRange.setValue("bytes=999-", forHTTPHeaderField: "Range")
  let (_, badResponse) = try await session.data(for: badRange)
  #expect((badResponse as? HTTPURLResponse)?.statusCode == 416)

  var token = Array(link.url.absoluteString)
  let changed = token.count - 12
  token[changed] = token[changed] == "A" ? "B" : "A"
  let (_, tampered) = try await session.data(from: URL(string: String(token))!)
  #expect((tampered as? HTTPURLResponse)?.statusCode == 404)
  let expiring = try await storage.getReadUrl(key, options: ObjectReadUrlOptions(seconds: 1))
  try await Task.sleep(for: .milliseconds(1200))
  let (_, expiredResponse) = try await session.data(from: expiring.url)
  #expect((expiredResponse as? HTTPURLResponse)?.statusCode == 404)

  let replacement = Data("replacement".utf8)
  _ = try await storage.putBytes(key, data: replacement,
    options: ObjectPutOptions(size: Int64(replacement.count), mode: .replace, contentType: "text/plain"))
  let (_, stale) = try await session.data(from: link.url)
  #expect((stale as? HTTPURLResponse)?.statusCode == 404)
  #expect(try await storage.getBytes(key, maximumBytes: 100) == replacement)
  let current = try await storage.getReadUrl(key)
  let hash = SHA256.hash(data: Data(key.value.utf8)).map { String(format: "%02x", $0) }.joined()
  let directory = parent.appendingPathComponent("private/\(hash.prefix(2))/\(hash)")
  for item in try FileManager.default.contentsOfDirectory(at: directory,
    includingPropertiesForKeys: nil) where item.lastPathComponent.hasPrefix("data-") {
    try FileManager.default.removeItem(at: item)
  }
  await expectStoreError(.unavailable) { _ = try await storage.head(key) }
  let (_, absent) = try await session.data(from: current.url)
  #expect((absent as? HTTPURLResponse)?.statusCode == 404)
  try await storage.delete(key)
  #expect(try await storage.head(key)?.size == nil)
}
