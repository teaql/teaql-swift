import Foundation

/// A generated, passive inventory of TeaQL runtime metadata.
public struct RuntimeModule: Sendable {
  public let name: String
  public let entities: [EntityDescriptor]
  public let checkers: [String: any EntityChecker]
  /// Generated application-layer bootstrap. It runs after physical schema
  /// creation and uses the ordinary typed Mutation lifecycle.
  package let generatedBootstrap: (@Sendable (UserContext) async throws -> Void)?
  public let wireMetadata: [String: WireEntityMetadata]

  public init(
    name: String, entities: [EntityDescriptor],
    checkers: [String: any EntityChecker] = [:],
    generatedBootstrap: (@Sendable (UserContext) async throws -> Void)? = nil,
    wireMetadata: [String: WireEntityMetadata] = [:]
  ) {
    precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.name = name
    self.entities = entities
    self.checkers = checkers
    self.generatedBootstrap = generatedBootstrap
    self.wireMetadata = wireMetadata
  }
}

/// Application-owned runtime assembly. Installing metadata never changes a database schema.
public struct TeaQLRuntime: Sendable {
  private var descriptorsByName: [String: EntityDescriptor] = [:]
  private var checkersByName: [String: any EntityChecker] = [:]
  private var wireMetadataByName: [String: WireEntityMetadata] = [:]

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
    for (name, metadata) in module.wireMetadata { wireMetadataByName[name] = metadata }
  }

  public var entities: [EntityDescriptor] {
    descriptorsByName.values.sorted { $0.name < $1.name }
  }

  public func entity(named name: String) -> EntityDescriptor? {
    descriptorsByName[name]
  }

  public func checker(named name: String) -> (any EntityChecker)? { checkersByName[name] }
  public func wireMetadata(named name: String) -> WireEntityMetadata? { wireMetadataByName[name] }
}
