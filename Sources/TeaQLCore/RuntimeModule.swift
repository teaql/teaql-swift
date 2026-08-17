import Foundation

/// A generated, passive inventory of TeaQL runtime metadata.
public struct RuntimeModule: Sendable {
  public let name: String
  public let entities: [EntityDescriptor]

  public init(name: String, entities: [EntityDescriptor]) {
    precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.name = name
    self.entities = entities
  }
}

/// Application-owned runtime assembly. Installing metadata never changes a database schema.
public struct TeaQLRuntime: Sendable {
  private var descriptorsByName: [String: EntityDescriptor] = [:]

  public init() {}

  public mutating func install(_ module: RuntimeModule) throws {
    for descriptor in module.entities {
      if let existing = descriptorsByName[descriptor.name], existing != descriptor {
        throw TeaQLError.execution(
          "Conflicting entity descriptor \(descriptor.name) while installing module \(module.name)")
      }
      descriptorsByName[descriptor.name] = descriptor
    }
  }

  public var entities: [EntityDescriptor] {
    descriptorsByName.values.sorted { $0.name < $1.name }
  }

  public func entity(named name: String) -> EntityDescriptor? {
    descriptorsByName[name]
  }
}
