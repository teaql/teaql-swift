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
  /// Canonical model reference -> required active-root type. No application
  /// tenant/permission interpretation or mutable execution state lives here.
  public let contextRootFields: [String: [String: String]]
  public let contextFixFields: [String: [String: ContextFieldFunctions]]

  public init(
    name: String, entities: [EntityDescriptor],
    checkers: [String: any EntityChecker] = [:],
    generatedBootstrap: (@Sendable (UserContext) async throws -> Void)? = nil,
    wireMetadata: [String: WireEntityMetadata] = [:],
    contextRootFields: [String: [String: String]] = [:],
    contextFixFields: [String: [String: ContextFieldFunctions]] = [:]
  ) {
    precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.name = name
    self.entities = entities
    self.checkers = checkers
    self.generatedBootstrap = generatedBootstrap
    self.wireMetadata = wireMetadata
    self.contextRootFields = contextRootFields
    self.contextFixFields = contextFixFields
  }
}

/// Application-owned runtime assembly. Installing metadata never changes a database schema.
public struct TeaQLRuntime: Sendable {
  private var descriptorsByName: [String: EntityDescriptor] = [:]
  private var checkersByName: [String: any EntityChecker] = [:]
  private var wireMetadataByName: [String: WireEntityMetadata] = [:]
  private var managedRootsByName: [String: [String: String]] = [:]
  private var contextFixByName: [String: [String: ContextFieldFunctions]] = [:]

  public init() {}

  public mutating func install(_ module: RuntimeModule) throws {
    for descriptor in module.entities { try ModeledInteger32.validateMetadata(descriptor) }
    let available = Dictionary(module.entities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    for (entity, fields) in module.contextFixFields {
      guard let descriptor = available[entity] ?? descriptorsByName[entity] else { throw TeaQLError.execution("Context Fix requires a modeled entity") }
      for (field, declaration) in fields {
        guard let property = descriptor.property(named: field), field == (property.modelName ?? property.name), !property.isID, !property.isVersion,
          declaration.create != nil || declaration.update != nil,
          declaration.create.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
          declaration.update.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
          property.createFunction == nil || property.createFunction == declaration.create,
          property.updateFunction == nil || property.updateFunction == declaration.update else {
          throw TeaQLError.execution("Context Fix requires canonical non-identity fields and consistent functions")
        }
      }
    }
    for (name, fields) in module.contextRootFields {
      guard let entity = available[name] ?? descriptorsByName[name], !fields.isEmpty else {
        throw TeaQLError.execution("Invalid context-root metadata for \(name)")
      }
      for (field, target) in fields {
        guard let property = entity.property(named: field), field == (property.modelName ?? property.name),
          property.isRelation, !property.isID, !property.isVersion,
          property.type == .int || property.type == .uint,
          property.referencedEntity == target, available[target] != nil || descriptorsByName[target] != nil else {
          throw TeaQLError.execution("Invalid context-root metadata for \(name).\(field)")
        }
      }
      if let existing = managedRootsByName[name], existing != fields {
        throw TeaQLError.execution("Conflicting context-root metadata for \(name)")
      }
    }
    for descriptor in module.entities {
      if let existing = descriptorsByName[descriptor.name], existing != descriptor {
        throw TeaQLError.execution(
          "Conflicting entity descriptor \(descriptor.name) while installing module \(module.name)")
      }
      descriptorsByName[descriptor.name] = descriptor
    }
    for (name, checker) in module.checkers { checkersByName[name] = checker }
    for (name, metadata) in module.wireMetadata { wireMetadataByName[name] = metadata }
    for (name, fields) in module.contextRootFields { managedRootsByName[name] = fields }
    for (name, fields) in module.contextFixFields { contextFixByName[name, default: [:]].merge(fields) { _, new in new } }
  }

  public var entities: [EntityDescriptor] {
    descriptorsByName.values.sorted { $0.name < $1.name }
  }

  public func entity(named name: String) -> EntityDescriptor? {
    descriptorsByName[name]
  }

  public func checker(named name: String) -> (any EntityChecker)? { checkersByName[name] }
  public func wireMetadata(named name: String) -> WireEntityMetadata? { wireMetadataByName[name] }
  package func contextRootFields(named name: String) -> [String: String] { managedRootsByName[name] ?? [:] }
  package func contextFixFields(named name: String) -> [String: ContextFieldFunctions] { contextFixByName[name] ?? [:] }
}
