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
    var runtime = TeaQLRuntime()
    try runtime.install(module)
    let context = UserContext(
      runtime: runtime, actor: "conformance", queryExecutor: service,
      mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
    try await context.ensureSchema(module)
    try await context.ensureSchema(module)
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

    let createRequest = Q.schools().comment("create school through constant helper")
      .purpose("prove seeded constants form a usable relation graph")
    var school = try createRequest.newEntity(context)
    let now = Date()
    school.updatePlatform(1)
    school.updateSchoolTypeToPrimary()
    school.updateName("Riverside Primary School")
    school.updateAddress("12 River Road, Springfield")
    school.updateEstablishedDate(Date(timeIntervalSince1970: 810_950_400))
    school.updateStudentCapacity("800")
    school.updateActive(true)
    school.updateCreateTime(now)
    school.updateUpdateTime(now)
    let saved = try await school.auditAs("seed school linked to PRIMARY").save(context)
    try require(saved.schoolType == 1001,
                "Constant helper did not retain School.schoolType=1001 after save")

    let allSchools = try await Q.schools().withNameContaining("Riverside")
      .comment("read persisted school foreign key")
      .purpose("verify the constant helper reached SQLite")
      .executeForList(context)
    try require(allSchools.count == 1 && allSchools[0].schoolType == 1001,
                "Persisted School.school_type is not 1001")
    let primarySchools = try await Q.schools().withSchoolTypeIsPrimary()
      .selectSchoolTypeWith(Q.schoolTypes().selectCode())
      .comment("load schools linked to PRIMARY")
      .purpose("verify the seeded constant relationship is queryable")
      .executeForList(context)
    try require(primarySchools.count == 1,
                "withSchoolTypeIsPrimary did not match the persisted school")
    try require(primarySchools[0].schoolTypeEntity?.code == "PRIMARY",
                "SchoolType forward relation did not hydrate PRIMARY")

    let queryCases: [(String, SchoolRequest<RequestDraft>, Int)] = [
      ("string equality", Q.schools().withNameIs("Riverside Primary School"), 1),
      ("string inequality", Q.schools().withNameIsNot("Another School"), 1),
      ("string membership", Q.schools().withNameIn(["Riverside Primary School", "Another School"]), 1),
      ("negative membership", Q.schools().withNameNotIn(["Another School"]), 1),
      ("contains", Q.schools().withNameContaining("Primary"), 1),
      ("negative contains", Q.schools().withNameNotContaining("Secondary"), 1),
      ("starts with", Q.schools().withNameStartingWith("Riverside"), 1),
      ("negative starts with", Q.schools().withNameNotStartingWith("Lakeside"), 1),
      ("ends with", Q.schools().withNameEndingWith("School"), 1),
      ("negative ends with", Q.schools().withNameNotEndingWith("Academy"), 1),
      ("number range", Q.schools().withStudentCapacityBetween("700", "900"), 1),
      ("strict comparison", Q.schools().withStudentCapacityGreaterThan("799").withStudentCapacityLessThan("801"), 1),
      ("date range", Q.schools().withEstablishedDateBetween(
        Date(timeIntervalSince1970: 788_918_400), Date(timeIntervalSince1970: 820_454_400)), 1),
      ("known", Q.schools().withAddressIsKnown(), 1),
      ("unknown", Q.schools().withAddressIsUnknown(), 0),
        ("boolean true", Q.schools().whichAreActive(), 1),
        ("boolean false", Q.schools().whichAreNotActive(), 0),
      ("constant relation", Q.schools().withSchoolTypeIsPrimary(), 1),
    ]
    for (label, request, expected) in queryCases {
      let result = try await request.comment("Query parity: \(label)")
        .purpose("Execute the shared School Query conformance case")
        .executeForList(context)
      try require(result.count == expected,
                  "\(label): expected \(expected), got \(result.count)")
    }
    let projected = try await Q.schools().selectName().orderByIdDescending()
      .comment("Query parity: projection and ordering")
      .purpose("Execute the shared School Query conformance case")
      .executeForList(context)
    try require(projected.count == 1 && projected[0].name == "Riverside Primary School",
                "projection/order query did not preserve typed School result")

    var values = module.constantEntities[0].values
    values["name"] = .string("Primary School")
    let changedModule = RuntimeModule(
      name: module.name, entities: module.entities, checkers: module.checkers,
      rootEntities: module.rootEntities,
      constantEntities: [BootstrapEntity(entity: "SchoolType", id: 1001, values: values), module.constantEntities[1]])
    try await context.ensureSchema(changedModule)
    let changed = try await Q.schoolTypes().withIdIs(1001)
      .comment("verify constant reconciliation").purpose("local runtime verification")
      .executeForList(context)
    try require(changed.count == 1 && changed[0].name == "Primary School" && changed[0].version == 2,
                "Changed constant was not reconciled exactly once")
    print("PASS Swift School bootstrap, portable Query parity, and constant relation graph")
  }
}
