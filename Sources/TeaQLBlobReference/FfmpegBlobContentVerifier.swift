#if os(Linux)
@preconcurrency import Foundation
import Crypto
import Glibc
import TeaQLCore

/// Opt-in Linux MP3/MP4 parser using host-managed FFmpeg executables.
public actor FfmpegBlobContentVerifier: BlobContentVerifier, BlobVerifierReadiness {
  private let probePath: String
  private let decodePath: String
  private let limitPath: String
  private let maximumInputBytes: Int64
  private let maximumFrames: Int
  private let maximumVideoPixels: Int64
  private let concurrentVerifications: Int
  private var active = 0

  public init(probePath: String, decodePath: String, limitPath: String,
              maximumInputBytes: Int64 = 32 * 1024 * 1024,
              maximumFrames: Int = 100_000, maximumVideoPixels: Int64 = 16_000_000,
              concurrentVerifications: Int = 2) throws {
    guard [probePath, decodePath, limitPath].allSatisfy({ $0.hasPrefix("/") }),
      (1...100 * 1024 * 1024).contains(maximumInputBytes),
      (1...1_000_000).contains(maximumFrames),
      (1...64_000_000).contains(maximumVideoPixels),
      (1...32).contains(concurrentVerifications) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.probePath = probePath; self.decodePath = decodePath; self.limitPath = limitPath
    self.maximumInputBytes = maximumInputBytes; self.maximumFrames = maximumFrames
    self.maximumVideoPixels = maximumVideoPixels
    self.concurrentVerifications = concurrentVerifications
  }

  public func validateReady() async throws {
    guard [probePath, decodePath, limitPath].allSatisfy({
      FileManager.default.isExecutableFile(atPath: $0)
    }) else { throw TeaQLError.execution("BLOB_CAPABILITY_MISSING") }
    do {
      let probe = try await Self.execute(limit: limitPath, binary: probePath,
        arguments: ["-version"], input: Data(), timeout: 3)
      let decode = try await Self.execute(limit: limitPath, binary: decodePath,
        arguments: ["-version"], input: Data(), timeout: 3)
      guard String(decoding: probe, as: UTF8.self).hasPrefix("ffprobe version "),
        String(decoding: decode, as: UTF8.self).hasPrefix("ffmpeg version ") else {
        throw TeaQLError.execution("BLOB_CAPABILITY_MISSING")
      }
    } catch { throw TeaQLError.execution("BLOB_CAPABILITY_MISSING") }
  }

  private static func execute(limit: String, binary: String, arguments: [String],
                              input: Data, timeout: Double) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: limit)
      process.arguments = ["--cpu=10:10", "--as=536870912:536870912", "--", binary]
        + arguments
      process.environment = ["LC_ALL": "C"]
      let source = Pipe(); let output = Pipe()
      process.standardInput = source
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
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
      process.waitUntilExit()
      timer.cancel()
      let bytes = output.fileHandleForReading.readDataToEndOfFile()
      guard process.terminationStatus == 0, bytes.count <= 65_536 else {
        throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
      }
      return bytes
    }.value
  }

  public func verify(reader: any ObjectByteReader, extension ext: String,
                     maximumBytes: Int64) async throws -> BlobVerifiedContent {
    guard ext == "mp3" || ext == "mp4" else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
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
    guard ext == "mp3" ? Self.completeMP3(bytes, maximumFrames: maximumFrames)
      : Self.completeMP4(bytes) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    try await validateReady()
    let demuxer = ext == "mp3" ? "mp3" : "mov"
    let probe = try await Self.execute(limit: limitPath, binary: probePath,
      arguments: ["-v", "error", "-protocol_whitelist", "pipe", "-f", demuxer,
        "-count_frames", "-show_entries",
        "stream=codec_type,codec_name,nb_read_frames,width,height,sample_rate:stream_disposition=attached_pic:format=format_name",
        "-of", "json", "-i", "pipe:0"], input: data, timeout: 15)
    do {
      guard let json = try JSONSerialization.jsonObject(with: probe) as? [String: Any],
        let format = (json["format"] as? [String: Any])?["format_name"] as? String,
        let streams = json["streams"] as? [[String: Any]], (1...8).contains(streams.count) else {
        throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
      }
      if ext == "mp3" {
        guard format == "mp3", streams.count == 1, let stream = streams.first,
          stream["codec_type"] as? String == "audio",
          stream["codec_name"] as? String == "mp3",
          let rate = Int(stream["sample_rate"] as? String ?? ""), (8000...192_000).contains(rate),
          let frames = Int(stream["nb_read_frames"] as? String ?? ""),
          (1...maximumFrames).contains(frames) else {
          throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
        }
      } else {
        guard format.contains("mp4") else { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
        var videos = 0
        for stream in streams {
          guard let type = stream["codec_type"] as? String, type == "audio" || type == "video" else {
            throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
          }
          if type == "video" {
            videos += 1
            let width = stream["width"] as? Int ?? 0
            let height = stream["height"] as? Int ?? 0
            let attached = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0
            guard attached == 0, width > 0, height > 0,
              Int64(width) * Int64(height) <= maximumVideoPixels,
              let frames = Int(stream["nb_read_frames"] as? String ?? ""),
              (1...maximumFrames).contains(frames) else {
              throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
            }
          }
        }
        guard (1...4).contains(videos) else { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
      }
    } catch { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
    var args = ["-nostdin", "-v", "error", "-xerror", "-err_detect", "explode",
      "-threads", "1", "-protocol_whitelist", "pipe", "-f", demuxer, "-i", "pipe:0"]
    args += ext == "mp3" ? ["-map", "0:a:0"] : ["-map", "0:v", "-map", "0:a?"]
    args += ["-f", "null", "-"]
    _ = try await Self.execute(limit: limitPath, binary: decodePath,
      arguments: args, input: data, timeout: 15)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest,
      contentType: ext == "mp3" ? "audio/mpeg" : "video/mp4")
  }

  private static func number(_ data: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in offset..<(offset + count) { value = value << 8 | UInt64(data[index]) }
    return value
  }

  private static func completeMP3(_ data: [UInt8], maximumFrames: Int) -> Bool {
    var offset = 0
    if data.starts(with: Array("ID3".utf8)) {
      guard data.count >= 10, (2...4).contains(data[3]), data[4] != 255,
        data[6..<10].allSatisfy({ $0 & 0x80 == 0 }) else { return false }
      offset = 10 + (Int(data[6]) << 21 | Int(data[7]) << 14
        | Int(data[8]) << 7 | Int(data[9]))
      if data[3] == 4 && data[5] & 0x10 != 0 { offset += 10 }
      guard offset <= data.count else { return false }
    }
    var end = data.count
    if end >= 128 && Array(data[(end - 128)..<(end - 125)]) == Array("TAG".utf8) {
      end -= 128
    }
    var frames = 0; var firstRate = 0
    while offset < end {
      guard end - offset >= 4, frames < maximumFrames else { return false }
      let header = number(data, offset, 4)
      let version = Int(header >> 19 & 3); let layer = Int(header >> 17 & 3)
      let bit = Int(header >> 12 & 15); let sample = Int(header >> 10 & 3)
      guard header >> 21 == 0x7ff, version != 1, layer == 1,
        bit != 0, bit != 15, sample != 3 else { return false }
      var rate = [44_100, 48_000, 32_000][sample]
      if version == 2 { rate /= 2 } else if version == 0 { rate /= 4 }
      guard firstRate == 0 || firstRate == rate else { return false }
      firstRate = rate
      let rates = version == 3
        ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]
      let length = (version == 3 ? 144_000 : 72_000) * rates[bit] / rate
        + Int(header >> 9 & 1)
      guard length >= 4, length <= end - offset else { return false }
      offset += length; frames += 1
    }
    return frames > 0 && offset == end
  }

  private static func completeMP4(_ data: [UInt8]) -> Bool {
    let brands: Set<String> = ["isom", "iso2", "iso5", "iso6", "mp41", "mp42",
      "avc1", "M4V ", "M4V2", "dash"]
    var kinds = Set<String>(); var offset = 0; var count = 0
    while offset < data.count {
      guard data.count - offset >= 8, count < 1000 else { return false }
      var size = number(data, offset, 4)
      let kind = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
      var header = 8
      if size == 1 {
        guard data.count - offset >= 16 else { return false }
        size = number(data, offset + 8, 8); header = 16
      } else if size == 0 {
        guard kind == "mdat" else { return false }
        size = UInt64(data.count - offset)
      }
      guard size >= UInt64(header), size <= UInt64(data.count - offset) else { return false }
      if count == 0 {
        guard kind == "ftyp", size >= UInt64(header + 8),
          brands.contains(String(decoding: data[(offset + header)..<(offset + header + 4)],
            as: UTF8.self)) else { return false }
      }
      if (kind == "ftyp" || kind == "moov") && kinds.contains(kind) { return false }
      kinds.insert(kind); offset += Int(size); count += 1
    }
    return kinds.contains("ftyp") && kinds.contains("moov") && kinds.contains("mdat")
      && offset == data.count
  }
}
#endif
