import Crypto
import Foundation
import GeneratedTeaQL
import SotoS3
import TeaQLCore
import TeaQLObjectStorageS3
import TeaQLSQLite

private let receipt = Data("TeaQL order receipt fixture\nItem: tea\nTotal: 12.50\n".utf8)
private let filename = "receipt.txt"
private let mediaType = "text/plain"

private struct AssertionFailure: Error { let check: String }
private func require(_ condition: Bool, _ check: String) throws {
  if !condition { throw AssertionFailure(check: check) }
}

private func expect(_ code: StorageErrorCode, _ operation: () async throws -> Void) async throws {
  do { try await operation() }
  catch let error as StorageError {
    try require(error.code == code, "unexpected storage error")
    return
  }
  throw AssertionFailure(check: "expected typed storage error")
}

private actor Audits: AuditSink {
  private var values: [AuditEvent] = []
  func record(_ event: AuditEvent) { values.append(event) }
  func businessEvents() -> [AuditEvent] {
    values.filter { $0.entity == "CustomerOrder" || $0.entity == "OrderAttachment" }
  }
}

private final class StorageEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ObjectStorageEvent] = []
  func record(_ event: ObjectStorageEvent) { lock.withLock { values.append(event) } }
  func snapshot() -> [ObjectStorageEvent] { lock.withLock { values } }
}

private func checksum(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct Result: Encodable {
  let round: Int
  let order: Int64
  let attachment: Int64
  let orderNumber: String
  let filename: String
  let contentType: String
  let length: Int
  let sha256: String
  let conflict = true
  let sizeRefused = true
  let missing = true
  let businessAudits: Int
}

@main enum OrderAttachmentConsole {
  static func main() async {
    do {
      let args = CommandLine.arguments
      guard args.count == 4, let round = Int(args[3]), (1...2).contains(round) else {
        throw AssertionFailure(check: "provide database, downloaded receipt path and round")
      }
      let env = ProcessInfo.processInfo.environment
      guard let endpoint = env["TEAQL_S3_ENDPOINT"], let bucket = env["TEAQL_S3_BUCKET"],
        let access = env["TEAQL_S3_ACCESS_KEY"], let secret = env["TEAQL_S3_SECRET_KEY"]
      else { throw AssertionFailure(check: "dedicated fixture configuration required") }
      let client = AWSClient(credentialProvider: .static(accessKeyId: access, secretAccessKey: secret), retryPolicy: .noRetry)
      do {
        let s3 = S3(client: client, region: .useast1, endpoint: endpoint, timeout: .seconds(5), options: [.s3Disable100Continue])
        let provider = try S3ObjectStorage(service: s3, bucket: bucket)
        try await verify(database: args[1], download: URL(fileURLWithPath: args[2]), round: round, provider: provider)
      } catch {
        try? await client.shutdown()
        throw error
      }
      try await client.shutdown()
    } catch let error as AssertionFailure {
      print("Order attachment example failed: " + error.check); exit(1)
    } catch {
      print("Order attachment example failed type=" + String(reflecting: type(of: error))); exit(1)
    }
  }

  private static func verify(database: String, download: URL, round: Int, provider: S3ObjectStorage) async throws {
    var runtime = TeaQLRuntime()
    try runtime.install(GeneratedRuntimeModule.module)
    let sqlite = try SQLiteDataService(path: database), audits = Audits(), events = StorageEvents()
    let context = UserContext(runtime: runtime, queryExecutor: sqlite, mutationExecutor: sqlite,
      requestPolicy: RequestPolicy { $0 }, auditSink: audits, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
      .withObjectStorage(provider).withObjectStorageObserver { events.record($0) }
    let storage = try context.objectStorage("file and retrieve an order receipt")
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    let platforms = try await Q.commercePlatforms().withIdIs(1).limit(1)
      .comment("load the commerce platform").purpose("associate the new order to its root").executeForList(context)
    guard let platform = platforms.first, platforms.count == 1 else {
      throw AssertionFailure(check: "generated platform missing")
    }

    let orderNumber = "ATTACH-ORDER-\(round)"
    var order = try await Q.customerOrders().comment("prepare receipt order")
      .purpose("file a receipt against this order").newEntity(context)
    order.updateOrderNumber(orderNumber)
    order.updateCommercePlatform(platform.id)
    order = try await order.auditAs("place the order receiving the receipt").save(context)
    let orderID = order.id
    let key = try ObjectKey("private-order-attachments/" + UUID().uuidString)
    let digest = checksum(receipt)
    let length = Int64(receipt.count)
    try require(!(try await storage.exists(key)), "new attachment key already exists")
    _ = try await storage.putBytes(key, data: receipt, options: ObjectPutOptions(size: length, mode: .createOnly,
      contentType: mediaType, metadata: ["receipt-sha256": digest]))
    var uploaded = true
    do {
      var attachment = try await Q.orderAttachments().comment("prepare receipt attachment")
        .purpose("save the uploaded receipt reference on its order").newEntity(context)
      attachment.updateCustomerOrder(orderID)
      attachment.updateFileName(filename)
      attachment.updateContentType(mediaType)
      attachment.updateContentLength(length)
      attachment.updateContentSha256(digest)
      attachment.updateObjectKey(key.value)
      attachment = try await attachment.auditAs("associate the stored receipt with its order").save(context)
      func attachments() async throws -> [OrderAttachment] {
        let rows = try await Q.orderAttachments().filterByCustomerOrder(orderID).limit(2)
          .comment("load order attachments").purpose("retrieve this order's stored receipt").executeForList(context)
        return Array(rows)
      }
      let rows = try await attachments()
      try require(rows.count == 1 && rows[0].id == attachment.id, "persisted order association mismatch")
      let expression = E.orderAttachment(rows[0])
      try require(try expression.customerOrderId().eval() == orderID, "stored receipt order mismatch")
      try require(try expression.fileName().eval() == filename, "stored receipt filename mismatch")
      try require(try expression.contentType().eval() == mediaType, "stored receipt content type mismatch")
      try require(try expression.contentLength().eval() == length, "stored receipt length mismatch")
      try require(try expression.contentSha256().eval() == digest, "stored receipt checksum mismatch")
      guard let value = try expression.objectKey().eval(), value == key.value else {
        throw AssertionFailure(check: "stored receipt reference mismatch")
      }
      let persistedKey = try ObjectKey(value)
      let metadata = try await storage.head(persistedKey)
      try require(metadata?.size == length && metadata?.contentType == mediaType
        && metadata?.customMetadata["receipt-sha256"] == digest, "provider metadata mismatch")
      let replacement = Data("replacement".utf8)
      try await expect(.conflict) {
        _ = try await storage.putBytes(persistedKey, data: replacement,
          options: ObjectPutOptions(size: Int64(replacement.count), mode: .createOnly))
      }
      try await expect(.tooLarge) { _ = try await storage.getBytes(persistedKey, maximumBytes: receipt.count - 1) }
      let downloaded = try await storage.getBytes(persistedKey, maximumBytes: receipt.count)
      try require(downloaded == receipt && checksum(downloaded) == digest, "retrieved receipt changed")
      try downloaded.write(to: download)
      try await storage.delete(persistedKey)
      uploaded = false
      try await expect(.notFound) { _ = try await storage.get(persistedKey) }
      try require(!(try await storage.exists(persistedKey)), "missing object reported present")
      try require(try await attachments().map(\.id) == [attachment.id], "missing object changed the order association")
      let seen = events.snapshot(), saved = await audits.businessEvents()
      try require(!seen.isEmpty && Set(seen.map(\.contextID)).count == 1, "storage observation escaped the attachment Context")
      try require(saved.map(\.entity) == ["CustomerOrder", "OrderAttachment"]
        && saved.map(\.entityID) == [.int(orderID), .int(attachment.id)], "committed order and attachment audits missing")
      try require(!String(reflecting: seen).contains(key.value) && !String(reflecting: saved).contains(key.value),
        "private object key reached safe events")
      let result = Result(round: round, order: orderID, attachment: attachment.id, orderNumber: orderNumber,
        filename: filename, contentType: mediaType, length: receipt.count, sha256: digest, businessAudits: saved.count)
      print("ORDER_ATTACHMENT " + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    } catch {
      if uploaded { try? await storage.delete(key) }
      throw error
    }
  }
}
