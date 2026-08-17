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
    var inString = false
    var index = sql.startIndex
    while index < sql.endIndex {
      let character = sql[index]
      if character == "'" {
        result.append(character)
        let next = sql.index(after: index)
        if inString, next < sql.endIndex, sql[next] == "'" {
          result.append("'")
          index = sql.index(after: next)
        } else {
          inString.toggle()
          index = next
        }
        continue
      }
      if character == "?", !inString, parameterIndex < parameters.count {
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

private func sqlLiteral(_ value: TeaQLValue) -> String {
  switch value {
  case .null: "NULL"
  case .bool(let value): value ? "TRUE" : "FALSE"
  case .int(let value): String(value)
  case .uint(let value): String(value)
  case .double(let value): String(value)
  case .decimal(let value): NSDecimalNumber(decimal: value).stringValue
  case .string(let value): quoteSQLString(value)
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
    case .greaterThanOrEqual(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) >= ?"
    case .lessThanOrEqual(let field, let value):
      parameters.append(value)
      return "\(quote(try requireProperty(field, in: entity).column)) <= ?"
    case .contains(let field, let value):
      parameters.append(.string("%\(value)%"))
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .inList(let field, let values):
      guard !values.isEmpty else { return "0 = 1" }
      parameters.append(contentsOf: values)
      return
        "\(quote(try requireProperty(field, in: entity).column)) IN (\(Array(repeating: "?", count: values.count).joined(separator: ", ")))"
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
    case .date, .timestamp: "TEXT"
    case .data: "BLOB"
    case .json: "TEXT"
    }
  }
}
