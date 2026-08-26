import Foundation

/// A generated, passive inventory of TeaQL runtime metadata.
public struct RuntimeModule: Sendable {
  public let name: String
  public let entities: [EntityDescriptor]
  public let checkers: [String: any EntityChecker]
  public let rootEntities: [BootstrapEntity]
  public let constantEntities: [BootstrapEntity]

  public init(
    name: String, entities: [EntityDescriptor],
    checkers: [String: any EntityChecker] = [:],
    rootEntities: [BootstrapEntity] = [],
    constantEntities: [BootstrapEntity] = []
  ) {
    precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.name = name
    self.entities = entities
    self.checkers = checkers
    self.rootEntities = rootEntities
    self.constantEntities = constantEntities
  }
}

public struct BootstrapEntity: Sendable, Equatable {
  public let entity: String
  public let id: Int64
  public let values: TeaQLRecord
  public init(entity: String, id: Int64, values: TeaQLRecord) {
    self.entity = entity; self.id = id; self.values = values
  }
}

/// Application-owned runtime assembly. Installing metadata never changes a database schema.
public struct TeaQLRuntime: Sendable {
  private var descriptorsByName: [String: EntityDescriptor] = [:]
  private var checkersByName: [String: any EntityChecker] = [:]

  public init() {}

  public mutating func install(_ module: RuntimeModule) throws {
    for descriptor in module.entities {
      if let existing = descriptorsByName[descriptor.name], existing != descriptor {
        throw TeaQLError.execution(
          "Conflicting entity descriptor \(descriptor.name) while installing module \(module.name)")
      }
      descriptorsByName[descriptor.name] = descriptor
    }
    for (name, checker) in module.checkers { checkersByName[name] = checker }
  }

  public var entities: [EntityDescriptor] {
    descriptorsByName.values.sorted { $0.name < $1.name }
  }

  public func entity(named name: String) -> EntityDescriptor? {
    descriptorsByName[name]
  }

  public func checker(named name: String) -> (any EntityChecker)? { checkersByName[name] }
}
