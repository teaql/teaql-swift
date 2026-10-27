import Foundation

public enum StorageErrorCode: String, Sendable {
  case invalidInput = "InvalidInput", notConfigured = "NotConfigured", notFound = "NotFound"
  case accessDenied = "AccessDenied", conflict = "Conflict", timeout = "Timeout"
  case unavailable = "Unavailable", unsupported = "Unsupported", tooLarge = "TooLarge", io = "Io"
}
public struct StorageError: Error, Sendable, CustomStringConvertible {
  public let code: StorageErrorCode
  public init(_ code: StorageErrorCode) { self.code = code }
  public var description: String { "Object storage: \(code.rawValue)" }
}
public struct ObjectKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
  public let value: String
  public init(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1024,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw StorageError(.invalidInput) }
    self.value = value
  }
  public var description: String { "ObjectKey[masked]" }
  public var debugDescription: String { description }
}
public enum ObjectWriteMode: Sendable { case createOnly, replace }
public struct ObjectPutOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public static let maximumSize: Int64 = 5 * 1024 * 1024 * 1024
  public let size: Int64
  public let mode: ObjectWriteMode
  public let contentType: String
  public let metadata: [String: String]
  static func header(_ value: String) throws {
    guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else { throw StorageError(.invalidInput) }
  }
  public init(size: Int64, mode: ObjectWriteMode, contentType: String = "application/octet-stream", metadata: [String: String] = [:]) throws {
    guard size >= 0 else { throw StorageError(.invalidInput) }
    guard size <= Self.maximumSize else { throw StorageError(.tooLarge) }
    try Self.header(contentType)
    for (key, value) in metadata {
      guard !key.isEmpty, key.first != "-", key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { throw StorageError(.invalidInput) }
      try Self.header(value)
    }
    self.size = size; self.mode = mode; self.contentType = contentType; self.metadata = metadata
  }
  public var description: String { "ObjectPutOptions[size=\(size), details=masked]" }
  public var debugDescription: String { description }
}
public struct ObjectMetadata: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let key: ObjectKey
  public let size: Int64
  public let contentType: String?
  public let etag: String?
  public let lastModified: Date?
  public let customMetadata: [String: String]
  public init(key: ObjectKey, size: Int64, contentType: String? = nil, etag: String? = nil, lastModified: Date? = nil, customMetadata: [String: String] = [:]) throws {
    guard size >= 0 else { throw StorageError(.unavailable) }
    self.key = key; self.size = size; self.contentType = contentType; self.etag = etag; self.lastModified = lastModified; self.customMetadata = customMetadata
  }
  public var description: String { "ObjectMetadata[size=\(size), details=masked]" }
  public var debugDescription: String { description }
}
public struct ObjectReadUrlOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let seconds: Int
  public let contentDisposition: String?
  public init(seconds: Int = 300, disposition: String? = nil, filename: String? = nil) throws {
    guard seconds > 0, seconds <= 604800, disposition == nil || disposition == "inline" || disposition == "attachment" else { throw StorageError(.invalidInput) }
    if let filename {
      try ObjectPutOptions.header(filename)
      guard disposition != nil, !filename.contains(where: { "/\\\"".contains($0) }) else { throw StorageError(.invalidInput) }
    }
    self.seconds = seconds
    self.contentDisposition = disposition.map { $0 + (filename.map { "; filename=\"\($0)\"" } ?? "") }
  }
  public var description: String { "ObjectReadUrlOptions[details=masked]" }
  public var debugDescription: String { description }
}
public struct ObjectReadUrl: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let url: URL
  public let expiresAt: Date
  public init(url: URL, expiresAt: Date) { self.url = url; self.expiresAt = expiresAt }
  public var description: String { "ObjectReadUrl[url=masked]" }
  public var debugDescription: String { description }
}
/// Returns at most the requested count. Empty Data means EOF; close releases resources.
public protocol ObjectByteReader: Sendable {
  func read(upToCount: Int) async throws -> Data
  func close() async throws
}
public actor ObjectDataReader: ObjectByteReader {
  private var data: Data
  private var offset = 0
  private var closed = false
  public init(_ data: Data) { self.data = data }
  public func read(upToCount count: Int) throws -> Data {
    guard !closed, count >= 0 else { throw StorageError(.io) }
    let amount = min(count, data.count - offset)
    defer { offset += amount }
    return data.subdata(in: offset..<(offset + amount))
  }
  public func close() { closed = true; data = Data(); offset = 0 }
}
public struct ObjectContent: Sendable, CustomStringConvertible {
  public let metadata: ObjectMetadata
  public let reader: any ObjectByteReader
  public init(metadata: ObjectMetadata, reader: any ObjectByteReader) { self.metadata = metadata; self.reader = reader }
  public func close() async throws { try await reader.close() }
  public var description: String { "ObjectContent[masked]" }
}
public struct StorageInvocation: Sendable {
  public let context: UserContext
  public let comment: String
}
public protocol ObjectStorageProvider: Sendable {
  func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader, options: ObjectPutOptions) async throws -> ObjectMetadata
  func get(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectContent
  func head(_ invocation: StorageInvocation, key: ObjectKey) async throws -> ObjectMetadata?
  func delete(_ invocation: StorageInvocation, key: ObjectKey) async throws
  func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey, options: ObjectReadUrlOptions) async throws -> ObjectReadUrl
}
public enum ObjectConditionalDeleteResult: Sendable { case deleted, alreadyMissing, versionMismatch }
public protocol ObjectStorageConditionalDeleter: Sendable {
  func deleteIfVersion(_ invocation: StorageInvocation, key: ObjectKey, contentVersion: String) async throws -> ObjectConditionalDeleteResult
}
public struct ObjectStorageEvent: Sendable {
  public let operation: String
  public let comment: String
  public let contextID: String
  public let outcome: String
  public let elapsed: TimeInterval
}
public typealias ObjectStorageObserver = @Sendable (ObjectStorageEvent) -> Void
public extension UserContext {
  /// Checks the exact installed provider without exposing storage configuration.
  func usesObjectStorageProvider(_ provider: AnyObject) -> Bool {
    guard let installed = objectStorageProvider as AnyObject? else { return false }
    return installed === provider
  }
  func withObjectStorage(_ provider: any ObjectStorageProvider) -> UserContext {
    var copy = self; copy.objectStorageProvider = provider; return copy
  }
  func withObjectStorageObserver(_ observer: @escaping ObjectStorageObserver) -> UserContext {
    var copy = self; copy.objectStorageObserver = observer; return copy
  }
  func objectStorage(_ comment: String) throws -> ObjectStorage {
    guard !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StorageError(.invalidInput) }
    guard let provider = objectStorageProvider else { throw StorageError(.notConfigured) }
    return ObjectStorage(invocation: StorageInvocation(context: self, comment: comment), provider: provider)
  }
}
private func safeStorageError(_ error: Error) -> StorageError {
  (error as? StorageError) ?? StorageError(.unavailable)
}
private struct StorageObservation: Sendable {
  let invocation: StorageInvocation
  let operation: String
  let started = ContinuousClock.now
  func finish(_ outcome: String) {
    let safe: (String) -> String = { text in String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? Character(" ") : Character($0) }) }
    let duration = started.duration(to: .now).components
    let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let event = ObjectStorageEvent(operation: operation, comment: safe(invocation.comment), contextID: invocation.context.objectStorageContextID, outcome: outcome, elapsed: elapsed)
    if let observer = invocation.context.objectStorageObserver { observer(event) }
    else { print("ObjectStorage operation=\(event.operation) comment=\(event.comment) context=\(event.contextID) outcome=\(event.outcome) elapsed=\(event.elapsed)") }
  }
}
public struct ObjectStorage: Sendable {
  let invocation: StorageInvocation
  let provider: any ObjectStorageProvider
  public var supportsVersionConditionalDelete: Bool { provider is any ObjectStorageConditionalDeleter }
  private func execute<T: Sendable>(_ operation: String, _ body: () async throws -> T) async throws -> T {
    let observation = StorageObservation(invocation: invocation, operation: operation)
    do {
      let result = try await invocation.context.runtimeTelemetry.withOperation(RuntimeOperation(family: "object_storage", name: operation), body)
      observation.finish("success"); return result
    } catch is CancellationError { observation.finish("cancelled"); throw CancellationError() }
    catch { let error = safeStorageError(error); observation.finish(error.code.rawValue); throw error }
  }
  public func put(_ key: ObjectKey, content: any ObjectByteReader, options: ObjectPutOptions) async throws -> ObjectMetadata {
    try await execute("put") {
      var result: ObjectMetadata?
      var failure: Error?
      do { result = try await provider.put(invocation, key: key, content: content, options: options) }
      catch { failure = error }
      do { try await content.close() }
      catch { if failure == nil { failure = StorageError(.io) } }
      if let failure { throw failure }
      return result!
    }
  }
  public func putBytes(_ key: ObjectKey, data: Data, options: ObjectPutOptions) async throws -> ObjectMetadata {
    try await put(key, content: ObjectDataReader(data), options: options)
  }
  public func get(_ key: ObjectKey) async throws -> ObjectContent {
    let observation = StorageObservation(invocation: invocation, operation: "get")
    do {
      let content = try await invocation.context.runtimeTelemetry.withOperation(RuntimeOperation(family: "object_storage", name: "get.open")) {
        try await provider.get(invocation, key: key)
      }
      return ObjectContent(metadata: content.metadata, reader: ObservedStorageReader(inner: content.reader, remaining: content.metadata.size, observation: observation))
    } catch is CancellationError { observation.finish("cancelled"); throw CancellationError() }
    catch { let error = safeStorageError(error); observation.finish(error.code.rawValue); throw error }
  }
  public func getBytes(_ key: ObjectKey, maximumBytes: Int) async throws -> Data {
    guard maximumBytes >= 0 else { throw StorageError(.invalidInput) }
    let response = try await get(key)
    do {
      guard response.metadata.size <= Int64(maximumBytes) else { throw StorageError(.tooLarge) }
      var result = Data()
      while true {
        let remaining = maximumBytes - result.count
        let block = try await response.reader.read(upToCount: remaining >= 65536 ? 65536 : remaining + 1)
        if block.isEmpty { break }
        guard block.count <= maximumBytes - result.count else { throw StorageError(.tooLarge) }
        result.append(block)
      }
      try await response.close(); return result
    } catch { try? await response.close(); throw error }
  }
  public func head(_ key: ObjectKey) async throws -> ObjectMetadata? { try await execute("head") { try await provider.head(invocation, key: key) } }
  public func exists(_ key: ObjectKey) async throws -> Bool { try await head(key) != nil }
  public func delete(_ key: ObjectKey) async throws { try await execute("delete") { try await provider.delete(invocation, key: key) } }
  public func deleteIfVersion(_ key: ObjectKey, contentVersion: String) async throws -> ObjectConditionalDeleteResult {
    try await execute("delete_if_version") {
      guard !contentVersion.isEmpty, contentVersion.utf8.count <= 256, contentVersion != "*",
        contentVersion.trimmingCharacters(in: .whitespacesAndNewlines) == contentVersion,
        !contentVersion.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw StorageError(.invalidInput)
      }
      guard let conditional = provider as? any ObjectStorageConditionalDeleter else { throw StorageError(.unsupported) }
      return try await conditional.deleteIfVersion(invocation, key: key, contentVersion: contentVersion)
    }
  }
  public func getReadUrl(_ key: ObjectKey, options: ObjectReadUrlOptions? = nil) async throws -> ObjectReadUrl {
    let options = try options ?? ObjectReadUrlOptions()
    return try await execute("read_url") { try await provider.getReadUrl(invocation, key: key, options: options) }
  }
}
private actor ObservedStorageReader: ObjectByteReader {
  let inner: any ObjectByteReader
  var remaining: Int64
  let observation: StorageObservation
  var closed = false, ended = false, reading = false
  init(inner: any ObjectByteReader, remaining: Int64, observation: StorageObservation) { self.inner = inner; self.remaining = remaining; self.observation = observation }
  func finish(_ outcome: String) { if !ended { ended = true; observation.finish(outcome) } }
  func read(upToCount count: Int) async throws -> Data {
    guard !closed, !reading, count >= 0 else { throw StorageError(.io) }
    if count == 0 { return Data() }
    reading = true; defer { reading = false }
    do {
      let reader = inner
      let work: @Sendable () async throws -> Data = { try await reader.read(upToCount: count) }
      let bytes = try await observation.invocation.context.runtimeTelemetry.withOperation(RuntimeOperation(family: "object_storage", name: "get.read"), work)
      guard !closed, bytes.count <= count, Int64(bytes.count) <= remaining, !bytes.isEmpty || remaining == 0 else { throw StorageError(.io) }
      remaining -= Int64(bytes.count); if bytes.isEmpty { finish("success") }; return bytes
    } catch is CancellationError { finish("cancelled"); closed = true; try? await inner.close(); throw CancellationError() }
    catch { finish("Io"); closed = true; try? await inner.close(); throw StorageError(.io) }
  }
  func close() async throws {
    if closed { return }; closed = true
    do { try await inner.close(); finish("cancelled") }
    catch { finish("Io"); throw StorageError(.io) }
  }
}
