import CStbImage
import Crypto
import Foundation
import TeaQLCore

/// Explicit in-process JPEG/PNG parser with bounded input, pixels and admissions.
public actor StbImageBlobContentVerifier: BlobContentVerifier {
  private let maximumInputBytes: Int64
  private let maximumDecodedBytes: Int64
  private let concurrentVerifications: Int
  private var active = 0

  public init(maximumInputBytes: Int64 = 32 * 1024 * 1024,
              maximumDecodedBytes: Int64 = 100 * 1024 * 1024,
              concurrentVerifications: Int = 2) throws {
    guard (1...100 * 1024 * 1024).contains(maximumInputBytes),
      (4...512 * 1024 * 1024).contains(maximumDecodedBytes),
      (1...32).contains(concurrentVerifications) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.maximumInputBytes = maximumInputBytes
    self.maximumDecodedBytes = maximumDecodedBytes
    self.concurrentVerifications = concurrentVerifications
  }

  public func verify(reader: any ObjectByteReader, extension ext: String,
                     maximumBytes: Int64) async throws -> BlobVerifiedContent {
    let mime: String
    switch ext {
    case "jpg", "jpeg": mime = "image/jpeg"
    case "png": mime = "image/png"
    default: throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
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
    let bytes = [UInt8](data)
    guard !bytes.isEmpty, ext == "png" ? Self.completePNG(bytes) : Self.completeJPEG(bytes) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    let dimensions: (Int32, Int32)? = data.withUnsafeBytes { raw in
      guard let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
      var width: Int32 = 0
      var height: Int32 = 0
      guard teaql_image_info(pointer, Int32(data.count), &width, &height) == 1 else { return nil }
      return (width, height)
    }
    guard let dimensions, dimensions.0 > 0, dimensions.1 > 0,
      Int64(dimensions.0) * Int64(dimensions.1) * 4 <= maximumDecodedBytes else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    let decoded = data.withUnsafeBytes { raw in
      guard let pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
      return teaql_image_decode(pointer, Int32(data.count), dimensions.0, dimensions.1) == 1
    }
    guard decoded else { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest, contentType: mime)
  }

  private static func completeJPEG(_ bytes: [UInt8]) -> Bool {
    bytes.count >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8
      && bytes[bytes.count - 2] == 0xff && bytes[bytes.count - 1] == 0xd9
  }

  private static func completePNG(_ bytes: [UInt8]) -> Bool {
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.count >= 45, Array(bytes[0..<8]) == signature else { return false }
    var offset = 8
    var chunks = 0
    var imageData = false
    while offset <= bytes.count - 12 {
      let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
        | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
      guard length <= bytes.count - offset - 12 else { return false }
      let kind = Array(bytes[(offset + 4)..<(offset + 8)])
      guard kind.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
        return false
      }
      if chunks == 0 && (kind != Array("IHDR".utf8) || length != 13) { return false }
      var crc: UInt32 = 0xffffffff
      for index in (offset + 4)..<(offset + 8 + length) {
        crc ^= UInt32(bytes[index])
        for _ in 0..<8 { crc = (crc & 1) == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
      }
      let expected = UInt32(bytes[offset + 8 + length]) << 24
        | UInt32(bytes[offset + 9 + length]) << 16
        | UInt32(bytes[offset + 10 + length]) << 8
        | UInt32(bytes[offset + 11 + length])
      guard crc ^ 0xffffffff == expected else { return false }
      offset += length + 12
      chunks += 1
      if kind == Array("IDAT".utf8) { imageData = true }
      if kind == Array("IEND".utf8) {
        return length == 0 && imageData && offset == bytes.count
      }
    }
    return false
  }
}
