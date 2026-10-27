import Foundation
import TeaQLCore

/// Immutable host-selected Blob retention terms; the host resolves them on a SQL lease.
public struct BlobRetentionPolicy: Sendable {
  public static let maximumEpochMilliseconds: Int64 = 8_640_000_000_000_000
  public let profile: String
  public let uploadMode: String
  public let unboundRetentionSeconds: Int64
  public let unreferencedRetentionSeconds: Int64
  public let minimumRetentionSeconds: Int64

  public init(profile: String, uploadMode: String, unboundRetentionSeconds: Int64,
    unreferencedRetentionSeconds: Int64, minimumRetentionSeconds: Int64) throws {
    guard !profile.isEmpty, profile == profile.trimmingCharacters(in: .whitespacesAndNewlines),
      profile.utf8.count <= 256,
      !profile.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      ["server_stream", "direct"].contains(uploadMode),
      Self.validSeconds(unboundRetentionSeconds), Self.validSeconds(unreferencedRetentionSeconds),
      Self.validSeconds(minimumRetentionSeconds) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.profile = profile; self.uploadMode = uploadMode
    self.unboundRetentionSeconds = unboundRetentionSeconds
    self.unreferencedRetentionSeconds = unreferencedRetentionSeconds
    self.minimumRetentionSeconds = minimumRetentionSeconds
  }

  public static func validTime(_ value: Int64) -> Bool {
    (0...maximumEpochMilliseconds).contains(value)
  }
  public static func validSeconds(_ value: Int64) -> Bool {
    (0...(maximumEpochMilliseconds / 1000)).contains(value)
  }
  public static func deadline(_ baseMs: Int64, seconds: Int64) throws -> Int64 {
    guard validTime(baseMs) else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
    guard validSeconds(seconds), seconds <= (maximumEpochMilliseconds - baseMs) / 1000 else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    return baseMs + seconds * 1000
  }
  public static func effectiveRetention(_ accepted: [Int64], proposed: Int64) throws -> Int64 {
    guard validSeconds(proposed), accepted.allSatisfy(validSeconds) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    return max(proposed, accepted.max() ?? 0)
  }
  public static func unreferencedEligibleAt(_ lastUnboundMs: Int64, seconds: Int64,
    floorUntilMs: Int64?) throws -> Int64 {
    let durationDeadline = try deadline(lastUnboundMs, seconds: seconds)
    if let floorUntilMs {
      guard validTime(floorUntilMs) else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
      return max(durationDeadline, floorUntilMs)
    }
    return durationDeadline
  }
  public static func requireBindable(status: String, nowMs: Int64, completedMs: Int64?,
    unboundSeconds: Int64, unreferencedEligibleMs: Int64?) throws {
    guard validTime(nowMs) else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
    if status == "initiated" { throw TeaQLError.execution("BLOB_UPLOAD_INCOMPLETE") }
    if ["deleting", "deleted"].contains(status) {
      throw TeaQLError.execution("BLOB_REFERENCE_EXPIRED")
    }
    if status == "uploaded_unbound" {
      guard let completedMs else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
      if nowMs >= (try deadline(completedMs, seconds: unboundSeconds)) {
        throw TeaQLError.execution("BLOB_REFERENCE_EXPIRED")
      }
    } else if status == "available" {
      if let unreferencedEligibleMs {
        guard validTime(unreferencedEligibleMs) else {
          throw TeaQLError.execution("BLOB_REFERENCE_INVALID")
        }
        if nowMs >= unreferencedEligibleMs {
          throw TeaQLError.execution("BLOB_REFERENCE_EXPIRED")
        }
      }
    } else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
  }
}

public protocol BlobUploadPolicyAuthorization: Sendable {
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobUploadTarget) async throws -> BlobRetentionPolicy
}

public protocol BlobBindingPolicyAuthorization: Sendable {
  func currentPolicyOnLease(actor: UserContext, lease: any GraphPhysicalSQLLease,
    target: BlobBindingTarget) async throws -> BlobRetentionPolicy
}
