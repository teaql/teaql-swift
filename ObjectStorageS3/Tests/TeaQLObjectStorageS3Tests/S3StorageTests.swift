import Foundation
import FoundationNetworking
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
  func testMinioRealSignedRangeAndExpiry() async throws {
    // Explicit local S3-compatible gate; the host owns the disposable bucket.
    let env = ProcessInfo.processInfo.environment
    guard let endpoint = env["TEAQL_S3_TEST_ENDPOINT"], let bucket = env["TEAQL_S3_TEST_BUCKET"],
      let access = env["TEAQL_S3_TEST_ACCESS_KEY"], let secret = env["TEAQL_S3_TEST_SECRET_KEY"] else {
      throw XCTSkip("explicit S3-compatible endpoint, bucket and credentials required")
    }
    let client = AWSClient(credentialProvider: .static(accessKeyId: access, secretAccessKey: secret), retryPolicy: .noRetry)
    let service = S3(client: client, region: .useast1, endpoint: endpoint, options: [.s3Disable100Continue])
    let provider = try S3ObjectStorage(service: service, bucket: bucket)
    let context = UserContext(queryExecutor: UnusedStorageExecutor(), mutationExecutor: UnusedStorageExecutor(), requestPolicy: RequestPolicy { $0 }).withObjectStorage(provider)
    let storage = try context.objectStorage("F4 real S3-compatible Swift")
    let key = try ObjectKey("f4/swift/" + UUID().uuidString)
    let createKey = try ObjectKey("f4/swift/create/" + UUID().uuidString)
    let raceKey = try ObjectKey("f4/swift/race/" + UUID().uuidString)
    let bytes = Data("%PDF-1.7\nF4 real S3-compatible bytes\n%%EOF".utf8)
    do {
      let written = try await storage.putBytes(key, data: bytes, options: ObjectPutOptions(size: Int64(bytes.count), mode: .replace, contentType: "application/pdf"))
      let head = try await storage.head(key)
      XCTAssertEqual(head?.size, Int64(bytes.count))
      XCTAssertEqual(head?.etag, written.etag)
      XCTAssertEqual(head?.contentType, "application/pdf")
      let fetched = try await storage.getBytes(key, maximumBytes: 1024)
      XCTAssertEqual(fetched, bytes)
      let ticket = try await storage.getReadUrl(key, options: ObjectReadUrlOptions(seconds: 2, disposition: "attachment", filename: "report.pdf"))
      var request = URLRequest(url: ticket.url)
      request.setValue("bytes=0-7", forHTTPHeaderField: "Range")
      let (partial, response) = try await URLSession.shared.data(for: request)
      let http = try XCTUnwrap(response as? HTTPURLResponse)
      XCTAssertEqual(http.statusCode, 206)
      XCTAssertEqual(partial, bytes.prefix(8))
      XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/pdf")
      XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Disposition")?.contains("report.pdf") == true)
      let delay = ticket.expiresAt.addingTimeInterval(1.3).timeIntervalSinceNow
      if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
      let (_, expired) = try await URLSession.shared.data(from: ticket.url)
      XCTAssertEqual((expired as? HTTPURLResponse)?.statusCode, 403)
      if env["TEAQL_S3_TEST_CREATE_ONLY"] == "1" {
        let create = try ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly,
          contentType: "application/pdf")
        let created = try await storage.putBytes(createKey, data: bytes, options: create)
        await expect(.conflict) {
          _ = try await storage.putBytes(createKey, data: Data(repeating: 0x78, count: bytes.count),
            options: create)
        }
        let createdHead = try await storage.head(createKey)
        let createdBytes = try await storage.getBytes(createKey, maximumBytes: 1024)
        XCTAssertEqual(createdHead?.etag, created.etag)
        XCTAssertEqual(createdBytes, bytes)
        let candidates = [bytes, Data(repeating: 0x79, count: bytes.count)]
        let tasks = candidates.map { value in
          Task.detached { try await storage.putBytes(raceKey, data: value, options: create) }
        }
        var winner = -1, wins = 0
        for (index, task) in tasks.enumerated() {
          do { _ = try await task.value; winner = index; wins += 1 }
          catch let error as StorageError { XCTAssertEqual(error.code, .conflict) }
          catch { XCTFail("unexpected create-only race failure") }
        }
        XCTAssertEqual(wins, 1)
        if winner >= 0 {
          let winnerBytes = try await storage.getBytes(raceKey, maximumBytes: 1024)
          XCTAssertEqual(winnerBytes, candidates[winner])
        }
      }
    } catch {
      try? await storage.delete(key)
      if env["TEAQL_S3_TEST_CREATE_ONLY"] == "1" {
        try? await storage.delete(createKey)
        try? await storage.delete(raceKey)
      }
      try? await client.shutdown()
      throw error
    }
    try await storage.delete(key)
    if env["TEAQL_S3_TEST_CREATE_ONLY"] == "1" {
      try await storage.delete(createKey)
      try await storage.delete(raceKey)
    }
    try await client.shutdown()
  }

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
