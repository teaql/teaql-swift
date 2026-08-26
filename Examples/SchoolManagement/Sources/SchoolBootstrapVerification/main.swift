import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw TeaQLError.execution(message) }
}

@main enum SchoolBootstrapVerification {
  static func main() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaql-school-swift-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let service = try SQLiteDataService(path: path)
    let module = GeneratedRuntimeModule.module
    try await service.ensureSchema(module)
    try await service.ensureSchema(module)

    var runtime = TeaQLRuntime()
    try runtime.install(module)
    let context = UserContext(
      runtime: runtime, actor: "conformance", queryExecutor: service,
      mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
    let platforms = try await Q.platforms().comment("verify seeded root")
      .purpose("local runtime verification").executeForList(context)
    let constants = try await Q.schoolTypes().orderByIdAscending()
      .comment("verify seeded constants").purpose("local runtime verification")
      .executeForList(context)
    try require(platforms.count == 1 && platforms[0].id == 1, "Platform id 1 was not seeded")
    try require(constants.count == 2 && constants[0].id == 1001 && constants[1].id == 1002,
                "SchoolType constants were not seeded")
    try require(constants[0].version == 1 && constants[1].version == 1,
                "Repeated ensureSchema was not idempotent")

    var values = module.constantEntities[0].values
    values["name"] = .string("Primary School")
    let changedModule = RuntimeModule(
      name: module.name, entities: module.entities, checkers: module.checkers,
      rootEntities: module.rootEntities,
      constantEntities: [BootstrapEntity(entity: "SchoolType", id: 1001, values: values), module.constantEntities[1]])
    try await service.ensureSchema(changedModule)
    let changed = try await Q.schoolTypes().withIdIs(1001)
      .comment("verify constant reconciliation").purpose("local runtime verification")
      .executeForList(context)
    try require(changed.count == 1 && changed[0].name == "Primary School" && changed[0].version == 2,
                "Changed constant was not reconciled exactly once")
    print("PASS Swift School bootstrap with local runtime")
  }
}
