/// Hydration describes an existing/read-only value; it is not a request to
/// create business data. New entities must enter through a Context factory.
public struct EntityCreationError: Error, Sendable, Equatable, CustomStringConvertible {
  public let code = "ENTITY_CREATION_CONTEXT_REQUIRED"
  public let entityType: String
  public let suggestedFix = "Create new entities through the generated Q factory with a UserContext."

  public init(entityType: String) { self.entityType = entityType }
  public var description: String { "\(code): hydrated \(entityType) has no persisted version. \(suggestedFix)" }
}
