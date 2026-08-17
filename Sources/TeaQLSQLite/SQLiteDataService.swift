import CSQLite
import Dispatch
import Foundation
import TeaQLCore
import TeaQLSQL

public enum SQLiteError: Error, Sendable, Equatable, CustomStringConvertible {
  case open(String)
  case sqlite(code: Int32, message: String, sql: String?)
  case unsupportedValue(String)

  public var description: String {
    switch self {
    case .open(let message): "Unable to open SQLite database: \(message)"
    case .sqlite(let code, let message, let sql):
      "SQLite \(code): \(message)\(sql.map { " [\($0)]" } ?? "")"
    case .unsupportedValue(let value): "Unsupported SQLite value: \(value)"
    }
  }
}

public actor SQLiteDataService: QueryExecutor, MutationExecutor {
  private let handle: SQLiteHandle
  private var database: OpaquePointer { handle.pointer }
  private let compiler = SQLiteCompiler()
  public let path: String

  public init(path: String) throws {
    self.path = path
    let existed = FileManager.default.fileExists(atPath: path)
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let handle { sqlite3_close(handle) }
      throw SQLiteError.open(message)
    }
    self.handle = SQLiteHandle(handle)
    sqlite3_busy_timeout(handle, 5_000)
    if !existed { print("TeaQL SQLite: database not found; created \(path)") }
  }

  public func ensureSchema(_ entities: [EntityDescriptor]) throws {
    for entity in entities { try executeSQL(compiler.createTable(entity)) }
    try executeSQL(
      """
      CREATE TABLE IF NOT EXISTS teaql_row_audit_event (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          entity_type TEXT NOT NULL,
          entity_id TEXT,
          operation TEXT NOT NULL,
          reason TEXT NOT NULL,
          actor TEXT,
          occurred_at TEXT NOT NULL
      )
      """)
  }

  /// Explicitly creates/checks schema for a generated module.
  /// Installing the module into `TeaQLRuntime` never calls this operation.
  public func ensureSchema(_ module: RuntimeModule) throws {
    try ensureSchema(module.entities)
  }

  public func transaction(_ mutations: [Mutation]) async throws -> [MutationResult] {
    try executeSQL("BEGIN IMMEDIATE")
    do {
      var results: [MutationResult] = []
      for mutation in mutations {
        let validated = try mutation.validatedForExecution()
        let result = try performMutation(validated)
        try insertAudit(validated, generatedValues: result.generatedValues)
        results.append(result)
      }
      try executeSQL("COMMIT")
      return results
    } catch {
      try? executeSQL("ROLLBACK")
      throw error
    }
  }

  public func execute(_ query: SelectQuery) async throws -> QueryResult {
    let compiled = try compiler.compile(query)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let records = try fetch(compiled, entity: query.entity)
    return QueryResult(
      records: records,
      backend: "sqlite",
      trace: [
        TraceNode(entity: query.entity.name, comment: query.comment!, purpose: query.purpose!)
      ],
      metadata: SQLExecutionMetadata(
        operation: .select,
        parameterizedSQL: compiled.sql,
        parameters: compiled.parameters,
        debugSQL: compiled.debugSQL(),
        elapsedMicros: elapsedMicros(since: startedAt),
        resultCount: records.count,
        resultSummary: "Fetched \(records.count) rows")
    )
  }

  public func count(_ query: SelectQuery) async throws -> Int {
    let compiled = try compiler.compileCount(query)
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(database, compiled.sql, -1, &prepared, nil) == SQLITE_OK,
      let statement = prepared
    else {
      throw currentError(sql: compiled.sql)
    }
    defer { sqlite3_finalize(statement) }
    try bind(compiled.parameters, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw currentError(sql: compiled.sql)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  public func execute(_ mutation: Mutation) async throws -> MutationResult {
    let mutation = try mutation.validatedForExecution()
    try executeSQL("BEGIN IMMEDIATE")
    do {
      let result = try performMutation(mutation)
      try insertAudit(mutation, generatedValues: result.generatedValues)
      try executeSQL("COMMIT")
      return result
    } catch {
      try? executeSQL("ROLLBACK")
      throw error
    }
  }

  public func auditEvents() throws -> [TeaQLRecord] {
    let descriptor = EntityDescriptor(
      name: "TeaQLRowAuditEvent", table: "teaql_row_audit_event",
      properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true),
        PropertyDescriptor(name: "entityType", column: "entity_type", type: .string),
        PropertyDescriptor(name: "entityID", column: "entity_id", type: .string, nullable: true),
        PropertyDescriptor(name: "operation", type: .string),
        PropertyDescriptor(name: "reason", type: .string),
        PropertyDescriptor(name: "actor", type: .string, nullable: true),
        PropertyDescriptor(name: "occurredAt", column: "occurred_at", type: .timestamp),
      ])
    var query = SelectQuery(entity: descriptor)
    query.comment = "Inspect immutable TeaQL row audit events"
    query.purpose = "Verify mutation governance"
    query.orderBy = [OrderBy("id", .ascending)]
    return try fetch(compiler.compile(query), entity: descriptor)
  }

  private func performMutation(_ mutation: Mutation) throws -> MutationResult {
    switch mutation.kind {
    case .create: return try insert(mutation)
    case .update: return try update(mutation)
    case .delete: return try delete(mutation)
    case .recover:
      throw TeaQLError.execution("SQLite recover requires a generated soft-delete contract")
    }
  }

  private func insert(_ mutation: Mutation) throws -> MutationResult {
    var insertValues = mutation.values
    if let version = mutation.entity.versionProperty {
      insertValues[version.name] = .int(1)
    }
    let properties = try insertValues.keys.sorted().map {
      try requireProperty($0, mutation.entity)
    }
    guard !properties.isEmpty else { throw TeaQLError.execution("Insert values must not be empty") }
    let sql =
      "INSERT INTO \(quote(mutation.entity.table)) (\(properties.map { quote($0.column) }.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: properties.count).joined(separator: ", ")))"
    let values = properties.map { insertValues[$0.name] ?? .null }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    try run(sql, parameters: values)
    let affected = Int(sqlite3_changes(database))
    var generated: TeaQLRecord = [:]
    if let id = mutation.entity.idProperty, mutation.values[id.name] == nil {
      generated[id.name] = .int(sqlite3_last_insert_rowid(database))
    }
    return MutationResult(
      affectedRows: affected,
      generatedValues: generated,
      persistedRecord: try fetchPersistedRecord(
        entity: mutation.entity,
        id: generated[mutation.entity.idProperty?.name ?? "id"]
          ?? mutation.values[mutation.entity.idProperty?.name ?? "id"]
      ),
      metadata: SQLExecutionMetadata(
        operation: .insert,
        parameterizedSQL: sql,
        parameters: values,
        debugSQL: CompiledSQL(sql: sql, parameters: values).debugSQL(),
        elapsedMicros: elapsedMicros(since: startedAt),
        affectedRows: affected,
        resultSummary: "Affected \(affected) rows"))
  }

  private func update(_ mutation: Mutation) throws -> MutationResult {
    guard let id = mutation.id, let idProperty = mutation.entity.idProperty else {
      throw TeaQLError.execution("Update requires entity ID metadata and an ID value")
    }
    let versionProperty = mutation.entity.versionProperty
    let properties = try mutation.values.keys.sorted()
      .filter { $0 != idProperty.name && $0 != versionProperty?.name }
      .map { try requireProperty($0, mutation.entity) }
    var assignments = properties.map { "\(quote($0.column)) = ?" }
    var values = properties.map { mutation.values[$0.name] ?? .null }
    var whereSQL = "\(quote(idProperty.column)) = ?"
    values.append(id)
    if let versionProperty {
      guard let expected = mutation.expectedVersion else {
        throw TeaQLError.execution("Versioned update requires expectedVersion")
      }
      assignments.append("\(quote(versionProperty.column)) = \(quote(versionProperty.column)) + 1")
      whereSQL += " AND \(quote(versionProperty.column)) = ?"
      values.append(.int(expected))
    }
    guard !assignments.isEmpty else {
      throw TeaQLError.execution("Update values must not be empty")
    }
    let sql =
      "UPDATE \(quote(mutation.entity.table)) SET \(assignments.joined(separator: ", ")) WHERE \(whereSQL)"
    let startedAt = DispatchTime.now().uptimeNanoseconds
    try run(sql, parameters: values)
    let changed = Int(sqlite3_changes(database))
    if changed == 0, let expected = mutation.expectedVersion {
      throw TeaQLError.optimisticLock(
        entity: mutation.entity.name, id: id, expectedVersion: expected)
    }
    return MutationResult(
      affectedRows: changed,
      persistedRecord: try fetchPersistedRecord(entity: mutation.entity, id: id),
      metadata: SQLExecutionMetadata(
        operation: .update,
        parameterizedSQL: sql,
        parameters: values,
        debugSQL: CompiledSQL(sql: sql, parameters: values).debugSQL(),
        elapsedMicros: elapsedMicros(since: startedAt),
        affectedRows: changed,
        resultSummary: "Affected \(changed) rows"))
  }

  private func delete(_ mutation: Mutation) throws -> MutationResult {
    guard let id = mutation.id, let idProperty = mutation.entity.idProperty else {
      throw TeaQLError.execution("Delete requires entity ID metadata and an ID value")
    }
    guard let versionProperty = mutation.entity.versionProperty,
      let expected = mutation.expectedVersion
    else {
      throw TeaQLError.execution("Soft delete requires version metadata and expectedVersion")
    }
    let deletedVersion = -(expected + 1)
    let sql =
      "UPDATE \(quote(mutation.entity.table)) SET \(quote(versionProperty.column)) = ? WHERE \(quote(idProperty.column)) = ? AND \(quote(versionProperty.column)) = ?"
    let values: [TeaQLValue] = [.int(deletedVersion), id, .int(expected)]
    let startedAt = DispatchTime.now().uptimeNanoseconds
    try run(sql, parameters: values)
    let changed = Int(sqlite3_changes(database))
    if changed == 0 {
      throw TeaQLError.optimisticLock(
        entity: mutation.entity.name, id: id, expectedVersion: expected)
    }
    return MutationResult(
      affectedRows: changed,
      generatedValues: [versionProperty.name: .int(deletedVersion)],
      persistedRecord: try fetchPersistedRecord(entity: mutation.entity, id: id),
      metadata: SQLExecutionMetadata(
        operation: .delete,
        parameterizedSQL: sql,
        parameters: values,
        debugSQL: CompiledSQL(sql: sql, parameters: values).debugSQL(),
        elapsedMicros: elapsedMicros(since: startedAt),
        affectedRows: changed,
        resultSummary: "Affected \(changed) rows"))
  }

  private func insertAudit(_ mutation: Mutation, generatedValues: TeaQLRecord) throws {
    let id = mutation.id ?? generatedValues["id"]
    try run(
      "INSERT INTO teaql_row_audit_event (entity_type, entity_id, operation, reason, actor, occurred_at) VALUES (?, ?, ?, ?, ?, ?)",
      parameters: [
        .string(mutation.entity.name),
        id.map { .string(render($0)) } ?? .null,
        .string(mutation.kind.rawValue),
        .string(mutation.auditReason!),
        mutation.actor.map(TeaQLValue.string) ?? .null,
        .string(ISO8601DateFormatter().string(from: Date())),
      ]
    )
  }

  private func fetch(_ compiled: CompiledSQL, entity: EntityDescriptor) throws -> [TeaQLRecord] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, compiled.sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw currentError(sql: compiled.sql)
    }
    defer { sqlite3_finalize(statement) }
    try bind(compiled.parameters, to: statement)
    var records: [TeaQLRecord] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        var record: TeaQLRecord = [:]
        for index in 0..<sqlite3_column_count(statement) {
          let column = String(cString: sqlite3_column_name(statement, index))
          let property = entity.properties.first {
            $0.column.caseInsensitiveCompare(column) == .orderedSame
          }
          record[property?.name ?? column] = decode(statement, index: index, type: property?.type)
        }
        records.append(record)
      case SQLITE_DONE: return records
      default: throw currentError(sql: compiled.sql)
      }
    }
  }

  private func fetchPersistedRecord(
    entity: EntityDescriptor, id: TeaQLValue?
  ) throws -> TeaQLRecord {
    guard let id, let idProperty = entity.idProperty else {
      throw TeaQLError.execution(
        "Persisted state refresh requires entity ID metadata and an ID value")
    }
    let columns = entity.properties.map { quote($0.column) }.joined(separator: ", ")
    let compiled = CompiledSQL(
      sql: "SELECT \(columns) FROM \(quote(entity.table)) WHERE \(quote(idProperty.column)) = ?",
      parameters: [id]
    )
    guard let record = try fetch(compiled, entity: entity).first else {
      throw TeaQLError.execution(
        "Persisted state refresh found no \(entity.name) row for ID \(id)")
    }
    return record
  }

  private func executeSQL(_ sql: String) throws { try run(sql, parameters: []) }

  private func elapsedMicros(since startedAt: UInt64) -> UInt64 {
    (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000
  }

  private func run(_ sql: String, parameters: [TeaQLValue]) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw currentError(sql: sql)
    }
    defer { sqlite3_finalize(statement) }
    try bind(parameters, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError(sql: sql) }
  }

  private func bind(_ values: [TeaQLValue], to statement: OpaquePointer) throws {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .null: result = sqlite3_bind_null(statement, index)
      case .bool(let value): result = sqlite3_bind_int(statement, index, value ? 1 : 0)
      case .int(let value): result = sqlite3_bind_int64(statement, index, value)
      case .uint(let value) where value <= UInt64(Int64.max):
        result = sqlite3_bind_int64(statement, index, Int64(value))
      case .double(let value): result = sqlite3_bind_double(statement, index, value)
      case .decimal(let value): result = bindText(String(describing: value), statement, index)
      case .string(let value): result = bindText(value, statement, index)
      case .date(let value):
        result = bindText(ISO8601DateFormatter().string(from: value), statement, index)
      case .data(let value):
        result = value.withUnsafeBytes { bytes in
          sqlite3_bind_blob(
            statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
      case .array, .object:
        result = bindText(
          String(data: try JSONEncoder().encode(value), encoding: .utf8)!, statement, index)
      default: throw SQLiteError.unsupportedValue(render(value))
      }
      guard result == SQLITE_OK else { throw currentError(sql: nil) }
    }
  }

  private func bindText(_ value: String, _ statement: OpaquePointer, _ index: Int32) -> Int32 {
    value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
  }

  private func decode(_ statement: OpaquePointer, index: Int32, type: PropertyType?) -> TeaQLValue {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_NULL: return .null
    case SQLITE_INTEGER:
      let value = sqlite3_column_int64(statement, index)
      return type == .bool ? .bool(value != 0) : .int(value)
    case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, index))
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, index))
      guard let bytes = sqlite3_column_blob(statement, index) else { return .data(Data()) }
      return .data(Data(bytes: bytes, count: count))
    default:
      let text = String(cString: sqlite3_column_text(statement, index))
      if type == .decimal, let decimal = Decimal(string: text) { return .decimal(decimal) }
      if type == .date || type == .timestamp {
        if let date = ISO8601DateFormatter().date(from: text) { return .date(date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = type == .date ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        if let date = formatter.date(from: text) { return .date(date) }
      }
      return .string(text)
    }
  }

  private func currentError(sql: String?) -> SQLiteError {
    .sqlite(
      code: sqlite3_errcode(database), message: String(cString: sqlite3_errmsg(database)), sql: sql)
  }

  private func requireProperty(_ name: String, _ entity: EntityDescriptor) throws
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

  private func render(_ value: TeaQLValue) -> String {
    switch value {
    case .null: "null"
    case .bool(let value): String(value)
    case .int(let value): String(value)
    case .uint(let value): String(value)
    case .double(let value): String(value)
    case .decimal(let value): String(describing: value)
    case .string(let value): value
    case .date(let value): ISO8601DateFormatter().string(from: value)
    case .data: "<data>"
    case .array: "<array>"
    case .object: "<object>"
    }
  }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { sqlite3_close(pointer) }
}
