#if os(Linux)
@preconcurrency import Foundation
import CStbImage
import Crypto
import Glibc
import TeaQLCore

/// Opt-in Linux PDF parser using host-managed Poppler executables.
public actor PopplerBlobContentVerifier: BlobContentVerifier, BlobVerifierReadiness {
  private let infoPath: String
  private let renderPath: String
  private let limitPath: String
  private let maximumInputBytes: Int64
  private let maximumPages: Int
  private let maximumRenderedBytes: Int
  private let concurrentVerifications: Int
  private var active = 0

  public init(infoPath: String, renderPath: String, limitPath: String,
              maximumInputBytes: Int64 = 32 * 1024 * 1024,
              maximumPages: Int = 100, maximumRenderedBytes: Int = 32 * 1024 * 1024,
              concurrentVerifications: Int = 2) throws {
    guard [infoPath, renderPath, limitPath].allSatisfy({ $0.hasPrefix("/") }),
      (1...100 * 1024 * 1024).contains(maximumInputBytes),
      (1...200).contains(maximumPages),
      (1...100 * 1024 * 1024).contains(maximumRenderedBytes),
      (1...32).contains(concurrentVerifications) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.infoPath = infoPath; self.renderPath = renderPath; self.limitPath = limitPath
    self.maximumInputBytes = maximumInputBytes; self.maximumPages = maximumPages
    self.maximumRenderedBytes = maximumRenderedBytes
    self.concurrentVerifications = concurrentVerifications
  }

  public func validateReady() async throws {
    guard [infoPath, renderPath, limitPath].allSatisfy({
      FileManager.default.isExecutableFile(atPath: $0)
    }) else { throw TeaQLError.execution("BLOB_CAPABILITY_MISSING") }
    do {
      for (path, prefix) in [(infoPath, "pdfinfo version "),
                             (renderPath, "pdftoppm version ")] {
        let output = try await Self.execute(limit: limitPath, binary: path,
          arguments: ["-v"], input: Data(), maximumOutput: 4096,
          timeout: 3, captureStderr: true)
        guard String(decoding: output, as: UTF8.self).hasPrefix(prefix) else {
          throw TeaQLError.execution("BLOB_CAPABILITY_MISSING")
        }
      }
    } catch { throw TeaQLError.execution("BLOB_CAPABILITY_MISSING") }
  }

  private static func execute(limit: String, binary: String, arguments: [String],
                              input: Data, maximumOutput: Int, timeout: Double,
                              captureStderr: Bool = false) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: limit)
      process.arguments = ["--cpu=10:10", "--as=536870912:536870912",
        "--fsize=1048576:1048576", "--", binary] + arguments
      process.environment = ["LC_ALL": "C"]
      let source = Pipe(); let output = Pipe()
      process.standardInput = source
      process.standardOutput = output
      process.standardError = captureStderr ? output : FileHandle.nullDevice
      do { try process.run() }
      catch { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
      try? source.fileHandleForReading.close()
      try? output.fileHandleForWriting.close()
      let writer = source.fileHandleForWriting
      DispatchQueue.global(qos: .userInitiated).async {
        writer.write(input)
        try? writer.close()
      }
      let timer = DispatchWorkItem {
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
      defer {
        timer.cancel()
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
      }
      var bytes = Data()
      do {
        while let chunk = try output.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
          guard chunk.count <= maximumOutput - bytes.count else {
            throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
          }
          bytes.append(chunk)
        }
      } catch { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
      }
      return bytes
    }.value
  }

  private static func number(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
      | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
  }

  private static func completePDF(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 32, bytes.starts(with: Array("%PDF-".utf8)),
      bytes[5] == 49 || bytes[5] == 50, bytes[6] == 46,
      (48...57).contains(bytes[7]) else { return false }
    var end = bytes.count
    while end > 0 && [32, 9, 10, 13, 12].contains(bytes[end - 1]) { end -= 1 }
    guard end >= 5, Array(bytes[(end - 5)..<end]) == Array("%%EOF".utf8) else {
      return false
    }
    return Data(bytes[0..<(end - 5)]).range(of: Data("startxref".utf8)) != nil
  }

  private static func pageCount(_ output: Data, maximum: Int) -> Int? {
    var pages: Int?
    var encrypted: String?
    for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
      if line.hasPrefix("Pages:") {
        guard pages == nil, let count = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces)),
          (1...maximum).contains(count) else { return nil }
        pages = count
      } else if line.hasPrefix("Encrypted:") {
        guard encrypted == nil else { return nil }
        encrypted = line.dropFirst(10).split(separator: " ").first.map(String.init)
      }
    }
    return encrypted == "no" ? pages : nil
  }

  private static func renderedPages(_ output: Data, expected: Int) -> Bool {
    let bytes = [UInt8](output)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    var offset = 0; var pages = 0
    while offset < bytes.count {
      guard pages < expected, bytes.count - offset >= 33,
        Array(bytes[offset..<(offset + 8)]) == signature,
        number(bytes, offset + 8) == 13,
        Array(bytes[(offset + 12)..<(offset + 16)]) == Array("IHDR".utf8) else { return false }
      let width = number(bytes, offset + 16); let height = number(bytes, offset + 20)
      guard (1...64).contains(width), (1...64).contains(height) else { return false }
      var position = offset + 8; var chunks = 0
      while true {
        guard chunks < 1000, bytes.count - position >= 12 else { return false }
        let length = number(bytes, position)
        guard length <= bytes.count - position - 12 else { return false }
        let kind = Array(bytes[(position + 4)..<(position + 8)])
        position += length + 12; chunks += 1
        if kind == Array("IEND".utf8) {
          guard length == 0 else { return false }
          let image = Data(bytes[offset..<position])
          let decoded = image.withUnsafeBytes { raw -> Bool in
            guard let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
              return false
            }
            var actualWidth: Int32 = 0; var actualHeight: Int32 = 0
            guard teaql_image_info(pointer, Int32(image.count),
              &actualWidth, &actualHeight) == 1,
              actualWidth == width, actualHeight == height else { return false }
            return teaql_image_decode(pointer, Int32(image.count),
              actualWidth, actualHeight) == 1
          }
          guard decoded else { return false }
          offset = position; pages += 1
          break
        }
      }
    }
    return pages == expected && offset == bytes.count
  }

  public func verify(reader: any ObjectByteReader, extension ext: String,
                     maximumBytes: Int64) async throws -> BlobVerifiedContent {
    guard ext == "pdf" else { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
    guard maximumBytes > 0 else { throw TeaQLError.execution("BLOB_POLICY_INVALID") }
    guard active < concurrentVerifications else {
      throw TeaQLError.execution("BLOB_VERIFICATION_BUSY")
    }
    active += 1
    defer { active -= 1 }
    let bound = min(maximumBytes, maximumInputBytes)
    var data = Data()
    while true {
      let chunk: Data
      do { chunk = try await reader.read(upToCount: 64 * 1024) }
      catch { throw TeaQLError.execution("BLOB_STORE_FAILED") }
      if chunk.isEmpty { break }
      guard Int64(chunk.count) <= bound - Int64(data.count) else {
        throw TeaQLError.execution("BLOB_SIZE_EXCEEDED")
      }
      data.append(chunk)
    }
    guard Self.completePDF([UInt8](data)) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    try await validateReady()
    let info = try await Self.execute(limit: limitPath, binary: infoPath,
      arguments: ["-"], input: data, maximumOutput: 65_536, timeout: 10)
    guard let pages = Self.pageCount(info, maximum: maximumPages) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    let rendered = try await Self.execute(limit: limitPath, binary: renderPath,
      arguments: ["-f", "1", "-l", String(pages), "-scale-to", "64", "-png", "-"],
      input: data, maximumOutput: maximumRenderedBytes, timeout: 10)
    guard Self.renderedPages(rendered, expected: pages) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest,
      contentType: "application/pdf")
  }
}
#endif
