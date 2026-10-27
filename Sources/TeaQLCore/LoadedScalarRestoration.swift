import Foundation

/// Save-time normalization of modeled scalars with trusted loaded provenance.
/// This never treats an absent snapshot field as a known null, never visits an
/// unrelated key, and never turns a new entity or a deletion into a no-op.
public enum LoadedScalarRestoration {
  public static func discardRestoredFields<Entity: TeaQLEntity>(of entity: Entity) {
    guard let rooted = entity as? any TeaQLMutationRootedEntity,
      let snapshot = rooted.teaqlLoadedSnapshot, snapshot.version == entity.version else { return }
    rooted.teaqlEntityRoot.discardRestoredFields(rooted.teaqlEntityKey,
      snapshot: snapshot, descriptor: Entity.descriptor)
  }

  package static func same(_ value: TeaQLValue, _ original: TeaQLValue, property: PropertyDescriptor) -> Bool {
    if case .null = value, case .null = original { return property.nullable }
    switch property.type {
    case .timestamp:
      guard let left = milliseconds(value), let right = milliseconds(original) else { return false }
      return left == right
    case .date:
      guard let left = calendarDay(value), let right = calendarDay(original) else { return false }
      return left == right
    case .bool: if case .bool(let left) = value, case .bool(let right) = original { return left == right }
    case .int: if case .int(let left) = value, case .int(let right) = original { return left == right }
    case .uint: if case .uint(let left) = value, case .uint(let right) = original { return left == right }
    case .string: if case .string(let left) = value, case .string(let right) = original { return left == right }
    case .localDateTime:
      if case .localDateTime(let left) = value, case .localDateTime(let right) = original { return left == right }
    case .data: if case .data(let left) = value, case .data(let right) = original { return left == right }
    case .double:
      if case .double(let left) = value, case .double(let right) = original {
        return left.isFinite && right.isFinite && left.bitPattern == right.bitPattern
      }
    case .decimal:
      if case .decimal(let left) = value, case .decimal(let right) = original { return sameDecimal(left, right) }
    case .json: return sameJSON(value, original)
    }
    return false
  }

  private static func sameDecimal(_ left: Decimal, _ right: Decimal) -> Bool {
    !left.isNaN && !right.isNaN && left == right && left.exponent == right.exponent && left.sign == right.sign
  }

  private static func milliseconds(_ value: TeaQLValue) -> Int64? {
    switch value {
    case .timestamp(let number): return number
    case .date(let date):
      // Only integral, exactly representable milliseconds may bridge native
      // Date hydration and a generated Timestamp setter. Never truncate.
      return Int64(exactly: date.timeIntervalSince1970 * 1_000)
    default: return nil
    }
  }

  private static func calendarDay(_ value: TeaQLValue) -> String? {
    let formatter = ISO8601DateFormatter()
    switch value {
    case .calendarDate(let text):
      guard text.utf8.count == 10, let date = formatter.date(from: text + "T00:00:00Z"),
        formatter.string(from: date) == text + "T00:00:00Z" else { return nil }
      return text
    case .date(let date):
      guard date.timeIntervalSince1970.isFinite,
        date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) == 0 else { return nil }
      return String(formatter.string(from: date).prefix(10))
    default: return nil
    }
  }

  private static func sameJSON(_ left: TeaQLValue, _ right: TeaQLValue) -> Bool {
    switch (left, right) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.uint(let a), .uint(let b)): return a == b
    case (.string(let a), .string(let b)): return a == b
    case (.double(let a), .double(let b)): return a.isFinite && b.isFinite && a.bitPattern == b.bitPattern
    case (.decimal(let a), .decimal(let b)): return sameDecimal(a, b)
    case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { sameJSON($0, $1) }
    case (.object(let a), .object(let b)):
      return a.count == b.count && a.allSatisfy { key, value in b[key].map { sameJSON(value, $0) } == true }
    default: return false
    }
  }
}
