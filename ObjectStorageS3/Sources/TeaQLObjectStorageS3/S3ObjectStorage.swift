import Foundation
import SotoS3
import AsyncHTTPClient
import TeaQLCore

private func storageError(_ error: Error) -> StorageError {
  if let storage = error as? StorageError { return storage }
  if let http = error as? HTTPClientError,
    [HTTPClientError.readTimeout, .writeTimeout, .connectTimeout, .deadlineExceeded, .getConnectionFromPoolTimeout, .tlsHandshakeTimeout].contains(http) { return StorageError(.timeout) }
  var status: UInt?
  if let aws = error as? any AWSErrorType {
    if aws.errorCode == "NoSuchBucket" { return StorageError(.unavailable) }
    status = aws.context?.responseCode.code
  } else if let raw = error as? AWSRawError { status = raw.context.responseCode.code }
  switch status {
  case 401, 403: return StorageError(.accessDenied)
  case 404: return StorageError(.notFound)
  case 409, 412: return StorageError(.conflict)
  case 408, 504: return StorageError(.timeout)
  case 413: return StorageError(.tooLarge)
  case 501: return StorageError(.unsupported)
  case 400, 422: return StorageError(.invalidInput)
  default: return StorageError(.unavailable)
  }
}

/// A replayable file sequence; each SDK iterator opens its own bounded reader.
private struct FileChunks: AsyncSequence, Sendable {
  typealias Element = Data
  let url: URL
  struct AsyncIterator: AsyncIteratorProtocol {
    let url: URL
    var file: FileHandle?
    var ended = false
    mutating func next() async throws -> Data? {
      if ended { return nil }
      if file == nil { file = try FileHandle(forReadingFrom: url) }
      let bytes = try file!.read(upToCount: 65536) ?? Data()
      if bytes.isEmpty { try file!.close(); file = nil; ended = true; return nil }
      return bytes
    }
  }
  func makeAsyncIterator() -> AsyncIterator { AsyncIterator(url: url) }
}

// Soto's type-erased iterator is not Sendable. This box is private to one reader
// actor, which rejects overlapping reads and cancels its sole task on close.
private final class SotoIteratorBox: @unchecked Sendable {
  var iterator: AWSHTTPBody.AsyncIterator
  init(_ body: AWSHTTPBody) { iterator = body.makeAsyncIterator() }
  func next() async throws -> Data? {
    guard let bytes = try await iterator.next() else { return nil }
    return Data(bytes.readableBytesView)
  }
}
private actor S3BodyReader: ObjectByteReader {
  var box: SotoIteratorBox?
  var pending = Data()
  var offset = 0
  var task: Task<Data?, Error>?
  var reading = false, closed = false
  init(_ body: AWSHTTPBody) { box = SotoIteratorBox(body) }
  func read(upToCount count: Int) async throws -> Data {
    guard !closed, !reading, count >= 0 else { throw StorageError(.io) }
    if count == 0 { return Data() }
    reading = true; defer { reading = false }
    if offset == pending.count {
      pending = Data(); offset = 0
      guard let box else { return Data() }
      let next = Task { try await box.next() }; task = next
      do { pending = try await next.value ?? Data() }
      catch { task = nil; self.box = nil; throw StorageError(.io) }
      task = nil
      guard !closed else { throw StorageError(.io) }
      if pending.isEmpty { self.box = nil; return Data() }
    }
    let amount = min(count, pending.count - offset)
    defer { offset += amount }
    return pending.subdata(in: offset..<(offset + amount))
  }
  func close() {
    closed = true; task?.cancel(); task = nil; box = nil; pending = Data(); offset = 0
  }
}

public struct S3ObjectStorage: ObjectStorageProvider, ObjectStorageConditionalDeleter,
  CustomStringConvertible, CustomDebugStringConvertible {
  private let service: S3
  private let bucket: String
  public init(service: S3, bucket: String) throws {
    guard !bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StorageError(.invalidInput) }
    self.service = service; self.bucket = bucket
  }
  public var description: String { "S3ObjectStorage[configuration=masked]" }
  public var debugDescription: String { description }
  public func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader, options: ObjectPutOptions) async throws -> ObjectMetadata {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-object-" + UUID().uuidString, isDirectory: true)
    let file = directory.appendingPathComponent("upload")
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    catch { throw StorageError(.io) }
    defer { try? FileManager.default.removeItem(at: directory) }
    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw StorageError(.io) }
    do {
      let handle = try FileHandle(forWritingTo: file)
      do {
        var total: Int64 = 0
        while true {
          try Task.checkCancellation()
          let bytes = try await content.read(upToCount: 65536)
          if bytes.isEmpty { break }
          guard bytes.count <= 65536 else { throw StorageError(.invalidInput) }
          total += Int64(bytes.count)
          guard total <= options.size else { throw StorageError(.invalidInput) }
          try handle.write(contentsOf: bytes)
        }
        try handle.close()
        guard total == options.size else { throw StorageError(.invalidInput) }
      } catch { try? handle.close(); if error is CancellationError { throw CancellationError() }; if let error = error as? StorageError { throw error }; throw StorageError(.io) }
      let body = AWSHTTPBody(asyncSequence: FileChunks(url: file), length: Int(options.size))
      let response = try await service.putObject(.init(body: body, bucket: bucket, contentLength: options.size, contentType: options.contentType, ifNoneMatch: options.mode == .createOnly ? "*" : nil, key: key.value, metadata: options.metadata))
      guard let etag = response.eTag, !etag.isEmpty else { throw StorageError(.unavailable) }
      return try ObjectMetadata(key: key, size: options.size, contentType: options.contentType, etag: etag, customMetadata: options.metadata)
    } catch is CancellationError { throw CancellationError() }
    catch { throw storageError(error) }
  }
  private func metadata(_ key: ObjectKey, size: Int64?, type: String?, etag: String?, modified: Date?, values: [String: String]?) throws -> ObjectMetadata {
    guard let size, let etag, !etag.isEmpty else { throw StorageError(.unavailable) }
    return try ObjectMetadata(key: key, size: size, contentType: type, etag: etag, lastModified: modified, customMetadata: values ?? [:])
  }
  public func get(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectContent {
    do {
      let response = try await service.getObject(.init(bucket: bucket, key: key.value))
      let reader = S3BodyReader(response.body)
      do { return ObjectContent(metadata: try metadata(key, size: response.contentLength, type: response.contentType, etag: response.eTag, modified: response.lastModified, values: response.metadata), reader: reader) }
      catch { await reader.close(); throw error }
    } catch is CancellationError { throw CancellationError() }
    catch { throw storageError(error) }
  }
  public func head(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectMetadata? {
    do {
      let response = try await service.headObject(.init(bucket: bucket, key: key.value))
      return try metadata(key, size: response.contentLength, type: response.contentType, etag: response.eTag, modified: response.lastModified, values: response.metadata)
    } catch is CancellationError { throw CancellationError() }
    catch { let safe = storageError(error); if safe.code != .notFound { throw safe } }
    do { _ = try await service.headBucket(.init(bucket: bucket)); return nil }
    catch is CancellationError { throw CancellationError() }
    catch { let safe = storageError(error); throw safe.code == .notFound ? StorageError(.unavailable) : safe }
  }
  public func delete(_ invocation: StorageInvocation, key: ObjectKey) async throws {
    do { _ = try await service.deleteObject(.init(bucket: bucket, key: key.value)) }
    catch is CancellationError { throw CancellationError() }
    catch { throw storageError(error) }
  }
  public func deleteIfVersion(_ invocation: StorageInvocation, key: ObjectKey,
    contentVersion: String) async throws -> ObjectConditionalDeleteResult {
    guard !contentVersion.isEmpty, contentVersion != "*", contentVersion.utf8.count <= 256,
      contentVersion == contentVersion.trimmingCharacters(in: .whitespacesAndNewlines),
      !contentVersion.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw StorageError(.invalidInput) }
    do {
      _ = try await service.deleteObject(.init(bucket: bucket, ifMatch: contentVersion, key: key.value))
      return .deleted
    } catch is CancellationError { throw CancellationError() }
    catch {
      let status = (error as? any AWSErrorType)?.context?.responseCode.code
        ?? (error as? AWSRawError)?.context.responseCode.code
      if status == 404 || status == 412 {
        let current = try await head(invocation, key: key)
        return current == nil ? .alreadyMissing : .versionMismatch
      }
      throw storageError(error)
    }
  }
  public func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey, options: ObjectReadUrlOptions) async throws -> ObjectReadUrl {
    try Task.checkCancellation()
    var components = URLComponents(string: service.config.endpoint)
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    guard let bucketPath = bucket.addingPercentEncoding(withAllowedCharacters: allowed),
      let keyPath = key.value.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "/"))), components != nil else { throw StorageError(.invalidInput) }
    components!.percentEncodedPath += "/" + bucketPath + "/" + keyPath
    if let disposition = options.contentDisposition { components!.queryItems = [URLQueryItem(name: "response-content-disposition", value: disposition)] }
    guard let url = components!.url else { throw StorageError(.invalidInput) }
    do {
      let signed = try await service.signURL(url: url, httpMethod: .GET, expires: .seconds(Int64(options.seconds)))
      let query = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
      guard let timestamp = query.first(where: { $0.name == "X-Amz-Date" })?.value, let started = formatter.date(from: timestamp),
        let value = query.first(where: { $0.name == "X-Amz-Expires" })?.value, let seconds = Int(value), seconds > 0, seconds <= options.seconds else { throw StorageError(.unavailable) }
      guard query.first(where: { $0.name == "X-Amz-SignedHeaders" })?.value == "host" else { throw StorageError(.unsupported) }
      return ObjectReadUrl(url: signed, expiresAt: started.addingTimeInterval(TimeInterval(seconds)))
    }
    catch { throw storageError(error) }
  }
}
