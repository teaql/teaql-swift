import Foundation
import TeaQLCore

public struct CompiledSQL: Sendable, Equatable {
  public let sql: String
  public let parameters: [TeaQLValue]

  public init(sql: String, parameters: [TeaQLValue]) {
    self.sql = sql
    self.parameters = parameters
  }

  /// Returns a diagnostic statement whose parameters are SQL literals, suitable for copy/paste.
  public func debugSQL() -> String {
    var result = ""
    var parameterIndex = 0
    var state = SQLScanState.sql
    var index = sql.startIndex
    while index < sql.endIndex {
      let character = sql[index]
      let nextIndex = sql.index(after: index)
      let next = nextIndex < sql.endIndex ? sql[nextIndex] : nil
      if state == .sql, character == "'" { result.append(character); state = .singleQuote }
      else if state == .sql, character == "\"" { result.append(character); state = .doubleQuote }
      else if state == .sql, character == "-", next == "-" {
        result += "--"; index = nextIndex; state = .lineComment
      } else if state == .sql, character == "/", next == "*" {
        result += "/*"; index = nextIndex; state = .blockComment
      } else if state == .singleQuote {
        result.append(character)
        if character == "'", next == "'" { result.append("'"); index = nextIndex }
        else if character == "'" { state = .sql }
      } else if state == .doubleQuote {
        result.append(character)
        if character == "\"", next == "\"" { result.append("\""); index = nextIndex }
        else if character == "\"" { state = .sql }
      } else if state == .lineComment {
        result.append(character)
        if character == "\n" || character == "\r" { state = .sql }
      } else if state == .blockComment {
        result.append(character)
        if character == "*", next == "/" { result.append("/"); index = nextIndex; state = .sql }
      } else if character == "?", parameterIndex < parameters.count {
        result += sqlLiteral(parameters[parameterIndex])
        parameterIndex += 1
      } else {
        result.append(character)
      }
      index = sql.index(after: index)
    }
    return result
  }
}

private enum SQLScanState { case sql, singleQuote, doubleQuote, lineComment, blockComment }

private func sqlLiteral(_ value: TeaQLValue) -> String {
  switch value {
  case .null: "NULL"
  case .bool(let value): value ? "TRUE" : "FALSE"
  case .int(let value): String(value)
  case .uint(let value): String(value)
  case .double(let value): String(value)
  case .decimal(let value): NSDecimalNumber(decimal: value).stringValue
  case .string(let value): quoteSQLString(value)
  case .calendarDate(let value): quoteSQLString(value)
  case .localDateTime(let value): quoteSQLString(value)
  case .timestamp(let value): String(value)
  case .date(let value): quoteSQLString(ISO8601DateFormatter().string(from: value))
  case .data(let value): "X'" + value.map { String(format: "%02x", $0) }.joined() + "'"
  case .array, .object:
    quoteSQLString(String(data: try! JSONEncoder().encode(value), encoding: .utf8)!)
  }
}

private func quoteSQLString(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
}

public struct SQLiteCompiler: Sendable {
  public init() {}

  public func compile(_ rawQuery: SelectQuery) throws -> CompiledSQL {
    let query = try rawQuery.validatedForExecution()
    let columns = try projection(query)
    var parameters: [TeaQLValue] = []
    var sql = "SELECT \(columns) FROM \(quote(query.entity.table))"
    if let filter = query.filter {
      sql += " WHERE " + (try expression(filter, entity: query.entity, parameters: &parameters))
    }
    if !query.orderBy.isEmpty {
      let orders = try query.orderBy.map { item in
        let property = try requireProperty(item.field, in: query.entity)
        return "\(quote(property.column)) \(item.direction == .ascending ? "ASC" : "DESC")"
      }
      sql += " ORDER BY " + orders.joined(separator: ", ")
    }
    let effectiveLimit = query.limit ?? query.hardLimit
    sql += " LIMIT ?"
    parameters.append(.int(Int64(effectiveLimit)))
    if query.offset > 0 {
      sql += " OFFSET ?"
      parameters.append(.int(Int64(query.offset)))
    }
    return CompiledSQL(sql: sql, parameters: parameters)
  }

  public func compileCount(_ rawQuery: SelectQuery) throws -> CompiledSQL {
    let query = try rawQuery.validatedForExecution()
    var parameters: [TeaQLValue] = []
    var sql = "SELECT COUNT(*) FROM \(quote(query.entity.table))"
    if let filter = query.filter {
      sql += " WHERE " + (try expression(filter, entity: query.entity, parameters: &parameters))
    }
    return CompiledSQL(sql: sql, parameters: parameters)
  }

  public func createTable(_ entity: EntityDescriptor) throws -> String {
    let columns = entity.properties.map { property in
      var result = "\(quote(property.column)) \(sqlType(property.type))"
      if property.isID { result += " PRIMARY KEY" }
      if !property.nullable { result += " NOT NULL" }
      return result
    }
    return "CREATE TABLE IF NOT EXISTS \(quote(entity.table)) (\(columns.joined(separator: ", ")))"
  }

  private func projection(_ query: SelectQuery) throws -> String {
    let selected = query.projection.isEmpty ? query.entity.properties.map(\.name) : query.projection
    return try selected.map { quote(try requireProperty($0, in: query.entity).column) }.joined(
      separator: ", ")
  }

  private func expression(
    _ expression: TeaQLExpression,
    entity: EntityDescriptor,
    parameters: inout [TeaQLValue]
  ) throws -> String {
    switch expression {
    case .equal(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) = ?"
    case .notEqual(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) <> ?"
    case .greaterThan(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) > ?"
    case .greaterThanOrEqual(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) >= ?"
    case .lessThan(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) < ?"
    case .lessThanOrEqual(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) <= ?"
    case .between(let field, let lower, let upper):
      parameters.append(lower)
      parameters.append(upper)
      return "\(quote(try requireProperty(field, in: entity).column)) BETWEEN ? AND ?"
    case .contains(let field, let value):
      parameters.append(.string("%\(value)%"))
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .notContains(let field, let value):
      parameters.append(.string("%\(value)%"))
      return "\(quote(try requireProperty(field, in: entity).column)) NOT LIKE ?"
    case .startsWith(let field, let value):
      parameters.append(.string("\(value)%"))
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .notStartsWith(let field, let value):
      parameters.append(.string("\(value)%"))
      return "\(quote(try requireProperty(field, in: entity).column)) NOT LIKE ?"
    case .endsWith(let field, let value):
      parameters.append(.string("%\(value)"))
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .notEndsWith(let field, let value):
      parameters.append(.string("%\(value)"))
      return "\(quote(try requireProperty(field, in: entity).column)) NOT LIKE ?"
    case .soundingLike(let field, let value):
      parameters.append(.string(value))
      return "SOUNDEX(\(quote(try requireProperty(field, in: entity).column))) = SOUNDEX(?)"
    case .inList(let field, let values):
      guard !values.isEmpty else { return "0 = 1" }
      parameters.append(contentsOf: values)
      return
        "\(quote(try requireProperty(field, in: entity).column)) IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))"
    case .notInList(let field, let values):
      guard !values.isEmpty else { return "1 = 1" }
      parameters.append(contentsOf: values)
      return
        "\(quote(try requireProperty(field, in: entity).column)) NOT IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))"
    case .isNull(let field):
      return "\(quote(try requireProperty(field, in: entity).column)) IS NULL"
    case .isNotNull(let field):
      return "\(quote(try requireProperty(field, in: entity).column)) IS NOT NULL"
    case .and(let items):
      return try items.map {
        "(" + (try self.expression($0, entity: entity, parameters: &parameters)) + ")"
      }.joined(separator: " AND ")
    case .or(let items):
      return try items.map {
        "(" + (try self.expression($0, entity: entity, parameters: &parameters)) + ")"
      }.joined(separator: " OR ")
    }
  }

  private func requireProperty(_ name: String, in entity: EntityDescriptor) throws
    -> PropertyDescriptor
  {
    guard let property = entity.property(named: name) else {
      throw TeaQLError.unknownProperty(entity: entity.name, property: name)
    }
    return property
  }

  private func quote(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  private func sqlType(_ type: PropertyType) -> String {
    switch type {
    case .bool, .int, .uint: "INTEGER"
    case .double: "REAL"
    case .decimal: "NUMERIC"
    case .string: "TEXT"
    case .date, .localDateTime: "TEXT"
    case .timestamp: "INTEGER"
    case .data: "BLOB"
    case .json: "TEXT"
    }
  }
}
