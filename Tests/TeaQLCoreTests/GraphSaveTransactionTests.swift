import XCTest
@testable import TeaQLCore

final class GraphSaveTransactionTests: XCTestCase {
  func testNestedGraphSaveUsesOneTransactionAndCommitCallback() async throws {
    let provider = TransactionRecorder()
    let context = makeContext(provider)
    let callbacks = LockedStrings()

    let result = try await context.executeGraphSave {
      try context.afterGraphCommit { callbacks.append("committed") }
      return try await context.executeGraphSave { 42 }
    }

    XCTAssertEqual(result, 42)
    let beginCount = await provider.beginCount
    XCTAssertEqual(beginCount, 1)
    XCTAssertEqual(callbacks.values, ["committed"])
  }

  func testFailureRollsBackAndRunsCallbacksInReverseOrder() async throws {
    let provider = TransactionRecorder()
    let context = makeContext(provider)
    let callbacks = LockedStrings()
    do {
      _ = try await context.executeGraphSave { () async throws -> Int in
        try context.afterGraphRollback { callbacks.append("parent") }
        try context.afterGraphRollback { callbacks.append("child") }
        throw TeaQLError.execution("injected")
      }
      XCTFail("missing failure")
    } catch { }
    let rollbackCount = await provider.rollbackCount
    XCTAssertEqual(rollbackCount, 1)
    XCTAssertEqual(callbacks.values, ["child", "parent"])
  }

  func testIndependentConcurrentGraphSavesAreSerialized() async throws {
    let provider = TransactionRecorder()
    let context = makeContext(provider)
    async let first: Int = context.executeGraphSave {
      try await Task.sleep(for: .milliseconds(75)); return 1
    }
    async let second: Int = context.executeGraphSave { 2 }
    let values = try await [first, second]
    XCTAssertEqual(Set(values), [1, 2])
    let beginCount = await provider.beginCount
    let maximumActive = await provider.maximumActiveTransactions
    XCTAssertEqual(beginCount, 2)
    XCTAssertEqual(maximumActive, 1)
  }

  func testOneGraphUsesOneCapturedFixClock() async throws {
    let provider = TransactionRecorder()
    let checker = ClockChecker()
    let descriptor = EntityDescriptor(
      name: "Task", table: "task_data",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "clock", entities: [descriptor], checkers: ["Task": checker]))
    let context = UserContext(
      runtime: runtime, queryExecutor: EmptyQueryExecutor(), mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 })
    try await context.executeGraphSave {
      _ = try await context.execute(Mutation(kind: .create, entity: descriptor, auditReason: "first"))
      try await Task.sleep(for: .milliseconds(5))
      _ = try await context.execute(Mutation(kind: .create, entity: descriptor, auditReason: "second"))
    }
    let times = checker.values
    XCTAssertEqual(times.count, 2)
    XCTAssertEqual(times[0], times[1])
  }

  private func makeContext(_ provider: TransactionRecorder) -> UserContext {
    UserContext(
      queryExecutor: EmptyQueryExecutor(), mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 })
  }
}

private struct EmptyQueryExecutor: QueryExecutor {
  func execute(_ query: SelectQuery) async throws -> QueryResult { QueryResult(records: [], backend: "test") }
  func count(_ query: SelectQuery) async throws -> Int { 0 }
}

private actor TransactionRecorder: GraphTransactionExecutor {
  private(set) var beginCount = 0
  private(set) var rollbackCount = 0
  private var activeTransactions = 0
  private(set) var maximumActiveTransactions = 0
  func beginGraphTransaction() async throws {
    beginCount += 1; activeTransactions += 1
    maximumActiveTransactions = max(maximumActiveTransactions, activeTransactions)
  }
  func commitGraphTransaction() async throws { activeTransactions -= 1 }
  func rollbackGraphTransaction() async throws { rollbackCount += 1; activeTransactions -= 1 }
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    MutationResult(affectedRows: 1, persistedRecord: mutation.values)
  }
}

private final class LockedStrings: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) { lock.withLock { storage.append(value) } }
  var values: [String] { lock.withLock { storage } }
}

private final class ClockChecker: @unchecked Sendable, EntityChecker {
  private let lock = NSLock()
  private var times: [Date] = []
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    lock.withLock { times.append(now) }; return []
  }
  var values: [Date] { lock.withLock { times } }
}
