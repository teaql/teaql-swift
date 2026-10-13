import Foundation

/// Generated, trusted field types and aliases. Never supplied by the search input.
public struct GeneratedSearchModel: Sendable {
  public let model: SearchModel
  public let queryFields: [String: String]
  public init(model: SearchModel, queryFields: [String: String]) {
    self.model = model
    self.queryFields = queryFields
  }
}

extension DynamicSearch {
  /// Bind scalar fields through generated metadata and the existing local-search boundary.
  /// Related paths need explicit trusted bindings through merge; the default does not
  /// infer related authorization or replace existing query scope.
  public static func mergeGeneratedScalar(
    _ base: SelectQuery, source: String, models: [String: GeneratedSearchModel],
    warn: ((DynamicSearchWarning) -> Void)? = nil
  ) throws -> DynamicSearchResult {
    func column(_ path: String) throws -> String {
      guard !path.contains(".") else {
        throw DynamicSearchError.invalid("Related paths require a trusted relation binding")
      }
      guard let key = models[base.entity.name]?.queryFields[path], !key.isEmpty else {
        throw DynamicSearchError.invalid("Missing trusted field binding")
      }
      return key
    }
    func filter(_ item: DynamicSearchFilter) throws -> TeaQLExpression {
      let key = try column(item.fieldPath)
      guard let kind = models[base.entity.name]?.model.fields[item.fieldPath] else {
        throw DynamicSearchError.invalid("Missing trusted field type")
      }
      if item.operation == "$contains" {
        guard case .string(let text) = item.value else {
          throw DynamicSearchError.invalid("Contains requires a string")
        }
        return .contains(key, text)
      }
      if item.operation == "$in" || item.operation == "$notIn" {
        guard case .array(let raw) = item.value else {
          throw DynamicSearchError.invalid("Invalid value list")
        }
        let values = try raw.map { try generatedSearchValue($0, kind: kind) }
        return item.operation == "$in" ? .inList(key, values) : .notInList(key, values)
      }
      if item.value == .null {
        switch item.operation {
        case "$eq": return .isNull(key)
        case "$ne": return .isNotNull(key)
        default: throw DynamicSearchError.invalid("Null supports only equality predicates")
        }
      }
      let value = try generatedSearchValue(item.value, kind: kind)
      switch item.operation {
      case "$eq": return .equal(key, value)
      case "$ne": return .notEqual(key, value)
      case "$gt": return .greaterThan(key, value)
      case "$gte": return .greaterThanOrEqual(key, value)
      case "$lt": return .lessThan(key, value)
      case "$lte": return .lessThanOrEqual(key, value)
      default: throw DynamicSearchError.invalid("Unsupported operator")
      }
    }
    return try merge(base, source: source, models: models.mapValues(\.model),
      filterBinding: filter, orderBinding: { OrderBy(try column($0.fieldPath), $0.direction) }, warn: warn)
  }

  private static func generatedSearchValue(_ raw: TeaQLValue, kind: String) throws -> TeaQLValue {
    if raw == .null { return .null }
    switch kind {
    case "string", "boolean": return raw
    case "integer", "timestamp":
      let value = Int64(try generatedSearchNumber(raw))
      return kind == "timestamp" ? .timestamp(value) : .int(value)
    case "number": return .double(try generatedSearchNumber(raw))
    case "decimal":
      switch raw {
      case .decimal: return raw
      case .int(let value): return .decimal(Decimal(value))
      case .uint(let value): return .decimal(Decimal(value))
      case .double(let value): return .decimal(Decimal(value))
      case .string(let text):
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
          throw DynamicSearchError.invalid("Decimal is outside the native range")
        }
        return .decimal(value)
      default: break
      }
    case "date":
      if case .string(let text) = raw,
        let date = ISO8601DateFormatter().date(from: text + "T00:00:00Z") {
        return .date(date)
      }
    default: break
    }
    throw DynamicSearchError.invalid("Unsupported known-field value")
  }

  private static func generatedSearchNumber(_ raw: TeaQLValue) throws -> Double {
    switch raw {
    case .int(let value): return Double(value)
    case .uint(let value): return Double(value)
    case .double(let value): return value
    case .decimal(let value): return NSDecimalNumber(decimal: value).doubleValue
    default: throw DynamicSearchError.invalid("Invalid numeric value")
    }
  }
}
