import XCTest
@testable import TeaQLCore

final class RuntimeModuleTests: XCTestCase {
  private let first = EntityDescriptor(
    name: "First", table: "first_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])

  func testPassiveModulesInstallAndComposeDeterministically() throws {
    let module = RuntimeModule(name: "example", entities: [first])
    XCTAssertEqual(module.entities, [first])

    var runtime = TeaQLRuntime()
    try runtime.install(module)
    try runtime.install(module)
    XCTAssertEqual(runtime.entities, [first])
    XCTAssertEqual(runtime.entity(named: "First"), first)
  }

  func testConflictingDescriptorsFailInstallation() throws {
    let conflict = EntityDescriptor(
      name: "First", table: "other_data",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "one", entities: [first]))
    XCTAssertThrowsError(
      try runtime.install(RuntimeModule(name: "two", entities: [conflict])))
  }

  func testCheckerFailureIsStructuredSaveScopedAndPrecedesProvider() async throws {
    let checker = RequiredNameChecker()
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(
      name: "checked", entities: [first], checkers: ["First": checker]))
    let executor = CountingExecutor()
    let context = UserContext(
      runtime: runtime, queryExecutor: executor, mutationExecutor: executor,
      requestPolicy: RequestPolicy { $0 })
    let mutation = Mutation(
      kind: .create, entity: first, values: [:], auditReason: "create invalid")

    for _ in 0..<2 {
      do {
        _ = try await context.execute(mutation)
        XCTFail("invalid mutation must fail")
      } catch let error as CheckException {
        XCTAssertEqual(error.violations.first?.location, "name")
      }
    }
    XCTAssertEqual(checker.calls, 2)
    let mutationCalls = await executor.mutationCalls
    XCTAssertEqual(mutationCalls, 0)
  }
}

private final class RequiredNameChecker: EntityChecker, @unchecked Sendable {
  private(set) var calls = 0
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) -> [CheckResult] {
    calls += 1
    return mutation.values["name"] == nil
      ? [CheckResult(ruleID: "required", location: "name")] : []
  }
}

private actor CountingExecutor: QueryExecutor, MutationExecutor {
  private(set) var mutationCalls = 0
  func execute(_ query: SelectQuery) async throws -> QueryResult {
    QueryResult(records: [], backend: "test")
  }
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    mutationCalls += 1
    return MutationResult(affectedRows: 1)
  }
}
