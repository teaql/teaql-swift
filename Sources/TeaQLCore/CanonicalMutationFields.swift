/// Mutation identity is the KSML name, not a native member or storage alias.
/// Query hydration may accept those aliases; mutation admission must not.
package enum CanonicalMutationFields {
  package static func validate(_ values: TeaQLRecord, entity: EntityDescriptor) throws {
    let canonical = Set(entity.properties.map { $0.modelName ?? $0.name })
    let violations = values.keys.sorted().compactMap { field -> CheckResult? in
      guard !canonical.contains(field) else { return nil }
      let property = entity.property(named: field)
      return CheckResult(ruleID: "unknown_field",
        location: .property(property?.modelName ?? property?.name ?? field),
        message: "Mutation fields must use canonical KSML names", entityType: entity.name)
    }
    if !violations.isEmpty { throw CheckException(violations) }
  }
}
