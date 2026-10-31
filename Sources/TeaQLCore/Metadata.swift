import Foundation

public enum PropertyType: String, Sendable, Codable {
  case bool, int, uint, double, decimal, string, date, localDateTime, timestamp, data, json
}

public struct PropertyDescriptor: Sendable, Hashable, Codable {
  public let name: String
  public let modelName: String?
  public let column: String
  public let type: PropertyType
  public let nullable: Bool
  public let isID: Bool
  public let isVersion: Bool
  /// Explicit generated forward relation marker. Native property names need
  /// not end in `Id`, so schema indexes must not depend on that spelling.
  public let isRelation: Bool
  /// Trusted generated metadata for type-qualified graph references.
  public let referencedEntity: String?
  /// KSML Integer uses a signed 32-bit domain even when its native carrier is
  /// Int64. Long, identity, version and relation fields must not set this flag.
  public let isInt32: Bool

  private enum CodingKeys: String, CodingKey {
    case name, modelName, column, type, nullable, isID, isVersion, isRelation, referencedEntity, isInt32
  }

  public init(
    name: String,
    modelName: String? = nil,
    column: String? = nil,
    type: PropertyType,
    nullable: Bool = false,
    isID: Bool = false,
    isVersion: Bool = false,
    isRelation: Bool = false,
    referencedEntity: String? = nil,
    isInt32: Bool = false
  ) {
    self.name = name
    self.modelName = modelName
    self.column = column ?? name
    self.type = type
    self.nullable = nullable
    self.isID = isID
    self.isVersion = isVersion
    self.isRelation = isRelation
    self.referencedEntity = referencedEntity
    self.isInt32 = isInt32
  }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    name = try fields.decode(String.self, forKey: .name)
    modelName = try fields.decodeIfPresent(String.self, forKey: .modelName)
    column = try fields.decodeIfPresent(String.self, forKey: .column) ?? name
    type = try fields.decode(PropertyType.self, forKey: .type)
    nullable = try fields.decodeIfPresent(Bool.self, forKey: .nullable) ?? false
    isID = try fields.decodeIfPresent(Bool.self, forKey: .isID) ?? false
    isVersion = try fields.decodeIfPresent(Bool.self, forKey: .isVersion) ?? false
    isRelation = try fields.decodeIfPresent(Bool.self, forKey: .isRelation) ?? false
    referencedEntity = try fields.decodeIfPresent(String.self, forKey: .referencedEntity)
    isInt32 = try fields.decodeIfPresent(Bool.self, forKey: .isInt32) ?? false
    if isInt32 && (type != .int || isID || isVersion || isRelation || referencedEntity != nil) {
      throw DecodingError.dataCorruptedError(forKey: .isInt32, in: fields,
        debugDescription: "The Integer marker requires a non-identity signed integral scalar")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(name, forKey: .name); try fields.encodeIfPresent(modelName, forKey: .modelName)
    try fields.encode(column, forKey: .column); try fields.encode(type, forKey: .type)
    try fields.encode(nullable, forKey: .nullable); try fields.encode(isID, forKey: .isID)
    try fields.encode(isVersion, forKey: .isVersion); try fields.encode(isRelation, forKey: .isRelation)
    try fields.encodeIfPresent(referencedEntity, forKey: .referencedEntity)
    // Older 64-bit descriptors keep their exact metadata shape.
    if isInt32 { try fields.encode(true, forKey: .isInt32) }
  }
}

public struct EntityDescriptor: Sendable, Hashable, Codable {
  public let name: String
  public let table: String
  public let properties: [PropertyDescriptor]
  /// Canonical KSML field names. Optional for decoding older descriptor snapshots.
  public let auditMaskFields: [String]?

  public init(name: String, table: String, properties: [PropertyDescriptor]) {
    self.name = name
    self.table = table
    self.properties = properties
    self.auditMaskFields = nil
  }

  public init(name: String, table: String, properties: [PropertyDescriptor], auditMaskFields: [String]) {
    self.name = name
    self.table = table
    self.properties = properties
    self.auditMaskFields = auditMaskFields
  }

  public var idProperty: PropertyDescriptor? { properties.first(where: \.isID) }
  public var versionProperty: PropertyDescriptor? { properties.first(where: \.isVersion) }
  public func property(named name: String) -> PropertyDescriptor? {
    properties.first { $0.name == name || $0.modelName == name || $0.column == name }
  }
}

public protocol TeaQLEntity: Sendable, Codable {
  static var descriptor: EntityDescriptor { get }
  static func from(record: TeaQLRecord) throws -> Self
  var id: Int64 { get set }
  var version: Int64 { get set }
  func toRecord() -> TeaQLRecord
  /// Returns only fields that are loaded and eligible for persistence.
  func toMutationRecord() -> TeaQLRecord
}

public protocol TeaQLMutationRootedEntity: TeaQLEntity {
  var teaqlEntityRoot: EntityRoot { get }
  var teaqlEntityKey: EntityKey { get }
  var teaqlLoadedSnapshot: LoadedEntitySnapshot? { get }
}

public extension TeaQLMutationRootedEntity {
  var teaqlLoadedSnapshot: LoadedEntitySnapshot? { nil }
}

public extension TeaQLEntity {
  /// Compatibility default for entities that do not track loaded fields.
  func toMutationRecord() -> TeaQLRecord { toRecord() }
}
