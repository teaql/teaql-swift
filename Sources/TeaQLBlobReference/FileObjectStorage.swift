import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import TeaQLCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct FileManifest: Codable {
  let version: String
  let size: Int64
  let contentType: String
  let sha256: String
  let modified: Date
  let metadata: [String: String]
}

private struct FileTicket: Codable {
  let hash: String
  let version: String
  let expiresUnixMs: Int64
  let disposition: String?
}

private actor FileObjectReader: ObjectByteReader {
  private var handle: FileHandle?
  init(_ handle: FileHandle) { self.handle = handle }
  func read(upToCount count: Int) throws -> Data {
    guard count >= 0, let handle else { throw StorageError(.io) }
    do { return try handle.read(upToCount: count) ?? Data() }
    catch { throw StorageError(.io) }
  }
  func close() throws {
    guard let handle else { return }
    self.handle = nil
    do { try handle.close() } catch { throw StorageError(.io) }
  }
}

/// A private local store. The host must protect the root's parent against untrusted writers.
/// Old immutable generations remain until a separate collector is installed.
/// The loopback read gateway starts only when `start()` is called.
public final class FileObjectStorage: ObjectStorageProvider, ObjectStorageConditionalDeleter, @unchecked Sendable {
  private let root: String
  private let key: SymmetricKey
  private let gatewayLock = NSLock()
  private var group: MultiThreadedEventLoopGroup?
  private var channel: Channel?
  private var baseURL: URL?

  public init(root: String, signingKey: Data) throws {
    guard root.hasPrefix("/"), signingKey.count == 32 else { throw StorageError(.invalidInput) }
    self.root = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path
    self.key = SymmetricKey(data: signingKey)
  }

  private static func hash(_ key: ObjectKey) -> String {
    SHA256.hash(data: Data(key.value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func directory(_ hash: String) -> String { "\(root)/\(hash.prefix(2))/\(hash)" }
  private func dataPath(_ hash: String, _ version: String) -> String { "\(directory(hash))/data-\(version)" }
  private func manifestPath(_ hash: String) -> String { "\(directory(hash))/manifest.json" }
  private func withManifestLock<T>(_ hash: String, _ operation: () throws -> T) throws -> T {
    let fd = open("\(directory(hash))/manifest.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StorageError(.io) }
    defer { _ = DarwinOrGlibcClose(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else { throw StorageError(.unavailable) }
    defer { _ = flock(fd, LOCK_UN) }
    return try operation()
  }
  private static func version() -> String { Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64URLEncodedString() }
  private static func validVersion(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
      (97...122).contains($0) || $0 == 45 || $0 == 95 }
  }
  private static func validHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private func ensureRoot(create: Bool) throws {
    if create {
      do {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch { throw StorageError(.io) }
    }
    var info = stat()
    guard lstat(root, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
      info.st_mode & 0o077 == 0 else { throw StorageError(.unavailable) }
  }

  private func readManifest(_ hash: String) throws -> FileManifest? {
    let path = manifestPath(hash)
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard let size = (attributes[.size] as? NSNumber)?.intValue,
        size >= 0, size <= 16 * 1024 else { throw StorageError(.unavailable) }
      let value = try JSONDecoder().decode(FileManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      guard Self.validVersion(value.version), value.size >= 0, value.size <= ObjectPutOptions.maximumSize,
        !value.contentType.isEmpty,
        value.contentType.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }),
        Self.validHash(value.sha256), value.modified.timeIntervalSince1970 > 0 else { throw StorageError(.unavailable) }
      return value
    } catch { throw StorageError(.unavailable) }
  }

  private func metadata(_ key: ObjectKey, _ value: FileManifest) throws -> ObjectMetadata {
    try ObjectMetadata(key: key, size: value.size, contentType: value.contentType,
      etag: value.sha256 + "." + value.version, lastModified: value.modified,
      customMetadata: value.metadata)
  }

  private func openData(_ hash: String, _ value: FileManifest) throws -> FileHandle {
    let path = dataPath(hash, value.version)
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw StorageError(.unavailable) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_size == value.size else { _ = DarwinOrGlibcClose(fd); throw StorageError(.unavailable) }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  public func put(_ invocation: StorageInvocation, key: ObjectKey, content: any ObjectByteReader,
                  options: ObjectPutOptions) async throws -> ObjectMetadata {
    try ensureRoot(create: true)
    let hash = Self.hash(key), directory = directory(Self.hash(key)), version = Self.version()
    do {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw StorageError(.io) }
    let dataPath = dataPath(hash, version), tempPath = "\(directory)/manifest-\(version)"
    var installed = false
    defer {
      if !installed { _ = unlink(dataPath); _ = unlink(tempPath) }
    }
    let fd = open(dataPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw StorageError(.io) }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var digest = SHA256(), remaining = options.size
    do {
      while remaining > 0 {
        try Task.checkCancellation()
        let block = try await content.read(upToCount: Int(min(remaining, 65536)))
        guard !block.isEmpty, Int64(block.count) <= remaining else { throw StorageError(.invalidInput) }
        try output.write(contentsOf: block)
        digest.update(data: block)
        remaining -= Int64(block.count)
      }
      guard try await content.read(upToCount: 1).isEmpty else { throw StorageError(.invalidInput) }
      try output.synchronize()
      try output.close()
    } catch {
      try? output.close()
      if error is CancellationError { throw error }
      throw (error as? StorageError) ?? StorageError(.io)
    }
    let manifest = FileManifest(version: version, size: options.size, contentType: options.contentType,
      sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
      modified: Date(), metadata: options.metadata)
    let encoded = try JSONEncoder().encode(manifest)
    let manifestFD = open(tempPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard manifestFD >= 0 else { throw StorageError(.io) }
    let manifestFile = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: true)
    do { try manifestFile.write(contentsOf: encoded); try manifestFile.synchronize(); try manifestFile.close() }
    catch { try? manifestFile.close(); throw StorageError(.io) }
    let target = manifestPath(hash)
    try withManifestLock(hash) {
      if options.mode == .createOnly {
        guard link(tempPath, target) == 0 else {
          if errno == EEXIST { throw StorageError(.conflict) }
          throw StorageError(.io)
        }
        _ = unlink(tempPath)
      } else {
        guard rename(tempPath, target) == 0 else { throw StorageError(.io) }
      }
    }
    installed = true
    return try metadata(key, manifest)
  }

  public func get(_ invocation: StorageInvocation, key: ObjectKey) throws -> ObjectContent {
    try ensureRoot(create: false)
    let hash = Self.hash(key)
    guard let value = try readManifest(hash) else { throw StorageError(.notFound) }
    return ObjectContent(metadata: try metadata(key, value), reader: FileObjectReader(try openData(hash, value)))
  }

  public func head(_ invocation: StorageInvocation, key: ObjectKey) throws -> ObjectMetadata? {
    if !FileManager.default.fileExists(atPath: root) { return nil }
    try ensureRoot(create: false)
    let hash = Self.hash(key)
    guard let value = try readManifest(hash) else { return nil }
    let handle = try openData(hash, value)
    try? handle.close()
    return try metadata(key, value)
  }

  public func delete(_ invocation: StorageInvocation, key: ObjectKey) throws {
    try ensureRoot(create: false)
    let hash = Self.hash(key)
    guard FileManager.default.fileExists(atPath: directory(hash)) else { return }
    try withManifestLock(hash) {
      guard unlink(manifestPath(hash)) == 0 || errno == ENOENT else { throw StorageError(.io) }
    }
  }

  /// Compare and remove the current manifest under a persistent cross-process key lock.
  /// Immutable data generations remain for a separate storage collector.
  public func deleteIfVersion(_ invocation: StorageInvocation, key: ObjectKey,
                              contentVersion: String) throws -> ObjectConditionalDeleteResult {
    if !FileManager.default.fileExists(atPath: root) { return .alreadyMissing }
    try ensureRoot(create: false)
    let hash = Self.hash(key)
    guard FileManager.default.fileExists(atPath: directory(hash)) else { return .alreadyMissing }
    return try withManifestLock(hash) {
      guard let manifest = try readManifest(hash) else { return .alreadyMissing }
      guard try metadata(key, manifest).etag == contentVersion else { return .versionMismatch }
      guard unlink(dataPath(hash, manifest.version)) == 0 || errno == ENOENT else { throw StorageError(.io) }
      guard unlink(manifestPath(hash)) == 0 else { throw StorageError(.io) }
      return .deleted
    }
  }

  private func seal(_ ticket: FileTicket) throws -> String {
    let plain = try JSONEncoder().encode(ticket)
    let box = try AES.GCM.seal(plain, using: key)
    guard let combined = box.combined else { throw StorageError(.unavailable) }
    return combined.base64URLEncodedString()
  }

  private func openTicket(_ token: String) -> FileTicket? {
    guard (40...4096).contains(token.utf8.count),
      let bytes = Data(base64URLEncoded: token), bytes.base64URLEncodedString() == token else { return nil }
    do {
      let box = try AES.GCM.SealedBox(combined: bytes)
      let plain = try AES.GCM.open(box, using: key)
      let ticket = try JSONDecoder().decode(FileTicket.self, from: plain)
      guard Self.validHash(ticket.hash), Self.validVersion(ticket.version),
        ticket.expiresUnixMs > Int64(Date().timeIntervalSince1970 * 1000),
        ticket.disposition?.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) ?? true else { return nil }
      return ticket
    } catch { return nil }
  }

  public func getReadUrl(_ invocation: StorageInvocation, key: ObjectKey,
                         options: ObjectReadUrlOptions) throws -> ObjectReadUrl {
    gatewayLock.lock(); let base = baseURL; gatewayLock.unlock()
    guard let base else { throw StorageError(.notConfigured) }
    try ensureRoot(create: false)
    let hash = Self.hash(key)
    guard let manifest = try readManifest(hash) else { throw StorageError(.notFound) }
    let handle = try openData(hash, manifest); try? handle.close()
    let expiry = Date().addingTimeInterval(TimeInterval(options.seconds))
    let ticket = FileTicket(hash: hash, version: manifest.version,
      expiresUnixMs: Int64(expiry.timeIntervalSince1970 * 1000), disposition: options.contentDisposition)
    return ObjectReadUrl(url: base.appending(path: "objects/\(try seal(ticket))"), expiresAt: expiry)
  }

  /// Explicitly enables an authenticated local HTTP read endpoint.
  public func start() throws -> URL {
    try ensureRoot(create: true)
    gatewayLock.lock(); defer { gatewayLock.unlock() }
    guard group == nil else { throw StorageError(.conflict) }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    do {
      let channel = try ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 128)
        .childChannelInitializer { child in
          child.pipeline.configureHTTPServerPipeline().flatMap {
            child.pipeline.addHandler(FileHTTPHandler(store: self))
          }
        }
        .bind(host: "127.0.0.1", port: 0).wait()
      guard let port = channel.localAddress?.port, let url = URL(string: "http://127.0.0.1:\(port)") else {
        try channel.close().wait(); throw StorageError(.unavailable)
      }
      self.group = group; self.channel = channel; self.baseURL = url
      return url
    } catch {
      try? group.syncShutdownGracefully()
      throw StorageError(.unavailable)
    }
  }

  public func close() throws {
    gatewayLock.lock()
    let channel = self.channel, group = self.group
    self.channel = nil; self.group = nil; self.baseURL = nil
    gatewayLock.unlock()
    try channel?.close().wait()
    try group?.syncShutdownGracefully()
  }

  fileprivate func serve(_ request: HTTPRequestHead) -> (HTTPResponseHead, String?, Int64, Int64) {
    var response = HTTPResponseHead(version: request.version, status: .notFound)
    response.headers.add(name: "Connection", value: "close")
    guard request.method == .GET || request.method == .HEAD else {
      response.status = .methodNotAllowed; return (response, nil, 0, 0)
    }
    guard request.uri.hasPrefix("/objects/"), !request.uri.dropFirst(9).contains("/"),
      let ticket = openTicket(String(request.uri.dropFirst(9))),
      (try? ensureRoot(create: false)) != nil,
      let manifest = try? readManifest(ticket.hash), manifest.version == ticket.version,
      let file = try? openData(ticket.hash, manifest) else { return (response, nil, 0, 0) }
    try? file.close()
    var start: Int64 = 0, end: Int64 = manifest.size - 1
    if let range = request.headers.first(name: "Range") {
      let value = range.hasPrefix("bytes=") ? String(range.dropFirst(6)) : ""
      let parts = value.split(separator: "-", omittingEmptySubsequences: false)
      var valid = parts.count == 2 && manifest.size > 0 && !value.contains(",")
      if valid {
        if parts[0].isEmpty {
          if let suffix = Int64(parts[1]), suffix > 0 { start = max(0, manifest.size - suffix) }
          else { valid = false }
        } else if let first = Int64(parts[0]), first >= 0, first < manifest.size {
          start = first
          if !parts[1].isEmpty {
            if let last = Int64(parts[1]), last >= first { end = min(last, manifest.size - 1) }
            else { valid = false }
          }
        } else { valid = false }
      }
      if !valid {
        response.status = .rangeNotSatisfiable
        response.headers.add(name: "Content-Range", value: "bytes */\(manifest.size)")
        return (response, nil, 0, 0)
      }
      response.status = .partialContent
      response.headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(manifest.size)")
    } else { response.status = .ok }
    response.headers.add(name: "Content-Type", value: manifest.contentType)
    response.headers.add(name: "Content-Length", value: "\(request.headers.first(name: "Range") == nil ? manifest.size : end - start + 1)")
    response.headers.add(name: "Cache-Control", value: "private, no-store")
    response.headers.add(name: "X-Content-Type-Options", value: "nosniff")
    response.headers.add(name: "Accept-Ranges", value: "bytes")
    response.headers.add(name: "ETag", value: "\"\(manifest.sha256).\(manifest.version)\"")
    if let disposition = ticket.disposition { response.headers.add(name: "Content-Disposition", value: disposition) }
    return (response, request.method == .HEAD ? nil : dataPath(ticket.hash, manifest.version), start, end + 1)
  }
}

private final class FileHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  private let store: FileObjectStorage
  private var responded = false
  init(store: FileObjectStorage) { self.store = store }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .head(let request) = Self.unwrapInboundIn(data), !responded else { return }
    responded = true
    let (head, path, start, end) = store.serve(request)
    let loopBoundContext = context.loopBound
    context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
    if let path {
      do {
        let handle = try NIOFileHandle(_deprecatedPath: path)
        let region = FileRegion(fileHandle: handle, readerIndex: Int(start), endIndex: Int(end))
        context.write(Self.wrapOutboundOut(.body(.fileRegion(region))), promise: nil)
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil))).whenComplete { _ in
          try? handle.close(); loopBoundContext.value.close(promise: nil)
        }
      } catch {
        context.close(promise: nil)
      }
    } else {
      context.writeAndFlush(Self.wrapOutboundOut(.end(nil))).whenComplete { _ in
        loopBoundContext.value.close(promise: nil)
      }
    }
  }
}

private func DarwinOrGlibcClose(_ fd: Int32) -> Int32 {
  #if canImport(Darwin)
  Darwin.close(fd)
  #else
  Glibc.close(fd)
  #endif
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  init?(base64URLEncoded value: String) {
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
      (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
    self.init(base64Encoded: value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      .padding(toLength: (value.count + 3) / 4 * 4, withPad: "=", startingAt: 0))
  }
}
