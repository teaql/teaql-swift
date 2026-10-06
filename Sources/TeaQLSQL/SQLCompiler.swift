import Foundation
import TeaQLCore

/// Compiler-owned input before LIKE decoration, not an executable SQL binding.
package struct SQLIntentOperand: Sendable, Equatable {
  package let value: TeaQLValue
  package let policy: SQLParameterLogPolicy
}

public struct CompiledSQL: Sendable, Equatable {
  public let sql: String
  public let parameters: [TeaQLValue]
  public let parameterLogPolicies: [SQLParameterLogPolicy]
  public let generatedSQL: Bool
  package private(set) var intentOperands: [SQLIntentOperand] = []

  public init(sql: String, parameters: [TeaQLValue],
              parameterLogPolicies: [SQLParameterLogPolicy] = [], generatedSQL: Bool = false) {
    self.sql = sql
    self.parameters = parameters
    self.parameterLogPolicies = parameterLogPolicies
    self.generatedSQL = generatedSQL
  }

  fileprivate func retainingIntentOperands(_ operands: [SQLIntentOperand]) -> Self {
    var result = self
    result.intentOperands = operands
    return result
  }

  /// Explicit diagnostic utility; normal runtime logging first projects safe values.
  public func debugSQL() -> String {
    (try? SQLLogRenderer.render(sql, parameters: parameters)) ?? "[SQL OMITTED; NOT REPLAYABLE]"
  }
}

private struct SQLBindings {
  var values: [TeaQLValue] = []
  var policies: [SQLParameterLogPolicy] = []
  var policy: SQLParameterLogPolicy = .plain
  var intentOperands: [SQLIntentOperand] = []
  mutating func append(_ value: TeaQLValue) { values.append(value); policies.append(policy) }
  mutating func append(contentsOf values: [TeaQLValue]) { for value in values { append(value) } }
  mutating func appendLike(_ operand: String, prefix: String, suffix: String) {
    intentOperands.append(SQLIntentOperand(value: .string(operand), policy: policy))
    append(.string(prefix + operand + suffix))
  }
}

public struct SQLiteCompiler: Sendable {
  public init() {}

  public func compile(_ rawQuery: SelectQuery) throws -> CompiledSQL {
    let query = try rawQuery.validatedForExecution()
    let columns = try projection(query)
    var parameters = SQLBindings()
    var sql = "SELECT \(columns) FROM \(quote(query.entity.table))"
    if let filter = query.filter {
      sql += " WHERE " + (try expression(filter, entity: query.entity, parameters: &parameters))
    }
    if !query.groupBy.isEmpty {
      sql += " GROUP BY " + (try query.groupBy.map {
        quote(try requireProperty($0, in: query.entity).column)
      }.joined(separator: ", "))
    }
    if let partitionBy = query.partitionBy, let limit = query.limit {
      guard query.aggregates.isEmpty, query.groupBy.isEmpty else {
        throw TeaQLError.unsupportedQueryCapability(
          "Per-parent relation limits cannot be combined with aggregate/group queries")
      }
      let partitionColumn = quote(try requireProperty(partitionBy, in: query.entity).column)
      var orders = query.orderBy
      let idName = query.entity.idProperty?.name ?? "id"
      if !orders.contains(where: { $0.field == idName }) {
        orders.append(OrderBy(idName, .descending))
      }
      let windowOrder = try orders.map { item in
        let property = try requireProperty(item.field, in: query.entity)
        return "\(quote(property.column)) \(item.direction == .ascending ? "ASC" : "DESC")"
      }.joined(separator: ", ")
      let ranked = sql.replacingOccurrences(
        of: "SELECT \(columns)",
        with: "SELECT \(columns), ROW_NUMBER() OVER (PARTITION BY \(partitionColumn) ORDER BY \(windowOrder)) AS \(quote("__teaql_partition_rank"))",
        options: [.anchored])
      sql = "SELECT \(columns) FROM (\(ranked)) AS \(quote("__teaql_partitioned")) WHERE \(quote("__teaql_partition_rank")) > ? AND \(quote("__teaql_partition_rank")) <= ? ORDER BY \(quote("__teaql_partition_rank"))"
      parameters.append(.int(Int64(query.offset)))
      parameters.append(.int(Int64(query.offset + limit)))
      return CompiledSQL(sql: sql, parameters: parameters.values, parameterLogPolicies: parameters.policies, generatedSQL: true)
        .retainingIntentOperands(parameters.intentOperands)
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
    return CompiledSQL(sql: sql, parameters: parameters.values, parameterLogPolicies: parameters.policies, generatedSQL: true)
      .retainingIntentOperands(parameters.intentOperands)
  }

  public func compileCount(_ rawQuery: SelectQuery) throws -> CompiledSQL {
    let query = try rawQuery.validatedForExecution()
    var parameters = SQLBindings()
    var sql = "SELECT COUNT(*) FROM \(quote(query.entity.table))"
    if let filter = query.filter {
      sql += " WHERE " + (try expression(filter, entity: query.entity, parameters: &parameters))
    }
    return CompiledSQL(sql: sql, parameters: parameters.values, parameterLogPolicies: parameters.policies, generatedSQL: true)
      .retainingIntentOperands(parameters.intentOperands)
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
    if !query.aggregates.isEmpty || !query.groupBy.isEmpty {
      var items = try query.groupBy.map { field in
        let property = try requireProperty(field, in: query.entity)
        return "\(quote(property.column)) AS \(quote(property.name))"
      }
      for aggregate in query.aggregates {
        guard isSafeAlias(aggregate.alias) else {
          throw TeaQLError.execution("Invalid aggregate alias: \(aggregate.alias)")
        }
        let expression: String
        if aggregate.function == .count && aggregate.field == "*" {
          expression = "COUNT(*)"
        } else {
          let property = try requireProperty(aggregate.field, in: query.entity)
          expression = "\(aggregate.function.rawValue.uppercased())(\(quote(property.column)))"
        }
        items.append("\(expression) AS \(quote(aggregate.alias))")
      }
      guard !items.isEmpty else { throw TeaQLError.execution("Aggregate query has no result columns") }
      return items.joined(separator: ", ")
    }
    let selected = query.projection.isEmpty ? query.entity.properties.map(\.name) : query.projection
    return try selected.map { quote(try requireProperty($0, in: query.entity).column) }.joined(
      separator: ", ")
  }

  private func isSafeAlias(_ value: String) -> Bool {
    guard let first = value.unicodeScalars.first,
      CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first)
    else { return false }
    return value.unicodeScalars.dropFirst().allSatisfy {
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
    }
  }

  private func expression(
    _ expression: TeaQLExpression,
    entity: EntityDescriptor,
    parameters: inout SQLBindings
  ) throws -> String {
    let previous = parameters.policy
    defer { parameters.policy = previous }
    switch expression {
    case .equal(let field, _), .notEqual(let field, _),
         .greaterThan(let field, _), .greaterThanOrEqual(let field, _),
         .lessThan(let field, _), .lessThanOrEqual(let field, _),
         .between(let field, _, _), .contains(let field, _), .notContains(let field, _),
         .startsWith(let field, _), .notStartsWith(let field, _),
         .endsWith(let field, _), .notEndsWith(let field, _),
         .soundingLike(let field, _), .inList(let field, _), .notInList(let field, _):
      parameters.policy = .field(field, in: entity)
    default: parameters.policy = .unknown
    }
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
      parameters.appendLike(value, prefix: "%", suffix: "%")
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .notContains(let field, let value):
      parameters.appendLike(value, prefix: "%", suffix: "%")
      return "\(quote(try requireProperty(field, in: entity).column)) NOT LIKE ?"
    case .startsWith(let field, let value):
      parameters.appendLike(value, prefix: "", suffix: "%")
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .notStartsWith(let field, let value):
      parameters.appendLike(value, prefix: "", suffix: "%")
      return "\(quote(try requireProperty(field, in: entity).column)) NOT LIKE ?"
    case .endsWith(let field, let value):
      parameters.appendLike(value, prefix: "%", suffix: "")
      return "\(quote(try requireProperty(field, in: entity).column)) LIKE ?"
    case .notEndsWith(let field, let value):
      parameters.appendLike(value, prefix: "%", suffix: "")
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
    case .inSubquery(let field, let plan, let projectedField):
      return try subqueryExpression(
        field: field, plan: plan, projectedField: projectedField,
        operatorSQL: "IN", entity: entity, parameters: &parameters)
    case .notInSubquery(let field, let plan, let projectedField):
      return try subqueryExpression(
        field: field, plan: plan, projectedField: projectedField,
        operatorSQL: "NOT IN", entity: entity, parameters: &parameters)
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

  private func subqueryExpression(
    field: String,
    plan: RelationQueryPlan,
    projectedField: String,
    operatorSQL: String,
    entity: EntityDescriptor,
    parameters: inout SQLBindings
  ) throws -> String {
    let left = quote(try requireProperty(field, in: entity).column)
    let child = plan.makeQuery()
    let projection = quote(try requireProperty(projectedField, in: child.entity).column)
    var sql = "SELECT \(projection) FROM \(quote(child.entity.table))"
    var predicates: [String] = []
    if let filter = child.filter {
      predicates.append(try expression(filter, entity: child.entity, parameters: &parameters))
    }
    // SQL NOT IN is poisoned by one NULL in the projected set. Negative
    // relation matching ignores orphan keys; explicit isNull remains the way
    // to select those orphan rows.
    if operatorSQL == "NOT IN" {
      predicates.append("\(projection) IS NOT NULL")
    }
    if !predicates.isEmpty {
      sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
    }
    return "\(left) \(operatorSQL) (\(sql))"
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
