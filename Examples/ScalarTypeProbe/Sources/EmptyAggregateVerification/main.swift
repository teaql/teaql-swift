import Foundation
import CSQLite
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw TeaQLError.execution(message) }
}

private struct Vectors: Decodable {
  struct Scalar: Decodable { let id: String; let values: [Int64?]; let countStar: Int64; let countValue: Int64; let sum: Int64? }
  struct Bucket: Decodable {
    struct Child: Decodable { let parent: Int; let value: Int64? }
    struct Expected: Decodable { let parent: Int; let count: Int64; let sum: Int64? }
    let id: String; let parents: [Int]; let children: [Child]; let expected: [Expected]
  }
  let scalarCases: [Scalar]; let bucketCases: [Bucket]
}

private struct SQLFact: Encodable {
  let sql: String; let comment: String?; let purpose: String?; let outcome: String?
  let rows: Int?; let chain: [TraceNode]; let physicalPath: [TraceNode]
  init(_ metadata: SQLExecutionMetadata) {
    sql = metadata.parameterizedSQL; comment = metadata.comment; purpose = metadata.purpose
    outcome = metadata.executionOutcome; rows = metadata.resultCount; chain = metadata.traceChain
    physicalPath = metadata.tracePath
  }
}
private actor SQLFacts: RuntimeTelemetrySink {
  private var facts: [SQLFact] = []
  func record(_ metadata: SQLExecutionMetadata) { facts.append(SQLFact(metadata)) }
  func reset() { facts = [] }
  func snapshot() -> [SQLFact] { facts }
}
private struct RequestSnapshot: Encodable { let name: String; let before: String; let after: String }
private struct ScalarObservation: Encodable { let id: String; let row: TeaQLRecord; let json: String }
private struct BucketObservation: Encodable { let id: String; let parents: [Int64]; let rows: [TeaQLRecord]; let entityJSON: [String]; let facets: [TeaQLRecord] }

@main enum EmptyAggregateVerification {
  private static let purpose = "Verify generated empty aggregates without losing null or provenance"
  private static func snapshot(_ query: SelectQuery) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(query), as: UTF8.self)
  }
  private static func encoded<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }
  private static func newProbe(_ context: UserContext, owner: Int64, tag: String, amount: Decimal?) throws -> ScalarTypeProbe {
    var entity = try Q.scalarTypeProbes().comment("Prepare an empty-aggregate contribution")
      .purpose(purpose).newEntity(context)
    entity.updateTypePlatform(owner); entity.updateRequiredString(tag)
    entity.updateRequiredBoolean(true); entity.updateRequiredInteger(7); entity.updateRequiredLong(1_234_567)
    entity.updateRequiredDecimal(1); entity.updateOptionalDecimal(amount)
    entity.updateRequiredFloat(1.25); entity.updateRequiredDouble(2.5)
    entity.updateRequiredDate(Date(timeIntervalSince1970: 1_792_454_400))
    entity.updateRequiredTime("09:30:15"); entity.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_488_600))
    return entity
  }
  // Deliberately reversible fault DDL, not business data/query SQL. All data is
  // written with generated audited Mutation APIs and read with Q/E.
  private static func renameTable(_ path: String, restore: Bool) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      if let connection { sqlite3_close(connection) }
      throw TeaQLError.execution("Cannot open the dedicated fault database")
    }
    defer { sqlite3_close(connection) }
    let sql = restore
      ? "ALTER TABLE ea_hidden_scalar_type_probe_data RENAME TO scalar_type_probe_data"
      : "ALTER TABLE scalar_type_probe_data RENAME TO ea_hidden_scalar_type_probe_data"
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw TeaQLError.execution("Reversible aggregate fault DDL failed")
    }
  }

  static func main() async {
    do { try await run() }
    catch { print("SWIFT_EMPTY_FAILURE=" + String(describing: error)); exit(1) }
  }

  private static func run() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["TEAQL_EMPTY_DB"], let input = environment["TEAQL_EMPTY_VECTORS"],
      let round = environment["TEAQL_EMPTY_ROUND"].flatMap(Int.init), (1...2).contains(round) else {
      throw TeaQLError.execution("Set TEAQL_EMPTY_DB, TEAQL_EMPTY_VECTORS and round 1 or 2")
    }
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
    let service = try SQLiteDataService(path: path), telemetry = SQLFacts()
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let context = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: telemetry,
      querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(GeneratedRuntimeModule.module)
    var snapshots: [RequestSnapshot] = [], scalars: [ScalarObservation] = [], buckets: [BucketObservation] = []
    let prefix = "ea-round-\(round)"
    for vector in vectors.scalarCases {
      let tag = "\(prefix)-\(vector.id)"
      for value in vector.values {
        let entity = try newProbe(context, owner: 1, tag: tag, amount: value.map(Decimal.init))
        _ = try await entity.auditAs("Seed an approved scalar aggregate vector").save(context)
      }
    }
    var owners: [String: [Int64]] = [:]
    for vector in vectors.bucketCases {
      var ids: [Int64] = []
      for ordinal in vector.parents {
        var owner = try Q.typePlatforms().comment("Prepare an independent aggregate bucket").purpose(purpose).newEntity(context)
        owner.updateName("\(prefix)-\(vector.id)-\(ordinal)")
        let saved = try await owner.auditAs("Seed an aggregate bucket through the generated API").save(context)
        try require(try E.typePlatform(saved).name().eval() == "\(prefix)-\(vector.id)-\(ordinal)", "Bucket E readback changed")
        ids.append(saved.id)
      }
      owners[vector.id] = ids
      for child in vector.children {
        guard let index = vector.parents.firstIndex(of: child.parent) else { throw TeaQLError.execution("Unknown vector parent") }
        let entity = try newProbe(context, owner: ids[index], tag: "\(prefix)-\(vector.id)", amount: child.value.map(Decimal.init))
        _ = try await entity.auditAs("Seed an approved related aggregate vector").save(context)
      }
    }
    for amount in [Decimal(string: "123456789012.3456789")!, Decimal(string: "0.0000001")!] {
      let entity = try newProbe(context, owner: 1, tag: "\(prefix)-exact", amount: amount)
      _ = try await entity.auditAs("Seed exact Decimal contributions without floating conversion").save(context)
    }
    await telemetry.reset()
    for vector in vectors.scalarCases {
      let request = Q.scalarTypeProbes().withRequiredStringIs("\(prefix)-\(vector.id)")
        .countAs("_rows").sumOptionalDecimalAs("_sum").limit(1)
        .comment("Evaluate \(vector.id) scalar counts and nullable sum").purpose(purpose)
      // COUNT(value) has no generated field accessor. The public request carrier
      // adds only that aggregate; predicates/SUM/COUNT(*) come from Q.
      var query = request.toQuery(); query.aggregates.append(QueryAggregate(.count, field: "optionalDecimal", alias: "_values"))
      let before = try snapshot(query), result = try await context.execute(QueryRequest(query: query))
      snapshots.append(RequestSnapshot(name: vector.id, before: before, after: try snapshot(query)))
      try require(result.records.count == 1, "Scalar aggregate did not return exactly one row")
      let row = result.records[0], expected: TeaQLValue = vector.sum.map { .decimal(Decimal($0)) } ?? .null
      try require(row["_rows"] == .int(vector.countStar) && row["_values"] == .int(vector.countValue)
        && row["_sum"] == expected, "\(vector.id) scalar value mismatch: \(row)")
      let json = try encoded(row)
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
      try require(object.keys.contains("_sum"), "Selected scalar SUM disappeared in JSON")
      if vector.sum == nil { try require(object["_sum"] is NSNull, "Selected empty SUM was not JSON null") }
      scalars.append(ScalarObservation(id: vector.id, row: row, json: json))
    }
    for vector in vectors.bucketCases {
      let ids = owners[vector.id]!
      let child = Q.scalarTypeProbes().withRequiredStringIs("\(prefix)-\(vector.id)").limit(100)
        .comment("Restrict each bucket to this approved child vector")
      let request = Q.typePlatforms().withIdIn(ids).countScalarTypeProbesWith("_rows", child)
        .sumOptionalDecimalOfScalarTypeProbesAs("_sum", child)
        .orderByIdAscending().limit(10).comment("Load \(vector.id) including selected nullable properties").purpose(purpose)
      let before = try snapshot(request.toQuery()), result = try await request.executeForList(context)
      snapshots.append(RequestSnapshot(name: vector.id + "-related", before: before, after: try snapshot(request.toQuery())))
      try require(result.count == ids.count, "Related aggregate lost a parent")
      var records: [TeaQLRecord] = [], json: [String] = []
      for (index, owner) in result.enumerated() {
        let expected = vector.expected[index], sum: TeaQLValue = expected.sum.map { .decimal(Decimal($0)) } ?? .null
        try require(owner.id == ids[index] && owner.dynamicProperties.contains("_rows") && owner.dynamicProperties.contains("_sum"), "Selected dynamic property absent")
        try require(owner.dynamicProperties.value("_rows") == .int(expected.count)
          && owner.dynamicProperties.value("_sum") == sum, "Related aggregate borrowed a different bucket")
        let bytes = try JSONEncoder().encode(owner), object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try require(object.keys.contains("_sum"), "Generated entity omitted selected SUM/null")
        if expected.sum == nil { try require(object["_sum"] is NSNull, "Generated entity SUM/null changed") }
        records.append(["id": .int(owner.id), "_rows": .int(expected.count), "_sum": sum])
        json.append(String(decoding: bytes, as: UTF8.self))
      }
      let choices = Q.typePlatforms().withIdIn(ids).countAs("_rows")
        .sumOptionalDecimalOfScalarTypeProbesAs("_sum", child).orderByIdAscending().limit(10)
        .comment("Load all facet choices including an empty bucket")
      let facet = Q.scalarTypeProbes().withRequiredStringIs("\(prefix)-\(vector.id)")
        .facetByTypePlatformAs("buckets", choices, includeAllFacets: true).offset(1).limit(1)
        .comment("Limit the visible page without narrowing facet membership").purpose(purpose)
      let facetBefore = try snapshot(facet.toQuery()), faceted = try await facet.executeForRows(context)
      snapshots.append(RequestSnapshot(name: vector.id + "-facets", before: facetBefore, after: try snapshot(facet.toQuery())))
      guard let options = faceted.facets["buckets"] else { throw TeaQLError.execution("Facet result absent") }
      try require(options.count == ids.count, "Facet choices were limited to the visible page")
      for (index, row) in options.enumerated() {
        let expected = records[index]
        try require(row["id"] == expected["id"] && row["_rows"] == expected["_rows"] && row["_sum"] == expected["_sum"], "Facet aggregate borrowed data or lost null")
      }
      buckets.append(BucketObservation(id: vector.id, parents: ids, rows: records, entityJSON: json, facets: Array(options)))
    }
    let fallbackRequest = Q.scalarTypeProbes().withRequiredStringIs("\(prefix)-EA-01").sumOptionalDecimalAs("_sum").limit(1)
      .comment("Apply a caller-local fallback to an absent sum").purpose(purpose)
    let fallbackBefore = try snapshot(fallbackRequest.toQuery()), raw = try await fallbackRequest.executeForRows(context)
    guard let value = raw.first?["_sum"] else { throw TeaQLError.execution("Fallback source SUM was absent") }
    let explicitZero = value == .null ? TeaQLValue.decimal(0) : value
    let repeated = try await fallbackRequest.executeForRows(context)
    try require(explicitZero == .decimal(0) && raw.first?["_sum"] == .null && repeated.first?["_sum"] == .null,
      "Caller fallback contaminated the raw aggregate")
    snapshots.append(RequestSnapshot(name: "EA-07", before: fallbackBefore, after: try snapshot(fallbackRequest.toQuery())))
    let grouped = Q.scalarTypeProbes().withRequiredStringIs("\(prefix)-EA-01").groupByRequiredString()
      .sumOptionalDecimalAs("_sum").limit(10).comment("Return no fabricated group on empty input").purpose(purpose)
    let groupedBefore = try snapshot(grouped.toQuery()), groups = try await grouped.executeForRows(context)
    try require(groups.isEmpty, "Empty grouped aggregate fabricated a row")
    snapshots.append(RequestSnapshot(name: "EA-08", before: groupedBefore, after: try snapshot(grouped.toQuery())))
    let exact = Q.scalarTypeProbes().withRequiredStringIs("\(prefix)-exact").sumOptionalDecimalAs("_sum").limit(1)
      .comment("Retain exact Decimal precision in aggregate results").purpose(purpose)
    let exactBefore = try snapshot(exact.toQuery()), exactRows = try await exact.executeForRows(context)
    guard case .decimal(let precise) = exactRows.first?["_sum"] else { throw TeaQLError.execution("Decimal SUM was not typed Decimal") }
    try require(precise == Decimal(string: "123456789012.345679")!, "Decimal SUM passed through a float")
    snapshots.append(RequestSnapshot(name: "exact", before: exactBefore, after: try snapshot(exact.toQuery())))
    let plainRequest = Q.typePlatforms().withIdIs(owners["EA-05"]![0]).limit(1)
      .comment("Read an unselected dynamic-property control").purpose(purpose)
    let plainBefore = try snapshot(plainRequest.toQuery()), plain = try await plainRequest.executeForList(context)
    let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain[0])) as! [String: Any]
    try require(!plain[0].dynamicProperties.contains("_sum") && !plainJSON.keys.contains("_sum"), "Unselected SUM was fabricated")
    snapshots.append(RequestSnapshot(name: "unselected", before: plainBefore, after: try snapshot(plainRequest.toQuery())))
    // First SELECT can succeed, then the actual related SUM preparation fails.
    // Restore the table even when an assertion fails; do not reset the database.
    let failing = Q.typePlatforms().withIdIs(owners["EA-05"]![0])
      .sumOptionalDecimalOfScalarTypeProbesAs("_sum", Q.scalarTypeProbes()).limit(1)
      .comment("Observe a real related SQLite aggregate failure").purpose(purpose)
    let failureBefore = try snapshot(failing.toQuery()), successFacts = await telemetry.snapshot()
    await telemetry.reset(); try renameTable(path, restore: false)
    var failed = false
    do {
      do { _ = try await failing.executeForList(context) }
      catch let SQLiteError.sqlite(code, message, _) {
        try require(code == SQLITE_ERROR && message.contains("no such table"), "Wrong SQLite failure")
        failed = true
      }
      try renameTable(path, restore: true)
    } catch { try? renameTable(path, restore: true); throw error }
    let failureFacts = await telemetry.snapshot(); try require(failed, "Fault did not fail in SQLite")
    await telemetry.reset()
    let recovered = try await failing.executeForList(context)
    let recoveryFacts = await telemetry.snapshot()
    try require(recovered.count == 1 && recovered[0].dynamicProperties.contains("_sum")
      && recovered[0].dynamicProperties.value("_sum") == .null, "Same query/context did not recover")
    snapshots.append(RequestSnapshot(name: "real-failure-recovery", before: failureBefore, after: try snapshot(failing.toQuery())))
    try require(snapshots.allSatisfy { $0.before == $0.after }, "Execution modified a request or its intent")
    try require(failureFacts.count == 2 && failureFacts.last?.outcome == "failure", "Failure SQL lineage was missing or fabricated")
    for fact in successFacts + failureFacts + recoveryFacts {
      try require(fact.purpose == purpose && !(fact.comment ?? "").isEmpty && fact.physicalPath.last?.kind == "sql"
        && fact.chain.contains { $0.kind == "purpose" && $0.comment == purpose },
        "SQL lost intent or its physical leaf: " + (try encoded(fact)))
    }
    struct Observation: Encodable {
      let language = "swift", passed = true, round: Int, prefix: String
      let scalars: [ScalarObservation], buckets: [BucketObservation], requests: [RequestSnapshot]
      let explicitFallback: TeaQLValue, fallbackRaw: TeaQLValue, groupedRows: Int, exactSum: String
      let successSQL: [SQLFact], failureSQL: [SQLFact], recoverySQL: [SQLFact]
    }
    let report = Observation(round: round, prefix: prefix, scalars: scalars, buckets: buckets, requests: snapshots,
      explicitFallback: explicitZero, fallbackRaw: value, groupedRows: groups.count,
      exactSum: NSDecimalNumber(decimal: precise).stringValue, successSQL: successFacts, failureSQL: failureFacts, recoverySQL: recoveryFacts)
    print("SWIFT_EMPTY_AGGREGATES=" + (try encoded(report)))
  }
}
