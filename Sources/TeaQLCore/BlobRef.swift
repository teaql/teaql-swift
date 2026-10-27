import Foundation

/// A stable catalog identity. Possessing a Key never authorizes binding or reading it.
public struct BlobRef: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
  public let key: String

  public init(_ key: String) throws {
    let bytes = Array(key.utf8)
    guard bytes.count >= 6, bytes.count <= 128,
      bytes.starts(with: Array("blob_".utf8)),
      bytes.dropFirst(5).allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
          || $0 == 45 || $0 == 95
      }) else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
    self.key = key
  }

  public init(sqlText: String) throws { try self.init(sqlText) }
  public var sqlText: String { key }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    try self.init(value)
  }

  /// Generic JSON output has no current authorization context or URL expiry.
  public func encode(to encoder: Encoder) throws {
    throw TeaQLError.execution("BLOB_PRESENTATION_REQUIRED")
  }

  public var description: String { "BlobRef[masked]" }
  public var debugDescription: String { description }
}

/// Model-declared format restrictions; a trusted server policy may narrow these further.
public struct BlobFieldSpec: Sendable, Hashable, Codable {
  public static let capability = "blob.v1"
  public let entity: String
  public let field: String
  public let allowedExtensions: [String]
  public let allowedContentTypes: [String]
  public let nullable: Bool
  public let policyProfile: String
  public var maxFiles: Int { 1 }

  private enum CodingKeys: String, CodingKey {
    case entity, field, allowedExtensions, nullable, policyProfile
  }

  private static let contentTypes: [String: String] = [
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
    "mp4": "video/mp4", "mp3": "audio/mpeg",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pdf": "application/pdf",
  ]

  /// Resolve only the frozen Blob format set, never a client MIME hint.
  public static func mime(forExtension value: String) -> String? { contentTypes[value] }

  public init(entity: String, field: String, extensions: [String], nullable: Bool,
              policyProfile: String) throws {
    for value in [entity, field, policyProfile] {
      guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw TeaQLError.execution("BLOB_POLICY_INVALID")
      }
    }
    let normalized = Array(Set(extensions)).sorted()
    guard !normalized.isEmpty, normalized.allSatisfy({ Self.contentTypes[$0] != nil }) else {
      throw TeaQLError.execution("BLOB_FORMAT_NOT_ALLOWED")
    }
    self.entity = entity
    self.field = field
    self.allowedExtensions = normalized
    self.allowedContentTypes = Array(Set(normalized.compactMap { Self.contentTypes[$0] })).sorted()
    self.nullable = nullable
    self.policyProfile = policyProfile
  }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(entity: fields.decode(String.self, forKey: .entity),
      field: fields.decode(String.self, forKey: .field),
      extensions: fields.decode([String].self, forKey: .allowedExtensions),
      nullable: fields.decode(Bool.self, forKey: .nullable),
      policyProfile: fields.decode(String.self, forKey: .policyProfile))
  }

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(entity, forKey: .entity)
    try fields.encode(field, forKey: .field)
    try fields.encode(allowedExtensions, forKey: .allowedExtensions)
    try fields.encode(nullable, forKey: .nullable)
    try fields.encode(policyProfile, forKey: .policyProfile)
  }
}
