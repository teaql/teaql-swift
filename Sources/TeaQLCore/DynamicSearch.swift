import Foundation

/// Application-owned local UI-search metadata, never client-supplied policy.
public struct SearchModel: Sendable {
  public let fields: [String: String]
  public let relations: [String: String]
  public init(fields: [String: String], relations: [String: String] = [:]) {
    self.fields = fields
    self.relations = relations
  }
}

public struct DynamicSearchWarning: Sendable, Equatable, Codable {
  public let code: String
  public let entity: String
  public let clause: String
  public let fieldPath: String
  init(entity: String, clause: String, fieldPath: String) {
    code = "DYNAMIC_SEARCH_UNKNOWN_FIELD"
    self.entity = entity
    self.clause = clause
    self.fieldPath = fieldPath
  }

  func defaultLogProjection() -> DynamicSearchWarning {
    DynamicSearchWarning(entity: entity, clause: clause, fieldPath: "<omitted>")
  }
}

public struct DynamicSearchFilter: Sendable {
  public let fieldPath: String
  public let operation: String
  public let value: TeaQLValue
}

public struct DynamicSearchOrder: Sendable {
  public let fieldPath: String
  public let direction: SortDirection
}

public struct NormalizedDynamicSearch: Sendable {
  public let filters: [DynamicSearchFilter]
  public let orders: [DynamicSearchOrder]
  public let warnings: [DynamicSearchWarning]
}

public struct DynamicSearchResult: Sendable {
  public let query: SelectQuery
  public let warnings: [DynamicSearchWarning]
}

public enum DynamicSearchError: Error, Equatable {
  case invalid(String)
}

/// Local schema-drift tolerance. Federation validation is deliberately unchanged.
public enum DynamicSearch {
  private static let operations: Set<String> = [
    "$eq", "$ne", "$gt", "$gte", "$lt", "$lte", "$in", "$notIn", "$contains"
  ]

  public static func normalize(
    _ source: String, entity: String, models: [String: SearchModel],
    maxClauses: Int = 100, warn: ((DynamicSearchWarning) -> Void)? = nil
  ) throws -> NormalizedDynamicSearch {
    guard maxClauses > 0, models[entity] != nil else { throw invalid("Invalid trusted search setup") }
    let decoded: TeaQLValue
    do { decoded = try JSONDecoder().decode(TeaQLValue.self, from: Data(source.utf8)) }
    catch { throw invalid("Dynamic search requires valid JSON") }
    guard case .object(let root) = decoded, Set(root.keys).isSubset(of: ["filter", "orderBy"]) else {
      throw invalid("Unsupported dynamic search input or control")
    }
    guard case .object(let filters) = root["filter"] ?? .object([:]),
      case .array(let orders) = root["orderBy"] ?? .array([]) else {
      throw invalid("Invalid search filter or ordering")
    }
    guard filters.count + orders.count <= maxClauses else { throw invalid("Dynamic search exceeds clause limit") }
    var resultFilters: [DynamicSearchFilter] = []
    var resultOrders: [DynamicSearchOrder] = []
    var warnings: [DynamicSearchWarning] = []
    for path in filters.keys.sorted() {
      let predicate = filters[path]!
      var operation = "$eq"
      var value = predicate
      if case .object(let parts) = predicate {
        guard parts.count == 1, let part = parts.first, operations.contains(part.key) else {
          throw invalid("Unsupported or malformed dynamic search operator")
        }
        operation = part.key
        value = part.value
      }
      if operation == "$in" || operation == "$notIn" {
        guard case .array(let items) = value, items.count <= 1000 else {
          throw invalid("Invalid or oversized search value list")
        }
      }
      guard let kind = try fieldType(path, entity: entity, models: models) else {
        warnings.append(.init(entity: entity, clause: "FILTER", fieldPath: path))
        continue
      }
      if operation == "$contains", kind != "string" { throw invalid("String operator requires a string field") }
      if case .array(let values) = value {
        guard operation == "$in" || operation == "$notIn" else { throw invalid("Unexpected search value list") }
        for item in values { try validate(item, kind: kind) }
      } else { try validate(value, kind: kind) }
      resultFilters.append(.init(fieldPath: path, operation: operation, value: value))
    }
    for order in orders {
      guard case .object(let object) = order, Set(object.keys) == ["field", "direction"],
        case .string(let path) = object["field"], case .string(let direction) = object["direction"],
        direction == "asc" || direction == "desc" else { throw invalid("Invalid dynamic search ordering") }
      if try fieldType(path, entity: entity, models: models) == nil {
        warnings.append(.init(entity: entity, clause: "ORDER_BY", fieldPath: path))
      } else {
        resultOrders.append(.init(fieldPath: path, direction: direction == "asc" ? .ascending : .descending))
      }
    }
    emit(warnings, warn: warn)
    return .init(filters: resultFilters, orders: resultOrders, warnings: warnings)
  }

  /// Bindings are trusted native adapters and must retain related-query authorization.
  public static func merge(
    _ base: SelectQuery, source: String, models: [String: SearchModel],
    filterBinding: (DynamicSearchFilter) throws -> TeaQLExpression,
    orderBinding: (DynamicSearchOrder) throws -> OrderBy,
    warn: ((DynamicSearchWarning) -> Void)? = nil
  ) throws -> DynamicSearchResult {
    let search = try normalize(source, entity: base.entity.name, models: models, warn: { _ in })
    let filters = try search.filters.map(filterBinding)
    let orders = try search.orders.map(orderBinding)
    var query = base
    for filter in filters { query.filter = query.filter.map { .and([$0, filter]) } ?? filter }
    query.orderBy.append(contentsOf: orders)
    emit(search.warnings, warn: warn)
    return .init(query: query, warnings: search.warnings)
  }

  private static func fieldType(_ path: String, entity: String, models: [String: SearchModel]) throws -> String? {
    let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count <= 16, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("$")
      && !["__proto__", "prototype", "constructor"].contains($0) }) else { throw invalid("Invalid search field path") }
    var model = models[entity]!
    for part in parts.dropLast() {
      guard let target = model.relations[part] else { return nil }
      guard let related = models[target] else { throw invalid("Invalid trusted search relation metadata") }
      model = related
    }
    return model.fields[parts.last!]
  }

  private static func validate(_ value: TeaQLValue, kind: String) throws {
    if value == .null { return }
    let number: Double?
    switch value {
    case .int(let n): number = Double(n)
    case .uint(let n): number = Double(n)
    case .double(let n): number = n.isFinite ? n : nil
    case .decimal(let n):
      let double = NSDecimalNumber(decimal: n).doubleValue
      number = double.isFinite ? double : nil
    default: number = nil
    }
    let valid: Bool
    switch kind {
    case "integer", "timestamp": valid = number.map { abs($0) <= 9007199254740991 && $0.rounded(.towardZero) == $0 } ?? false
    case "number": valid = number != nil
    case "string": if case .string = value { valid = true } else { valid = false }
    case "boolean": if case .bool = value { valid = true } else { valid = false }
    case "decimal":
      if case .string(let text) = value {
        valid = text.range(of: #"\A[+-]?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil
      } else { valid = number != nil }
    case "date":
      if case .string(let text) = value { valid = validDate(text) } else { valid = false }
    default: valid = false
    }
    guard valid else { throw invalid("Invalid value for known search field") }
  }

  private static func validDate(_ text: String) -> Bool {
    guard text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil else { return false }
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, parts[0] >= 1, (1...12).contains(parts[1]) else { return false }
    let leap = parts[0] % 4 == 0 && (parts[0] % 100 != 0 || parts[0] % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    return (1...days[parts[1] - 1]).contains(parts[2])
  }

  private static func invalid(_ message: String) -> DynamicSearchError { .invalid(message) }
  private static func emit(_ warnings: [DynamicSearchWarning], warn: ((DynamicSearchWarning) -> Void)?) {
    for warning in warnings {
      if let warn { warn(warning) }
      else if var data = try? JSONEncoder().encode(warning.defaultLogProjection()) {
        data.append(10)
        FileHandle.standardError.write(data)
      }
    }
  }
}
