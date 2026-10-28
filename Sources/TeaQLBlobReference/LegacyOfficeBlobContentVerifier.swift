#if os(Linux)
@preconcurrency import Foundation
import Crypto
import Glibc
import TeaQLCore

/// Opt-in binary DOC/XLS verifier using a host-managed, isolated LibreOffice conversion.
public actor LegacyOfficeBlobContentVerifier: BlobContentVerifier, BlobVerifierReadiness {
  private let sofficePath: String
  private let bwrapPath: String
  private let limitPath: String
  private let scratchRoot: String
  private let maximumInputBytes: Int64
  private let maximumConvertedBytes: Int64
  private let concurrentVerifications: Int
  private let packageVerifier: OfficeBlobContentVerifier
  private var active = 0

  public init(sofficePath: String, bwrapPath: String, limitPath: String,
              scratchRoot: String, maximumInputBytes: Int64 = 32 * 1024 * 1024,
              maximumConvertedBytes: Int64 = 10 * 1024 * 1024,
              concurrentVerifications: Int = 2) throws {
    guard [sofficePath, bwrapPath, limitPath, scratchRoot].allSatisfy({ $0.hasPrefix("/") }),
      URL(fileURLWithPath: scratchRoot).standardizedFileURL.path == scratchRoot,
      (1...100 * 1024 * 1024).contains(maximumInputBytes),
      (1...10 * 1024 * 1024).contains(maximumConvertedBytes),
      (1...32).contains(concurrentVerifications) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.sofficePath = sofficePath; self.bwrapPath = bwrapPath
    self.limitPath = limitPath; self.scratchRoot = scratchRoot
    self.maximumInputBytes = maximumInputBytes
    self.maximumConvertedBytes = maximumConvertedBytes
    self.concurrentVerifications = concurrentVerifications
    self.packageVerifier = try OfficeBlobContentVerifier(
      maximumInputBytes: maximumConvertedBytes, maximumDecodedBytes: 100 * 1024 * 1024,
      maximumParts: 10_000, maximumElements: 2_000_000,
      concurrentVerifications: concurrentVerifications)
  }

  public func validateReady() async throws {
    guard [sofficePath, bwrapPath, limitPath].allSatisfy({
      FileManager.default.isExecutableFile(atPath: $0)
    }) else { throw TeaQLError.execution("BLOB_CAPABILITY_MISSING") }
    var info = stat()
    guard Glibc.lstat(scratchRoot, &info) == 0,
      (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
      (info.st_mode & 0o777) == 0o700, info.st_uid == Glibc.getuid() else {
      throw TeaQLError.execution("BLOB_CAPABILITY_MISSING")
    }
    let probe = URL(fileURLWithPath: scratchRoot)
      .appendingPathComponent("ready-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.removeItem(at: probe)
    } catch { throw TeaQLError.execution("BLOB_CAPABILITY_MISSING") }
  }

  private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }

  private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
      UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
  }

  private static func validContainer(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 1024,
      bytes.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]),
      read16(bytes, 28) == 0xfffe, read16(bytes, 32) == 6 else { return false }
    let major = read16(bytes, 26); let shift = read16(bytes, 30)
    guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else { return false }
    let sectorSize = 1 << Int(shift)
    guard bytes.count % sectorSize == 0, bytes.count >= 2 * sectorSize else { return false }
    let sectors = UInt32(bytes.count / sectorSize - 1)
    let fat = read32(bytes, 44); let directory = read32(bytes, 48)
    let miniFat = read32(bytes, 60); let miniCount = read32(bytes, 64)
    let difat = read32(bytes, 68); let difatCount = read32(bytes, 72)
    return fat > 0 && fat <= sectors && directory < sectors &&
      read32(bytes, 56) == 4096 && miniCount <= sectors &&
      (miniCount == 0 || miniFat < sectors) && difatCount <= sectors &&
      (difatCount == 0 || difat < sectors)
  }

  private func convert(_ data: Data, extension ext: String) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      let manager = FileManager.default
      let job = URL(fileURLWithPath: self.scratchRoot)
        .appendingPathComponent("legacy-office-\(UUID().uuidString)", isDirectory: true)
      do {
        try manager.createDirectory(at: job, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: job) }
        let output = job.appendingPathComponent("output", isDirectory: true)
        let profile = job.appendingPathComponent("profile", isDirectory: true)
        for directory in [output, profile] {
          try manager.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        }
        let source = job.appendingPathComponent("source.\(ext)")
        try data.write(to: source, options: [.withoutOverwriting])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: self.limitPath)
        process.arguments = ["--cpu=20:20", "--as=1073741824:1073741824",
          "--fsize=10485760:10485760", "--", self.bwrapPath,
          "--unshare-net", "--unshare-pid", "--die-with-parent",
          "--ro-bind", "/usr", "/usr", "--ro-bind", "/lib", "/lib",
          "--ro-bind", "/lib64", "/lib64", "--symlink", "usr/bin", "/bin",
          "--ro-bind", "/etc", "/etc", "--dev", "/dev", "--proc", "/proc",
          "--dir", "/tmp", "--bind", job.path, job.path, "--clearenv",
          "--setenv", "LC_ALL", "C", "--setenv", "PATH", "/usr/bin:/bin",
          "--setenv", "HOME", job.path, "--setenv", "TMPDIR", job.path,
          "--", self.sofficePath, "-env:UserInstallation=\(profile.absoluteString)/",
          "--headless", "--nodefault", "--norestore", "--nolockcheck",
          "--convert-to", "\(ext)x", "--outdir", output.path, source.path]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
        let timer = DispatchWorkItem {
          if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else {
          throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
        }
        let entries = try manager.contentsOfDirectory(atPath: output.path)
        guard entries == ["source.\(ext)x"] else {
          throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
        }
        let result = output.appendingPathComponent(entries[0])
        var info = stat()
        guard Glibc.lstat(result.path, &info) == 0,
          (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          info.st_size > 0, info.st_size <= self.maximumConvertedBytes else {
          throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
        }
        let converted = try Data(contentsOf: result)
        guard Int64(converted.count) == info.st_size else {
          throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
        }
        return converted
      } catch let error as TeaQLError { throw error }
      catch { throw TeaQLError.execution("BLOB_STORE_FAILED") }
    }.value
  }

  public func verify(reader: any ObjectByteReader, extension ext: String,
                     maximumBytes: Int64) async throws -> BlobVerifiedContent {
    let mime: String
    switch ext {
    case "doc": mime = "application/msword"
    case "xls": mime = "application/vnd.ms-excel"
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
    guard Self.validContainer([UInt8](data)) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    try await validateReady()
    let converted = try await convert(data, extension: ext)
    do {
      _ = try await packageVerifier.verify(reader: ObjectDataReader(converted),
        extension: "\(ext)x", maximumBytes: Int64(converted.count))
    } catch { throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED") }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest,
      contentType: mime)
  }
}
#endif
