import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TeaQLCore
import TeaQLObjectStorageS3
import SotoS3

private struct UnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw StorageError(.unsupported) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw StorageError(.unsupported) }
}
private func context() -> UserContext { UserContext(queryExecutor: UnusedExecutor(), mutationExecutor: UnusedExecutor(), requestPolicy: RequestPolicy { $0 }) }
private struct AssertionFailure: Error { let check: String }
private func require(_ condition: Bool, _ check: String) throws { if !condition { throw AssertionFailure(check: check) } }
private func expect(_ code: StorageErrorCode, _ operation: () async throws -> Void) async throws {
  do { try await operation() }
  catch let error as StorageError { try require(error.code == code, "failure category"); return }
  throw AssertionFailure(check: "expected " + code.rawValue)
}
private final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ObjectStorageEvent] = []
  func record(_ event: ObjectStorageEvent) { lock.lock(); defer { lock.unlock() }; values.append(event) }
  var events: [ObjectStorageEvent] { lock.lock(); defer { lock.unlock() }; return values }
}
@main
struct Main {
  static func main() async {
    do { try await run() }
    catch let error as StorageError { print(error.description); exit(1) }
    catch let error as AssertionFailure { print("Object storage assertion: " + error.check); exit(1) }
    catch { print("Object storage example failed type=" + String(reflecting: type(of: error))); exit(1) }
  }
  static func run() async throws {
    let env = ProcessInfo.processInfo.environment, bucket = env["TEAQL_S3_BUCKET"]!
    let client = AWSClient(credentialProvider: .static(accessKeyId: env["TEAQL_S3_ACCESS_KEY"]!, secretAccessKey: env["TEAQL_S3_SECRET_KEY"]!), retryPolicy: .noRetry)
    let service = S3(client: client, region: .useast1, endpoint: env["TEAQL_S3_ENDPOINT"]!, timeout: .seconds(5), options: [.s3Disable100Continue])
    do { _ = try await service.headBucket(.init(bucket: bucket)) }
    catch { guard (error as? any AWSErrorType)?.context?.responseCode.code == 404 else { try? await client.shutdown(); throw StorageError(.unavailable) }; _ = try await service.createBucket(.init(bucket: bucket)) }
    let provider = try S3ObjectStorage(service: service, bucket: bucket), events = Events()
    let storage = try context().withObjectStorage(provider).withObjectStorageObserver { events.record($0) }.objectStorage("verify binary object storage")
    let prefix = "swift-example/" + UUID().uuidString + "/"
    let key = try ObjectKey(prefix + "收据 +% binary"), empty = try ObjectKey(prefix + "empty"), race = try ObjectKey(prefix + "race")
    let data = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
    do {
      try require(!(try await storage.exists(key)), "missing object")
      try await expect(.notFound) { _ = try await storage.get(key) }
      _ = try await storage.putBytes(key, data: data, options: ObjectPutOptions(size: Int64(data.count), mode: .createOnly, metadata: ["example": "binary"]))
      let metadata = try await storage.head(key)
      try require(metadata?.size == Int64(data.count) && metadata?.customMetadata["example"] == "binary" && metadata?.etag != nil, "metadata")
      try require(try await storage.getBytes(key, maximumBytes: data.count) == data, "binary bytes")
      let partial = try await storage.get(key); _ = try await partial.reader.read(upToCount: 1); try await partial.close()
      try await expect(.conflict) { _ = try await storage.putBytes(key, data: Data(), options: ObjectPutOptions(size: 0, mode: .createOnly)) }
      try await expect(.tooLarge) { _ = try await storage.getBytes(key, maximumBytes: 1) }
      let link = try await storage.getReadUrl(key, options: ObjectReadUrlOptions(disposition: "attachment", filename: "receipt.bin"))
      let (bytes, response) = try await URLSession.shared.data(from: link.url)
      try require(bytes == data && (response as? HTTPURLResponse)?.statusCode == 200, "URL download")
      try require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") == "attachment; filename=\"receipt.bin\"", "URL disposition")
      let expired = try await storage.getReadUrl(key, options: ObjectReadUrlOptions(seconds: 1)); try await Task.sleep(for: .milliseconds(2200))
      let (_, denied) = try await URLSession.shared.data(from: expired.url); try require((denied as? HTTPURLResponse)?.statusCode == 403, "URL expiry")
      _ = try await storage.putBytes(empty, data: Data(), options: ObjectPutOptions(size: 0, mode: .createOnly)); try require(try await storage.getBytes(empty, maximumBytes: 0).isEmpty, "empty object")
      try await expect(.invalidInput) { _ = try await storage.putBytes(key, data: Data([1, 2]), options: ObjectPutOptions(size: 1, mode: .replace)) }
      try require(try await storage.getBytes(key, maximumBytes: data.count) == data, "invalid upload preserved bytes")
      _ = try await storage.putBytes(key, data: Data([1, 2, 3]), options: ObjectPutOptions(size: 3, mode: .replace)); try require(try await storage.getBytes(key, maximumBytes: 3) == Data([1, 2, 3]), "replacement")
      let other = try context().withObjectStorage(provider).withObjectStorageObserver { events.record($0) }.objectStorage("verify atomic create")
      func create(_ api: ObjectStorage) async throws -> Bool { do { _ = try await api.putBytes(race, data: Data([1]), options: ObjectPutOptions(size: 1, mode: .createOnly)); return true } catch let error as StorageError { try require(error.code == .conflict, "concurrent conflict"); return false } }
      async let first = create(storage); async let second = create(other); let outcomes = try await [first, second]; try require(outcomes.filter { $0 }.count == 1, "one creator")
      let missing = try context().withObjectStorage(S3ObjectStorage(service: service, bucket: "missing-" + UUID().uuidString.lowercased())).objectStorage("verify missing bucket")
      try await expect(.unavailable) { _ = try await missing.exists(key) }
      for item in [key, empty, race] { try await storage.delete(item); try await storage.delete(item); try require(!(try await storage.exists(item)), "repeated delete") }
      try require(Set(events.events.map(\.contextID)).count == 2, "distinct context observations")
      try require(!String(reflecting: events.events).contains(prefix), "safe observations")
      try await client.shutdown()
      print("PASS Swift S3: binary, empty, metadata, URL download/expiry, atomic create, replace, bounded reads, missing bucket, repeated delete")
    } catch {
      for item in [key, empty, race] { try? await storage.delete(item) }
      try? await client.shutdown(); throw error
    }
  }
}
