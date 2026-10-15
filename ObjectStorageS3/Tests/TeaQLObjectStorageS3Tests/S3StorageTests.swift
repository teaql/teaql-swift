import Foundation
import XCTest
import SotoS3
import TeaQLCore
import TeaQLObjectStorageS3

private struct UnusedStorageExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw StorageError(.unsupported) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw StorageError(.unsupported) }
}
private actor FailingStorageInput: ObjectByteReader {
  func read(upToCount: Int) throws -> Data { throw StorageError(.io) }
  func close() {}
}
@MainActor
final class S3StorageTests: XCTestCase {
  func expect(_ code: StorageErrorCode, _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected storage failure") }
    catch let error as StorageError { XCTAssertEqual(error.code, code); XCTAssertFalse(String(describing: error).contains("CANARY")) }
    catch { XCTFail("Unexpected storage failure type") }
  }
  func testObjectStorageSDKHttpFailuresLengthAndTimeout() async throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = root.appendingPathComponent("Examples/ObjectStorage/http_fixture.py")
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", fixture.path]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    var port = Data()
    while true { let byte = output.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data([10]) { break }; port.append(byte) }
    let endpoint = "http://127.0.0.1:" + String(decoding: port, as: UTF8.self)
    let client = AWSClient(credentialProvider: .static(accessKeyId: "test", secretAccessKey: "secret"), retryPolicy: .noRetry)
    let service = S3(client: client, region: .useast1, endpoint: endpoint, timeout: .milliseconds(50), options: [.s3Disable100Continue])
    let provider = try S3ObjectStorage(service: service, bucket: "bucket")
    let context = UserContext(queryExecutor: UnusedStorageExecutor(), mutationExecutor: UnusedStorageExecutor(), requestPolicy: RequestPolicy { $0 }).withObjectStorage(provider)
    let storage = try context.objectStorage("verify HTTP error semantics")
    for (status, code) in [(403, StorageErrorCode.accessDenied), (500, .unavailable), (503, .unavailable), (408, .timeout), (504, .timeout), (501, .unsupported)] {
      let key = try ObjectKey("status-\(status)-PRIVATE-KEY-CANARY")
      await expect(code) { _ = try await storage.exists(key) }
    }
    let missing = try ObjectKey("status-404-key")
    let exists = try await storage.exists(missing); XCTAssertFalse(exists)
    await expect(.unavailable) { _ = try await storage.exists(ObjectKey("status-200-key")) }
    for (data, size) in [(Data([1, 2]), Int64(1)), (Data([1]), Int64(2))] {
      await expect(.invalidInput) { _ = try await storage.putBytes(missing, data: data, options: ObjectPutOptions(size: size, mode: .createOnly)) }
    }
    await expect(.io) { _ = try await storage.put(missing, content: FailingStorageInput(), options: ObjectPutOptions(size: 1, mode: .createOnly)) }
    await expect(.timeout) { _ = try await storage.exists(ObjectKey("status-0-key")) }
    process.terminate(); process.waitUntilExit()
    await expect(.unavailable) { _ = try await storage.exists(missing) }
    try await client.shutdown()
  }
}
