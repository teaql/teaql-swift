import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw TeaQLError.execution(message) }
}

private actor ObservedProvider: QueryExecutor, GraphTransactionExecutor {
  let service: SQLiteDataService
  private var queries = 0, mutations = 0, begins = 0
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    queries += 1; return try await service.execute(request)
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    mutations += 1; return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
  func snapshot() -> [Int] { [queries, mutations, begins] }
}

@main enum ExpressionProfiles {
  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let profile = environment["TEAQL_EXPRESSION_PROFILE"], let database = environment["TEAQL_EXPRESSION_DB"],
      let round = Int(environment["TEAQL_EXPRESSION_ROUND"] ?? "") else { throw TeaQLError.execution("Missing example configuration") }
    guard let pointer = ["camelCase": "/scalarTypeProbeList", "snake_case": "/scalar_type_probe_list", "PascalCase": "/ScalarTypeProbeList"][profile],
      let suffix = ["camelCase": "/0/requiredString", "snake_case": "/0/required_string", "PascalCase": "/0/RequiredString"][profile] else {
      throw TeaQLError.execution("Unknown model profile")
    }
    let service = try SQLiteDataService(path: database)
    var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
    let schemaContext = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
    try await schemaContext.ensureSchema(GeneratedRuntimeModule.module)
    let observed = ObservedProvider(service)
    let context = UserContext(runtime: runtime, queryExecutor: observed, mutationExecutor: observed, requestPolicy: RequestPolicy { $0 })
    let rows = try await Q.typePlatforms().withIdIs(1).limit(1)
      .comment("Load the root without its reverse list")
      .purpose("Verify generated E diagnostics under the modeled JSON profile").executeForList(context)
    guard rows.count == 1, let row = rows.first else { throw TeaQLError.execution("Missing seeded root") }
    try require(row.id == 1, "Root identity drift")
    let name = try E.typePlatform(row).name().eval(), before = await observed.snapshot()
    try require(before[0] > 0, "The observer must measure the actual Q query")
    let wire: NotLoadedDiagnostic, human: String
    do {
      _ = try E.typePlatform(row).scalarTypeProbeList().first().requiredString().eval()
      throw TeaQLError.execution("An unselected list must remain NotLoaded")
    } catch let error as TeaQLCore.TeaQLNotLoadedError { wire = error.toWire(); human = error.description }
    let dto = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as! [String: Any]
    try require(dto["location"] as? [[String: String]] == [["kind": "property", "name": "scalar_type_probe_list"]], "Canonical location drift")
    try require(wire.code == "NOT_LOADED" && wire.instancePath == pointer && wire.attemptedInstancePath == pointer + suffix, "Model profile drift")
    try require(wire.breakPoint == "scalar_type_probe_list" && wire.breakPointIndex == 0, "Wrong first failure")
    try require(wire.originalExpression == "E.typePlatform(<root>).scalarTypeProbeList().first().requiredString().eval()", "Lost original expression")
    try require(wire.expressionWithBrokenPoint == "E.typePlatform(<root>).scalarTypeProbeList()<broken>.first().requiredString().eval()", "Wrong breakpoint")
    try require(human.hasPrefix("TeaQLNotLoadedError:") && human.contains("expression=" + wire.expressionWithBrokenPoint)
      && !human.contains("\"instancePath\""), "Human view drift")
    let after = await observed.snapshot(), afterName = try E.typePlatform(row).name().eval()
    try require(after == before && afterName == name, "E changed state or accessed the provider")
    struct Observation: Encodable {
      let language = "swift", profile: String, round: Int, passed = true
      let wire: NotLoadedDiagnostic, human: String
      let providerEntries = 0, queryCalibration: Int, selectedNameUnchanged = true
    }
    let value = Observation(profile: profile, round: round, wire: wire, human: human, queryCalibration: before[0])
    print("GENERATED_E_MODEL_PROFILE=" + String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
  }
}
