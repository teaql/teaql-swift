import CSQLite
import Dispatch
import Foundation
import TeaQLCore
import TeaQLSQL

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func sqliteCompatibleSoundex(_ input: String?) -> String {
  guard let input else { return "?000" }
  let letters = input.uppercased().utf8.filter { $0 >= 65 && $0 <= 90 }
  guard let first = letters.first else { return "?000" }
  func code(_ byte: UInt8) -> UInt8 {
    switch byte {
    case 66, 70, 80, 86: 1
    case 67, 71, 74, 75, 81, 83, 88, 90: 2
    case 68, 84: 3
    case 76: 4
    case 77, 78: 5
    case 82: 6
    default: 0
    }
  }
  var bytes: [UInt8] = [first]
  var previous = code(first)
  for letter in letters.dropFirst() {
    let current = code(letter)
    if current != 0 && current != previous { bytes.append(48 + current) }
    if bytes.count == 4 { break }
    previous = current
  }
  while bytes.count < 4 { bytes.append(48) }
  return String(decoding: bytes, as: UTF8.self)
}

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

public actor SQLiteDataService: QueryExecutor, MutationExecutor, GraphTransactionExecutor, SchemaExecutor, RelationTopNPlanning, SQLDiagnosticExecutor, SQLCountDiagnosticExecutor, QueryIntentProvenanceExecutor {
  private let handle: SQLiteHandle
  private var database: OpaquePointer { handle.pointer }
  private let compiler = SQLiteCompiler()
  private var graphTransactionActive = false
  public let path: String
  public nonisolated var idSetDataSourceIdentity: String { "sqlite:\(path)" }
  public nonisolated var relationTopNPolicy: RelationTopNPolicy { .alwaysProbe }

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

  private func ensureEntitySchemas(_ entities: [EntityDescriptor]) throws {
    for entity in entities {
      try executeSQL(compiler.createTable(entity))
      let idColumn = entity.properties.first(where: { $0.isID })?.column ?? "id"
      for property in entity.properties
      where property.name.hasSuffix("Id") || property.name.hasSuffix("_id") {
        let index = "idx_\(entity.table)_\(property.column)_id_desc"
        try executeSQL("CREATE INDEX IF NOT EXISTS \(quote(index)) ON \(quote(entity.table)) (\(quote(property.column)), \(quote(idColumn)) DESC)")
      }
    }
    try executeSQL(
      """
      CREATE TABLE IF NOT EXISTS teaql_row_audit_event (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          entity_type TEXT NOT NULL,
          entity_id TEXT,
          operation TEXT NOT NULL,
          reason TEXT NOT NULL,
          actor TEXT,
          category TEXT,
          occurred_at TEXT NOT NULL
      )
      """)
    if try scalarInt64(
      "SELECT COUNT(*) FROM pragma_table_info('teaql_row_audit_event') WHERE name = 'category'",
      parameters: []) == 0
    {
      try executeSQL("ALTER TABLE teaql_row_audit_event ADD COLUMN category TEXT")
    }
    try executeSQL(
      """
      CREATE TABLE IF NOT EXISTS teaql_id_space (
          type_name TEXT NOT NULL PRIMARY KEY,
          current_level INTEGER NOT NULL
      )
      """)
  }

  /// Provider SPI. Application code calls `context.ensureSchema(module)`.
  package func ensureSchema(_ module: RuntimeModule, context: UserContext) throws {
    try ensureSoundexFunction()
    try ensureEntitySchemas(module.entities)
  }

  private func ensureSoundexFunction() throws {
    let status = sqlite3_create_function_v2(
      database, "soundex", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
      { context, count, values in
        guard let context, count == 1, let values, let value = values[0] else { return }
        let input = sqlite3_value_type(value) == SQLITE_NULL
          ? nil : sqlite3_value_text(value).map { String(cString: $0) }
        let encoded = sqliteCompatibleSoundex(input)
        encoded.withCString { sqlite3_result_text(context, $0, -1, sqliteTransient) }
      }, nil, nil, nil)
    guard status == SQLITE_OK else {
      throw SQLiteError.sqlite(code: status, message: String(cString: sqlite3_errmsg(database)), sql: nil)
    }
  }

  /// Advances an ID space after model-defined roots or constants are seeded.
  /// The floor is monotonic and is never allowed to move backwards.
  public func ensureIDFloor(typeName: String, floor: Int64) throws {
    guard floor >= 0 else {
      throw TeaQLError.execution("Invalid ID space floor \(floor) for \(typeName)")
    }
    if graphTransactionActive {
      try ensureIDFloorInCurrentTransaction(typeName: typeName, floor: floor)
      return
    }
    try executeSQL("BEGIN IMMEDIATE")
    do {
      try ensureIDFloorInCurrentTransaction(typeName: typeName, floor: floor)
      try executeSQL("COMMIT")
    } catch {
      try? executeSQL("ROLLBACK")
      throw error
    }
  }

  private func ensureIDFloorInCurrentTransaction(typeName: String, floor: Int64) throws {
    try executeSQL(
      "CREATE TABLE IF NOT EXISTS teaql_id_space (type_name TEXT NOT NULL PRIMARY KEY, current_level INTEGER NOT NULL)")
    for attempt in 1...100 {
      if let current = try scalarInt64(
        "SELECT current_level FROM teaql_id_space WHERE type_name = ?",
        parameters: [.string(typeName)])
      {
        if current >= floor { return }
        try run(
          "UPDATE teaql_id_space SET current_level = ? WHERE type_name = ? AND current_level = ?",
          parameters: [.int(floor), .string(typeName), .int(current)])
        if sqlite3_changes(database) == 1 { return }
      } else {
        do {
          try run(
            "INSERT INTO teaql_id_space(type_name, current_level) VALUES (?, ?)",
            parameters: [.string(typeName), .int(floor)])
          if sqlite3_changes(database) == 1 { return }
        } catch {
          if try scalarInt64(
            "SELECT current_level FROM teaql_id_space WHERE type_name = ?",
            parameters: [.string(typeName)]) == nil { throw error }
        }
      }
      if attempt == 100 {
        throw TeaQLError.execution(
          "Unable to synchronize ID space floor for \(typeName) after 100 optimistic-lock attempts")
      }
    }
  }

  public func execute(_ request: QueryRequest) async throws -> QueryResult {
    do { return try await executeDiagnosed(request) }
    catch let failure as SQLExecutionFailure { throw failure.cause }
  }

  package func queryIntentProvenance(_ request: QueryRequest) throws -> SQLExecutionMetadata {
    let compiled = try compiler.compile(request.query)
    return SQLExecutionMetadata(operation: .select, parameterizedSQL: compiled.sql,
      parameters: compiled.parameters, debugSQL: "", elapsedMicros: 0, resultSummary: "",
      parameterLogPolicies: compiled.parameterLogPolicies, generatedSQL: compiled.generatedSQL)
  }

  package func executeDiagnosed(_ request: QueryRequest) async throws -> QueryResult {
    let query = request.query
    let compiled = try compiler.compile(query)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let records: [TeaQLRecord]
    do { records = try fetch(compiled, entity: query.entity) }
    catch {
      throw SQLExecutionFailure(cause: error, metadata: SQLExecutionMetadata(
        operation: .select, comment: query.comment, purpose: query.purpose,
        tracePath: querySQLTrace(request),
        parameterizedSQL: compiled.sql, parameters: compiled.parameters, debugSQL: "",
        elapsedMicros: elapsedMicros(since: startedAt), resultSummary: "statement failed; row count unknown",
        parameterLogPolicies: compiled.parameterLogPolicies, generatedSQL: compiled.generatedSQL,
        executionOutcome: "failure"))
    }
    return QueryResult(
      records: records,
      backend: "sqlite",
      trace: [
        TraceNode(entity: request.originEntity, comment: request.intent.comment, purpose: request.intent.purpose)
      ],
      metadata: SQLExecutionMetadata(
        operation: .select,
        comment: query.comment,
        purpose: query.purpose,
        tracePath: querySQLTrace(request),
        parameterizedSQL: compiled.sql,
        parameters: compiled.parameters,
        debugSQL: "",
        elapsedMicros: elapsedMicros(since: startedAt),
        resultCount: records.count,
        resultSummary: "\(records.count) rows returned",
        parameterLogPolicies: compiled.parameterLogPolicies,
        generatedSQL: compiled.generatedSQL, executionOutcome: "success")
    )
  }

  public func count(_ request: QueryRequest) async throws -> Int {
    do { return try await countDiagnosed(request).count }
    catch let failure as SQLExecutionFailure { throw failure.cause }
  }

  package func countDiagnosed(_ request: QueryRequest) async throws -> SQLCountResult {
    let query = request.query
    let compiled = try compiler.compileCount(query)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    func metadata(count: Int? = nil) -> SQLExecutionMetadata {
      SQLExecutionMetadata(operation: .select, comment: query.comment, purpose: query.purpose,
        tracePath: querySQLTrace(request), parameterizedSQL: compiled.sql,
        parameters: compiled.parameters, debugSQL: "", elapsedMicros: elapsedMicros(since: startedAt),
        resultCount: count == nil ? nil : 1,
        resultSummary: count.map { "\($0) records counted" } ?? "statement failed; count unknown",
        parameterLogPolicies: compiled.parameterLogPolicies, generatedSQL: compiled.generatedSQL,
        executionOutcome: count == nil ? "failure" : "success")
    }
    do {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(database, compiled.sql, -1, &prepared, nil) == SQLITE_OK,
        let statement = prepared
      else { throw currentError(sql: compiled.sql) }
      defer { sqlite3_finalize(statement) }
      try bind(compiled.parameters, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw currentError(sql: compiled.sql) }
      let count = Int(sqlite3_column_int64(statement, 0))
      return SQLCountResult(count: count, metadata: metadata(count: count))
    } catch {
      throw SQLExecutionFailure(cause: error, metadata: metadata())
    }
  }

  public func execute(_ request: MutationRequest) async throws -> MutationResult {
    do { return try await executeDiagnosed(request) }
    catch let failure as SQLExecutionFailure { throw failure.cause }
  }

  package func executeDiagnosed(_ request: MutationRequest) async throws -> MutationResult {
    let mutation = request.mutation
    if graphTransactionActive {
      let result = try performMutation(mutation)
      if result.affectedRows > 0 { try insertAudit(mutation, generatedValues: result.generatedValues) }
      return result
    }
    try executeSQL("BEGIN IMMEDIATE")
    do {
      let result = try performMutation(mutation)
      if result.affectedRows > 0 { try insertAudit(mutation, generatedValues: result.generatedValues) }
      try executeSQL("COMMIT")
      return result
    } catch {
      try? executeSQL("ROLLBACK")
      throw error
    }
  }

  public func beginGraphTransaction() async throws {
    guard !graphTransactionActive else {
      throw TeaQLError.execution("A graph transaction is already active")
    }
    try executeSQL("BEGIN IMMEDIATE")
    graphTransactionActive = true
  }

  public func commitGraphTransaction() async throws {
    guard graphTransactionActive else { throw TeaQLError.execution("No graph transaction is active") }
    try executeSQL("COMMIT")
    graphTransactionActive = false
  }

  public func rollbackGraphTransaction() async throws {
    guard graphTransactionActive else { throw TeaQLError.execution("No graph transaction is active") }
    defer { graphTransactionActive = false }
    try executeSQL("ROLLBACK")
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
        PropertyDescriptor(name: "category", type: .string, nullable: true),
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

  private func mutationFailure(_ error: any Error, mutation: Mutation, operation: SQLExecutionOperation,
    sql: String, values: [TeaQLValue], policies: [SQLParameterLogPolicy], startedAt: UInt64,
    affectedRows: Int? = nil, executionOutcome: String = "failure") -> SQLExecutionFailure {
    SQLExecutionFailure(cause: error, metadata: SQLExecutionMetadata(
      operation: operation, auditReason: mutation.auditReason,
      tracePath: mutationSQLTrace(mutation, operation: operation.rawValue),
      mutationLineage: mutation.mutationLineage ?? [],
      parameterizedSQL: sql, parameters: values, debugSQL: "", elapsedMicros: elapsedMicros(since: startedAt),
      affectedRows: affectedRows,
      resultSummary: affectedRows.map { "\($0) rows affected" } ?? "statement failed; row count unknown",
      parameterLogPolicies: policies, generatedSQL: true, executionOutcome: executionOutcome))
  }

  private func insert(_ mutation: Mutation) throws -> MutationResult {
    var mutation = mutation
    var insertValues = try normalizedValues(mutation.values, for: mutation.entity)
    if let id = mutation.entity.idProperty {
      if insertValues[id.name] == nil {
        insertValues[id.name] = .int(try allocateID(typeName: mutation.entity.name))
      } else if case .int(let explicitID) = insertValues[id.name] {
        try ensureIDFloorInCurrentTransaction(typeName: mutation.entity.name, floor: explicitID)
      }
    }
    if let version = mutation.entity.versionProperty {
      insertValues[version.name] = .int(1)
    }
    if let id = mutation.entity.idProperty.flatMap({ insertValues[$0.name] }) {
      mutation.id = id
      mutation.mutationLineage = TraceChain.assignedLineage(mutation.mutationLineage ?? [],
        key: EntityKey(entity: mutation.entity.name, id: id))
    }
    let properties = try insertValues.keys.sorted().map {
      try requireProperty($0, mutation.entity)
    }
    guard !properties.isEmpty else { throw TeaQLError.execution("Insert values must not be empty") }
    let sql =
      "INSERT INTO \(quote(mutation.entity.table)) (\(properties.map { quote($0.column) }.joined(separator: ", "))) VALUES (\(Array(repeating: "?", count: properties.count).joined(separator: ", ")))"
    let values = properties.map { insertValues[$0.name] ?? .null }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    do { try run(sql, parameters: values) }
    catch {
      throw mutationFailure(error, mutation: mutation, operation: .insert, sql: sql, values: values,
        policies: properties.map { .field($0.name, in: mutation.entity) }, startedAt: startedAt)
    }
    let affected = Int(sqlite3_changes(database))
    var generated: TeaQLRecord = [:]
    if let id = mutation.entity.idProperty, mutation.values[id.name] == nil {
      generated[id.name] = insertValues[id.name]
    }
    let metadata = SQLExecutionMetadata(
        operation: .insert,
        auditReason: mutation.auditReason,
        tracePath: mutationSQLTrace(mutation, operation: "insert"),
        mutationLineage: mutation.mutationLineage ?? [],
        parameterizedSQL: sql,
        parameters: values,
        debugSQL: "",
        elapsedMicros: elapsedMicros(since: startedAt),
        affectedRows: affected,
        resultSummary: "\(affected) rows affected",
        parameterLogPolicies: properties.map { .field($0.name, in: mutation.entity) }, generatedSQL: true, executionOutcome: "success")
    let (record, read) = try fetchPersistedRecord(entity: mutation.entity,
        id: generated[mutation.entity.idProperty?.name ?? "id"]
          ?? mutation.values[mutation.entity.idProperty?.name ?? "id"], write: metadata)
    return MutationResult(affectedRows: affected, generatedValues: generated,
      persistedRecord: record, metadata: metadata.includingStatements([metadata, read]))
  }

  private func allocateID(typeName: String) throws -> Int64 {
    for attempt in 1...100 {
      if let current = try scalarInt64(
        "SELECT current_level FROM teaql_id_space WHERE type_name = ?",
        parameters: [.string(typeName)])
      {
        guard current < Int64.max else {
          throw TeaQLError.execution("ID space overflow for \(typeName)")
        }
        let next = current + 1
        try run(
          "UPDATE teaql_id_space SET current_level = ? WHERE type_name = ? AND current_level = ?",
          parameters: [.int(next), .string(typeName), .int(current)])
        let changed = Int(sqlite3_changes(database))
        if changed == 1 { return next }
        if changed != 0 {
          throw TeaQLError.execution(
            "ID space update for \(typeName) changed \(changed) rows on attempt \(attempt)")
        }
        continue
      }
      do {
        try run(
          "INSERT INTO teaql_id_space(type_name, current_level) VALUES (?, 1)",
          parameters: [.string(typeName)])
        if sqlite3_changes(database) == 1 { return 1 }
      } catch {
        if try scalarInt64(
          "SELECT current_level FROM teaql_id_space WHERE type_name = ?",
          parameters: [.string(typeName)]) == nil
        {
          throw error
        }
      }
    }
    throw TeaQLError.execution(
      "Unable to allocate ID for \(typeName) after 100 optimistic-lock attempts")
  }

  private func update(_ mutation: Mutation) throws -> MutationResult {
    guard let id = mutation.id, let idProperty = mutation.entity.idProperty else {
      throw TeaQLError.execution("Update requires entity ID metadata and an ID value")
    }
    let versionProperty = mutation.entity.versionProperty
    let normalized = try normalizedValues(mutation.values, for: mutation.entity)
    let properties = try normalized.keys.sorted()
      .filter { $0 != idProperty.name && $0 != versionProperty?.name }
      .map { try requireProperty($0, mutation.entity) }
    var assignments = properties.map { "\(quote($0.column)) = ?" }
    var values = properties.map { normalized[$0.name] ?? .null }
    var policies = properties.map { SQLParameterLogPolicy.field($0.name, in: mutation.entity) }
    var whereSQL = "\(quote(idProperty.column)) = ?"
    values.append(id)
    policies.append(.field(idProperty.name, in: mutation.entity))
    if let versionProperty {
      guard let expected = mutation.expectedVersion else {
        throw TeaQLError.execution("Versioned update requires expectedVersion")
      }
      assignments.append("\(quote(versionProperty.column)) = \(quote(versionProperty.column)) + 1")
      whereSQL += " AND \(quote(versionProperty.column)) = ?"
      values.append(.int(expected))
      policies.append(.field(versionProperty.name, in: mutation.entity))
    }
    guard !assignments.isEmpty else {
      throw TeaQLError.execution("Update values must not be empty")
    }
    let sql =
      "UPDATE \(quote(mutation.entity.table)) SET \(assignments.joined(separator: ", ")) WHERE \(whereSQL)"
    let startedAt = DispatchTime.now().uptimeNanoseconds
    do { try run(sql, parameters: values) }
    catch {
      throw mutationFailure(error, mutation: mutation, operation: .update, sql: sql, values: values,
        policies: policies, startedAt: startedAt)
    }
    let changed = Int(sqlite3_changes(database))
    if changed == 0, let expected = mutation.expectedVersion {
      throw mutationFailure(TeaQLError.optimisticLock(entity: mutation.entity.name, id: id, expectedVersion: expected),
        mutation: mutation, operation: .update, sql: sql, values: values, policies: policies,
        startedAt: startedAt, affectedRows: 0, executionOutcome: "success")
    }
    let metadata = SQLExecutionMetadata(
        operation: .update,
        auditReason: mutation.auditReason,
        tracePath: mutationSQLTrace(mutation, operation: "update"),
        mutationLineage: mutation.mutationLineage ?? [],
        parameterizedSQL: sql,
        parameters: values,
        debugSQL: "",
        elapsedMicros: elapsedMicros(since: startedAt),
        affectedRows: changed,
        resultSummary: "\(changed) rows affected", parameterLogPolicies: policies, generatedSQL: true, executionOutcome: "success")
    guard changed > 0 else { return MutationResult(affectedRows: changed, metadata: metadata) }
    let (record, read) = try fetchPersistedRecord(entity: mutation.entity, id: id, write: metadata)
    return MutationResult(affectedRows: changed, persistedRecord: record,
      metadata: metadata.includingStatements([metadata, read]))
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
    let policies: [SQLParameterLogPolicy] = [.field(versionProperty.name, in: mutation.entity),
      .field(idProperty.name, in: mutation.entity), .field(versionProperty.name, in: mutation.entity)]
    let startedAt = DispatchTime.now().uptimeNanoseconds
    do { try run(sql, parameters: values) }
    catch {
      throw mutationFailure(error, mutation: mutation, operation: .delete, sql: sql, values: values,
        policies: policies, startedAt: startedAt)
    }
    let changed = Int(sqlite3_changes(database))
    if changed == 0 {
      throw mutationFailure(TeaQLError.optimisticLock(entity: mutation.entity.name, id: id, expectedVersion: expected),
        mutation: mutation, operation: .delete, sql: sql, values: values, policies: policies,
        startedAt: startedAt, affectedRows: 0, executionOutcome: "success")
    }
    let metadata = SQLExecutionMetadata(
        operation: .delete,
        auditReason: mutation.auditReason,
        tracePath: mutationSQLTrace(mutation, operation: "delete"),
        mutationLineage: mutation.mutationLineage ?? [],
        parameterizedSQL: sql,
        parameters: values,
        debugSQL: "",
        elapsedMicros: elapsedMicros(since: startedAt),
        affectedRows: changed,
        resultSummary: "\(changed) rows affected",
        parameterLogPolicies: [.field(versionProperty.name, in: mutation.entity),
          .field(idProperty.name, in: mutation.entity), .field(versionProperty.name, in: mutation.entity)],
        generatedSQL: true, executionOutcome: "success")
    let (record, read) = try fetchPersistedRecord(entity: mutation.entity, id: id, write: metadata)
    return MutationResult(affectedRows: changed, generatedValues: [versionProperty.name: .int(deletedVersion)],
      persistedRecord: record, metadata: metadata.includingStatements([metadata, read]))
  }

  private func insertAudit(_ mutation: Mutation, generatedValues: TeaQLRecord) throws {
    let id = mutation.id ?? generatedValues["id"]
      ?? mutation.entity.idProperty.flatMap { mutation.values[$0.name] }
    try run(
      "INSERT INTO teaql_row_audit_event (entity_type, entity_id, operation, reason, actor, category, occurred_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      parameters: [
        .string(mutation.entity.name),
        id.map { .string(render($0)) } ?? .null,
        .string(mutation.kind.rawValue),
        .string(mutation.auditReason!),
        mutation.actor.map(TeaQLValue.string) ?? .null,
        mutation.auditCategory.map(TeaQLValue.string) ?? .null,
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
    entity: EntityDescriptor, id: TeaQLValue?, write: SQLExecutionMetadata
  ) throws -> (TeaQLRecord, SQLExecutionMetadata) {
    guard let id, let idProperty = entity.idProperty else {
      throw TeaQLError.execution(
        "Persisted state refresh requires entity ID metadata and an ID value")
    }
    let columns = entity.properties.map { quote($0.column) }.joined(separator: ", ")
    let compiled = CompiledSQL(
      sql: "SELECT \(columns) FROM \(quote(entity.table)) WHERE \(quote(idProperty.column)) = ?",
      parameters: [id], parameterLogPolicies: [.field(idProperty.name, in: entity)], generatedSQL: true
    )
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var resultCount: Int?
    let intent = try MutationIntent(comment: write.auditReason).readbackIntent()
    func readMetadata(rejected: Bool = false) -> SQLExecutionMetadata {
      SQLExecutionMetadata(operation: .select, comment: intent.comment,
        purpose: intent.purpose, auditReason: write.auditReason,
        tracePath: TraceChain.readback(write.tracePath), mutationLineage: write.mutationLineage,
        parameterizedSQL: compiled.sql, parameters: compiled.parameters,
        debugSQL: "", elapsedMicros: elapsedMicros(since: startedAt), resultCount: resultCount,
        resultSummary: resultCount.map { "\($0) rows returned" + (rejected ? "; persisted snapshot rejected" : "") }
          ?? "readback failed; row count unknown",
        parameterLogPolicies: compiled.parameterLogPolicies, generatedSQL: true,
        executionOutcome: resultCount == nil ? "failure" : "success")
    }
    do {
      let records = try fetch(compiled, entity: entity)
      resultCount = records.count
      guard records.count == 1 else {
        throw TeaQLError.execution("Persisted state refresh expected one \(entity.name) row; found \(records.count)")
      }
      return (records[0], readMetadata())
    } catch {
      let read = readMetadata(rejected: true)
      throw SQLExecutionFailure(cause: error, diagnostics: [SQLFailureDiagnostic(metadata: write),
        SQLFailureDiagnostic(metadata: read, intentSource: write)])
    }
  }

  private func executeSQL(_ sql: String) throws { try run(sql, parameters: []) }

  private func mutationSQLTrace(_ mutation: Mutation, operation: String) -> [TraceNode] {
    let reason = mutation.auditReason ?? ""
    return TraceChain.canonical((mutation.mutationLineage ?? [
      TraceNode(entity: mutation.entity.name, comment: reason, purpose: "", kind: "auditReason")
    ]) + [
      TraceNode(entity: mutation.entity.name, comment: "", purpose: "", kind: "entity",
        entityID: mutation.id ?? mutation.entity.idProperty.flatMap { mutation.values[$0.name] }),
    ], backend: "sqlite", operation: operation)
  }

  private func querySQLTrace(_ request: QueryRequest) -> [TraceNode] {
    // Origin and intent belong to the request, not supplied diagnostic frames.
    return TraceChain.canonical([
      TraceNode(entity: request.originEntity, comment: request.intent.comment, purpose: "", kind: "comment"),
      TraceNode(entity: request.originEntity, comment: request.intent.purpose, purpose: "", kind: "purpose"),
    ] + request.query.tracePath.filter { $0.kind.lowercased() == "relation" },
      backend: "sqlite", operation: "select")
  }

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

  private func scalarInt64(_ sql: String, parameters: [TeaQLValue]) throws -> Int64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw currentError(sql: sql) }
    defer { sqlite3_finalize(statement) }
    try bind(parameters, to: statement)
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return sqlite3_column_int64(statement, 0)
    case SQLITE_DONE: return nil
    default: throw currentError(sql: sql)
    }
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
      case .calendarDate(let value): result = bindText(value, statement, index)
      case .localDateTime(let value): result = bindText(value, statement, index)
      case .timestamp(let value): result = sqlite3_bind_int64(statement, index, value)
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
      if type == .bool { return .bool(value != 0) }
      if type == .timestamp { return .timestamp(value) }
      return .int(value)
    case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, index))
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, index))
      guard let bytes = sqlite3_column_blob(statement, index) else { return .data(Data()) }
      return .data(Data(bytes: bytes, count: count))
    default:
      let text = String(cString: sqlite3_column_text(statement, index))
      if type == .decimal, let decimal = Decimal(string: text) { return .decimal(decimal) }
      if type == .date {
        // `.date` is used by generated Swift `Date` properties for both
        // calendar dates and audit instants. Preserve a full ISO-8601 instant
        // as a typed Date; only the date-only storage form is a calendar date.
        if let instant = ISO8601DateFormatter().date(from: text) { return .date(instant) }
        return .calendarDate(text)
      }
      if type == .localDateTime { return .localDateTime(text) }
      if type == .timestamp {
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

  private func normalizedValues(
    _ values: TeaQLRecord, for entity: EntityDescriptor
  ) throws -> TeaQLRecord {
    var normalized: TeaQLRecord = [:]
    for (inputName, value) in values {
      let property = try requireProperty(inputName, entity)
      if let existing = normalized[property.name], existing != value {
        throw TeaQLError.execution(
          "Conflicting mutation values for \(entity.name).\(property.name)")
      }
      normalized[property.name] = value
    }
    return normalized
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
    case .calendarDate(let value): value
    case .localDateTime(let value): value
    case .timestamp(let value): String(value)
    case .date(let value): ISO8601DateFormatter().string(from: value)
    case .data: "<data>"
    case .array: "<array>"
    case .object: "<object>"
    }
  }
}

private final class SQLiteHandle: @unchecked Sendable {
  let pointer: OpaquePointer

  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { sqlite3_close(pointer) }
}
