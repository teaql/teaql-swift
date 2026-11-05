/// Boolean is a scalar domain, not numeric or string truthiness. SQLite's
/// physical INTEGER representation is decoded separately at the storage edge.
package enum ModeledBoolean {
  package static func violation(_ value: TeaQLValue, entity: EntityDescriptor,
    property: PropertyDescriptor) -> CheckResult?
  {
    guard property.type == .bool else { return nil }
    // Requiredness belongs to Checker; partial records and nullable values
    // must not turn into a new full-entity validation requirement here.
    switch value {
    case .bool, .null: return nil
    default: return invalidValue(entity: entity, property: property)
    }
  }

  package static func invalidValue(entity: EntityDescriptor, property: PropertyDescriptor) -> CheckResult {
    let field = property.modelName ?? property.name
    return CheckResult(ruleID: "invalid_type", location: .property(field),
      message: "invalid field \(field): expected a Boolean", entityType: entity.name)
  }

  package static func validateMutation(_ values: TeaQLRecord, entity: EntityDescriptor,
    violations: inout [CheckResult])
  {
    for (name, value) in values {
      guard let property = entity.property(named: name),
        let result = violation(value, entity: entity, property: property) else { continue }
      if !violations.contains(where: { $0.ruleID == result.ruleID && $0.location == result.location }) {
        violations.append(result)
      }
    }
  }
}
