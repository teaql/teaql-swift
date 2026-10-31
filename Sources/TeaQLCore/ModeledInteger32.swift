import Foundation

/// Shared generated hydration/JSON/E admission. No Context, I/O or mutable
/// entity state participates in inspecting an intrinsic scalar domain.
@_spi(Generated) public enum ModeledInteger32 {
  public static func exactValue(_ value: TeaQLValue) -> Int64? {
    switch value {
    case .int(let number): return Int32(exactly: number).map(Int64.init)
    case .uint(let number): return Int32(exactly: number).map(Int64.init)
    case .decimal(let number):
      guard !number.isNaN, number >= Decimal(Int32.min), number <= Decimal(Int32.max) else { return nil }
      var original = number, integral = Decimal()
      NSDecimalRound(&integral, &original, 0, .plain)
      guard integral == number else { return nil }
      return NSDecimalNumber(decimal: number).int64Value
    default: return nil
    }
  }

  public static func error(_ value: TeaQLValue, entity: EntityDescriptor, field: String) -> CheckException? {
    guard let property = entity.property(named: field), property.isInt32,
      value != .null, exactValue(value) == nil else { return nil }
    return CheckException([violation(entity, property)])
  }

  /// Normalize only actually present Integer values, retaining absence/null and
  /// leaving Long, identity, version, dynamic members and input records alone.
  public static func readRecord(_ record: TeaQLRecord, entity: EntityDescriptor) throws -> TeaQLRecord {
    try validateMetadata(entity)
    var result = record
    for property in entity.properties where property.isInt32 {
      for name in Set([property.name, property.modelName ?? property.name, property.column]) {
        guard let value = record[name] else { continue }
        if value == .null {
          if !property.nullable { throw CheckException([violation(entity, property)]) }
          continue
        }
        guard let number = exactValue(value) else { throw CheckException([violation(entity, property)]) }
        if value != .int(number) { result[name] = .int(number) }
      }
    }
    return result
  }

  package static func validateMetadata(_ entity: EntityDescriptor) throws {
    for property in entity.properties where property.isInt32 {
      guard property.type == .int && !property.isID && !property.isVersion
        && !property.isRelation && property.referencedEntity == nil else {
        throw TeaQLError.execution("INVALID_INTEGER32_METADATA: \(entity.name).\(property.modelName ?? property.name)")
      }
    }
  }

  package static func normalizeMutation(_ values: inout TeaQLRecord, entity: EntityDescriptor,
    violations: inout [CheckResult]) throws {
    try validateMetadata(entity)
    for property in entity.properties where property.isInt32 {
      let name = property.modelName ?? property.name
      guard let value = values[name], value != .null else { continue }
      if let number = exactValue(value) {
        if value != .int(number) { values[name] = .int(number) }
      } else if !violations.contains(where: { $0.ruleID == "invalid_type" && $0.location == .property(name) }) {
        violations.append(violation(entity, property))
      }
    }
  }

  private static func violation(_ entity: EntityDescriptor, _ property: PropertyDescriptor) -> CheckResult {
    let field = property.modelName ?? property.name
    return CheckResult(ruleID: "invalid_type", location: .property(field),
      message: "invalid field \(field): expected an exact signed 32-bit Integer", entityType: entity.name)
  }
}
