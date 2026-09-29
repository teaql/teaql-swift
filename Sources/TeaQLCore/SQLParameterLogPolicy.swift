import Foundation

public enum SQLParameterLogPolicy: String, Sendable, Equatable, Codable {
  case unknown, plain, masked, credential

  public static func field(_ name: String, in entity: EntityDescriptor) -> Self {
    guard let property = entity.property(named: name) else { return .unknown }
    if LogPrivacy.credential(property.name) || LogPrivacy.credential(property.modelName ?? property.name)
      || LogPrivacy.credential(property.column) { return .credential }
    guard let maskFields = entity.auditMaskFields else { return .unknown }
    return maskFields.contains(property.modelName ?? property.name) ? .masked : .plain
  }
}
