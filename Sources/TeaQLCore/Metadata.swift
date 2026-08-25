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

  public init(
    name: String,
    modelName: String? = nil,
    column: String? = nil,
    type: PropertyType,
    nullable: Bool = false,
    isID: Bool = false,
    isVersion: Bool = false
  ) {
    self.name = name
    self.modelName = modelName
    self.column = column ?? name
    self.type = type
    self.nullable = nullable
    self.isID = isID
    self.isVersion = isVersion
  }
}

public struct EntityDescriptor: Sendable, Hashable, Codable {
  public let name: String
  public let table: String
  public let properties: [PropertyDescriptor]

  public init(name: String, table: String, properties: [PropertyDescriptor]) {
    self.name = name
    self.table = table
    self.properties = properties
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
}

public extension TeaQLEntity {
  /// Compatibility default for entities that do not track loaded fields.
  func toMutationRecord() -> TeaQLRecord { toRecord() }
}
