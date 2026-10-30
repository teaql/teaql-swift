import Foundation
import XCTest
@testable import TeaQLCore

private struct StorageUnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw StorageError(.unsupported) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw StorageError(.unsupported) }
}
private func storageContext() -> UserContext { UserContext(queryExecutor: StorageUnusedExecutor(), mutationExecutor: StorageUnusedExecutor(), requestPolicy: RequestPolicy { $0 }) }
private actor StorageStub: ObjectStorageProvider {
  var size: Int64 = 3
  var deletes = 0
  var error: StorageErrorCode?
  var seenComment = "", seenContext = ""
  func configure(size: Int64 = 3, error: StorageErrorCode? = nil) { self.size = size; self.error = error }
  func head(_ invocation: StorageInvocation, key: ObjectKey) throws -> ObjectMetadata? {
    seenComment = invocation.comment; seenContext = invocation.context.objectStorageContextID
    if let error { throw StorageError(error) }; return nil
  }
  func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader, options: ObjectPutOptions) throws -> ObjectMetadata { try ObjectMetadata(key: key, size: options.size) }
  func get(_ invocation: StorageInvocation, key: ObjectKey) throws -> ObjectContent { ObjectContent(metadata: try ObjectMetadata(key: key, size: size), reader: ObjectDataReader(Data([1, 2, 3]))) }
  func delete(_ invocation: StorageInvocation, key: ObjectKey) { deletes += 1 }
  func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey, options: ObjectReadUrlOptions) throws -> ObjectReadUrl { throw StorageError(.unsupported) }
}
private actor CountedStorageReader: ObjectByteReader {
  var closes = 0
  func read(upToCount: Int) -> Data { Data() }
  func close() { closes += 1 }
}
private final class StorageEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ObjectStorageEvent] = []
  func record(_ value: ObjectStorageEvent) { lock.lock(); defer { lock.unlock() }; values.append(value) }
  var events: [ObjectStorageEvent] { lock.lock(); defer { lock.unlock() }; return values }
}
@MainActor
final class ObjectStorageTests: XCTestCase {
  func expect(_ code: StorageErrorCode, _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected storage failure") }
    catch let error as StorageError { XCTAssertEqual(error.code, code); XCTAssertFalse(String(describing: error).contains("CANARY")) }
    catch { XCTFail("Unexpected storage error type") }
  }
  func testObjectStorageContextAndErrorSemantics() async throws {
    XCTAssertThrowsError(try storageContext().objectStorage("read"))
    let stub = StorageStub(); let context = storageContext().withObjectStorage(stub)
    XCTAssertThrowsError(try context.objectStorage("  "))
    let storage = try context.objectStorage("read attachment"); let key = try ObjectKey("PRIVATE-KEY-CANARY")
    let exists = try await storage.exists(key); XCTAssertFalse(exists)
    let comment = await stub.seenComment, contextID = await stub.seenContext
    XCTAssertEqual(comment, "read attachment"); XCTAssertEqual(contextID, context.objectStorageContextID)
    for code in [StorageErrorCode.accessDenied, .unavailable] {
      await stub.configure(error: code)
      await expect(code) { _ = try await storage.exists(key) }
    }
  }
  func testConditionalDeleteRequiresProviderCapability() async throws {
    let stub = StorageStub()
    let storage = try storageContext().withObjectStorage(stub).objectStorage("conditional delete")
    let key = try ObjectKey("f4/conditional")
    await expect(.invalidInput) { _ = try await storage.deleteIfVersion(key, contentVersion: "*") }
    await expect(.unsupported) { _ = try await storage.deleteIfVersion(key, contentVersion: "\"etag\"") }
    let deletes = await stub.deletes
    XCTAssertEqual(deletes, 0)
  }
  func testObjectStorageStreamsAndObservationBoundaries() async throws {
    let stub = StorageStub(), events = StorageEvents()
    let storage = try storageContext().withObjectStorage(stub).withObjectStorageObserver { events.record($0) }.objectStorage("read attachment")
    let key = try ObjectKey("PRIVATE-KEY-CANARY"), input = CountedStorageReader()
    _ = try await storage.put(key, content: input, options: ObjectPutOptions(size: 0, mode: .createOnly))
    let closes = await input.closes; XCTAssertEqual(closes, 1)
    let response = try await storage.get(key); _ = try await response.reader.read(upToCount: 1); try await response.close()
    XCTAssertEqual(events.events.last?.outcome, "cancelled")
    let data = try await storage.getBytes(key, maximumBytes: 3); XCTAssertEqual(data, Data([1, 2, 3])); XCTAssertEqual(events.events.last?.outcome, "success")
    await expect(.tooLarge) { _ = try await storage.getBytes(key, maximumBytes: 2) }
    for size: Int64 in [2, 4] { await stub.configure(size: size); await expect(.io) { _ = try await storage.getBytes(key, maximumBytes: 5) } }
    XCTAssertFalse(String(reflecting: events.events).contains("CANARY"))
  }
  func testObjectStorageOptionsAndPrivateDescriptions() throws {
    for key in ["", String(repeating: "x", count: 1025), "bad\nkey"] { XCTAssertThrowsError(try ObjectKey(key)) }
    XCTAssertThrowsError(try ObjectPutOptions(size: ObjectPutOptions.maximumSize + 1, mode: .createOnly))
    XCTAssertThrowsError(try ObjectPutOptions(size: 0, mode: .createOnly, contentType: "bad\r\nheader"))
    XCTAssertThrowsError(try ObjectPutOptions(size: 0, mode: .createOnly, metadata: ["Bad Key": "value"]))
    for seconds in [0, -1, 604801] { XCTAssertThrowsError(try ObjectReadUrlOptions(seconds: seconds)) }
    XCTAssertThrowsError(try ObjectReadUrlOptions(disposition: "attachment", filename: "bad\nname"))
    XCTAssertThrowsError(try ObjectReadUrlOptions(disposition: "attachment", filename: "bad/name"))
    XCTAssertEqual(try ObjectReadUrlOptions(disposition: "inline", filename: "sample.jpg")
      .contentDisposition, "inline; filename=\"sample.jpg\"")
    let unicode = try ObjectReadUrlOptions(disposition: "inline",
      filename: "报告 & 📄\u{2028}mid\u{2029}x.jpg").contentDisposition!
    XCTAssertTrue(unicode.hasPrefix("inline; filename=\"__ & _"))
    XCTAssertTrue(unicode.contains("filename*=UTF-8''%E6%8A%A5%E5%91%8A%20%26%20%F0%9F%93%84"))
    XCTAssertFalse(unicode.contains("\r") || unicode.contains("\n"))
    let key = try ObjectKey("PRIVATE-KEY-CANARY")
    XCTAssertFalse(String(reflecting: key).contains("CANARY"))
    XCTAssertFalse(String(reflecting: ObjectReadUrl(url: URL(string: "https://example.invalid/PRIVATE-URL-CANARY")!, expiresAt: Date())).contains("CANARY"))
    XCTAssertFalse(String(reflecting: try ObjectPutOptions(size: 0, mode: .createOnly, metadata: ["tag": "PRIVATE-METADATA-CANARY"])).contains("CANARY"))
  }
}
