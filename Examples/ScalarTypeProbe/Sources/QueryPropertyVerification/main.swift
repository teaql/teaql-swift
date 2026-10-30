import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private actor ObservedProvider: QueryExecutor, GraphTransactionExecutor {
  let service: SQLiteDataService
  private var writes: [[String]] = []
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult { try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes.append(request.mutation.values.keys.sorted())
    return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
  func clear() { writes = [] }
  func fields() -> [[String]] { writes }
}

@main enum QueryPropertyVerification {
  static func main() async throws {
    guard let path = ProcessInfo.processInfo.environment["TEAQL_QUERY_PROPERTY_DB"] else {
      throw TeaQLError.execution("Set TEAQL_QUERY_PROPERTY_DB to a dedicated example database")
    }
    let service = try SQLiteDataService(path: path), provider = ObservedProvider(service)
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let schemaContext = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await schemaContext.ensureSchema(GeneratedRuntimeModule.module)
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    let rows = try await Q.typePlatforms().countScalarTypeProbesAs("_count")
      .orderByIdAscending().limit(10)
      .comment("Load a selected zero-valued child count")
      .purpose("Verify generated query-property JSON and read-only ownership").executeForList(context)
    guard rows.count == 1, let row = rows.first else { throw TeaQLError.execution("Missing seeded owner") }
    let name = try E.typePlatform(row).name().eval()
    guard let beforeVersion = try E.typePlatform(row).version().eval() else {
      throw TeaQLError.execution("Selected owner version is null")
    }
    let present = row.dynamicProperties.contains("_count"), count = row.dynamicProperties.value("_count")?.int64Value
    let bytes = try JSONEncoder().encode(row)
    guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw TeaQLError.execution("Generated entity JSON is not an object")
    }
    let encoded = (json["_count"] as? NSNumber)?.int64Value
    let absentRows = try await Q.typePlatforms().withIdIs(row.id).limit(1)
      .comment("Load the same owner without derived aliases")
      .purpose("Ensure serialization does not fabricate unselected properties").executeForList(context)
    guard let absent = absentRows.first,
      let absentJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(absent)) as? [String: Any] else {
      throw TeaQLError.execution("Missing unselected owner control")
    }
    let unselectedRemainsAbsent = !absent.dynamicProperties.contains("_count")
      && absent.dynamicProperties.value("_count") == nil && !absentJSON.keys.contains("_count")
    var edited = row
    let nextName = name == "Query property A" ? "Query property B" : "Query property A"
    edited.updateName(nextName); await provider.clear()
    _ = try await edited.auditAs("Change a modeled name without persisting a query snapshot").save(context)
    let writes = await provider.fields()
    let savedRows = try await Q.typePlatforms().withIdIs(row.id).limit(1)
      .comment("Reload the modeled mutation")
      .purpose("Verify derived fields never entered the mutation record").executeForList(context)
    guard let saved = savedRows.first else { throw TeaQLError.execution("Missing saved query-property owner") }
    guard let afterVersion = try E.typePlatform(saved).version().eval() else {
      throw TeaQLError.execution("Persisted owner version is null")
    }
    let savedName = try E.typePlatform(saved).name().eval()
    let mutationExcludedAliases = writes.count == 1 && writes[0].contains("name")
      && !writes[0].contains("_count") && savedName == nextName
      && afterVersion == beforeVersion + 1
    let originalSnapshotUnchanged = row.dynamicProperties.contains("_count") && row.dynamicProperties.value("_count")?.int64Value == 0
    struct Observation: Encodable {
      let language = "swift", normalGeneratedQuery = true, expectedCount: Int64 = 0
      let rootName: String?, propertyPresent: Bool, count: Int64?, encodedCount: Int64?, encodedPropertyPresent: Bool
      let encodedJSON: String, unselectedRemainsAbsent: Bool, mutationExcludedAliases: Bool, originalSnapshotUnchanged: Bool
      let beforeVersion: Int64, afterVersion: Int64, mutationFields: [[String]], passed: Bool
    }
    let result = Observation(rootName: name, propertyPresent: present, count: count, encodedCount: encoded,
      encodedPropertyPresent: json.keys.contains("_count"), encodedJSON: String(decoding: bytes, as: UTF8.self),
      unselectedRemainsAbsent: unselectedRemainsAbsent, mutationExcludedAliases: mutationExcludedAliases,
      originalSnapshotUnchanged: originalSnapshotUnchanged, beforeVersion: beforeVersion, afterVersion: afterVersion,
      mutationFields: writes, passed: present && count == 0 && encoded == 0 && unselectedRemainsAbsent
        && mutationExcludedAliases && originalSnapshotUnchanged)
    print("SWIFT_QUERY_PROPERTY_JSON=" + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
  }
}
