import Foundation
import XCTest
@testable import TeaQLCore

final class TypedListTelemetryTests: XCTestCase {
  private func query(_ name: String = "Order") -> SelectQuery {
    var query = SelectQuery(entity: EntityDescriptor(name: name, table: name.lowercased(),
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)]))
    query.comment = "load \(name)"; query.purpose = "verify list lifecycle"; query.limit = 1
    query.pageCountOperation = QueryOperation("named-count", method: "countAs", alias: "totalOrders")
    return query
  }

  func testTypedHydrationStaysInsideOneRootWithOptionalCount() async throws {
    for counted in [false, true] {
      let executor = ListExecutor(), probe = ListProbe()
      let context = UserContext(queryExecutor: executor, mutationExecutor: executor,
        requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: probe)
      let result: SmartList<Int64> = try await context.executeTypedList(query(), countRequested: counted) { row in
        XCTAssertEqual(probe.roots.filter { $0.phase == "start" }.count, 1)
        XCTAssertEqual(probe.roots.filter { $0.phase == "success" }.count, 0)
        return row["id"]!.int64Value!
      }
      XCTAssertEqual(Array(result), [2])
      XCTAssertEqual(probe.roots.map(\.phase), ["start", "success"])
      XCTAssertEqual(probe.roots.last?.cardinality, 1)
      let counts = await executor.calls()
      XCTAssertEqual(counts, counted ? [1, 1] : [1, 0])
      XCTAssertEqual(result.aggregations, counted ? ["totalOrders": .int(3)] : [:])
    }
  }

  func testHydrationFailurePreservedAndNextInvocationHasNewRoot() async throws {
    let executor = ListExecutor(), probe = ListProbe()
    let context = UserContext(queryExecutor: executor, mutationExecutor: executor,
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: probe)
    do {
      let _: SmartList<Int64> = try await context.executeTypedList(query(), countRequested: true) { _ in
        throw ListFailure.hydration
      }
      XCTFail("expected hydration failure")
    } catch { XCTAssertEqual(error as? ListFailure, .hydration) }
    let _: SmartList<Int64> = try await context.executeTypedList(query(), countRequested: false) { $0["id"]!.int64Value! }
    XCTAssertEqual(probe.roots.map(\.phase), ["start", "failure", "start", "success"])
  }

  func testConcurrentListsInSharedContextKeepSeparateRoots() async throws {
    let executor = ListExecutor(), probe = ListProbe()
    let context = UserContext(queryExecutor: executor, mutationExecutor: executor,
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: probe)
    let query = query()
    async let first: SmartList<Int64> = context.executeTypedList(query, countRequested: true) { $0["id"]!.int64Value! }
    async let second: SmartList<Int64> = context.executeTypedList(query, countRequested: true) { $0["id"]!.int64Value! }
    let results = try await (first, second)
    XCTAssertEqual(results.0.first, 2); XCTAssertEqual(results.1.first, 2)
    XCTAssertEqual(probe.roots.filter { $0.phase == "start" }.count, 2)
    XCTAssertEqual(probe.roots.filter { $0.phase == "success" }.count, 2)
  }

  func testCountedPolicyAppliedOnceAndItsLimitCannotBeOverwritten() async throws {
    let executor = ListExecutor(), probe = ListProbe(), policy = PolicyProbe()
    let context = UserContext(queryExecutor: executor, mutationExecutor: executor,
      requestPolicy: RequestPolicy { query in policy.apply(query) }, runtimeTelemetry: probe)
    var query = query(); query.limit = 100
    let result: SmartList<Int64> = try await context.executeTypedList(query, countRequested: true) { $0["id"]!.int64Value! }
    XCTAssertEqual(result.count, 1); XCTAssertEqual(policy.count, 1)
    let selected = await executor.lastQuery()
    XCTAssertEqual(selected?.limit, 1)
    XCTAssertEqual(selected?.filter, .equal("id", .int(2)))
    let page = try await context.executePage(query, offset: 0, limit: 100)
    XCTAssertEqual(page.limit, 1); XCTAssertEqual(policy.count, 2)
  }

  func testProviderFailureClosesRootAndPreservesError() async throws {
    let executor = ListExecutor(fail: true), probe = ListProbe()
    let context = UserContext(queryExecutor: executor, mutationExecutor: executor,
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: probe)
    do {
      let _: SmartList<Int64> = try await context.executeTypedList(query(), countRequested: false) { $0["id"]!.int64Value! }
      XCTFail("expected provider failure")
    } catch { XCTAssertEqual(error as? ListFailure, .provider) }
    XCTAssertEqual(probe.roots.map(\.phase), ["start", "failure"])
  }
}

private enum ListFailure: Error { case hydration, provider }
private actor ListExecutor: QueryExecutor, MutationExecutor {
  private var reads = 0, counts = 0
  private var selected: SelectQuery?
  let fail: Bool
  init(fail: Bool = false) { self.fail = fail }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    if fail { throw ListFailure.provider }
    reads += 1; selected = request.query
    await Task.yield()
    return QueryResult(records: [["id": .int(2)]], backend: "stub")
  }
  func count(_ request: QueryRequest) async throws -> Int { counts += 1; return 3 }
  func execute(_ request: MutationRequest) async throws -> MutationResult { MutationResult(affectedRows: 0) }
  func calls() -> [Int] { [reads, counts] }
  func lastQuery() -> SelectQuery? { selected }
}

private final class PolicyProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var applied = 0
  var count: Int { lock.withLock { applied } }
  func apply(_ input: SelectQuery) -> SelectQuery {
    lock.withLock { applied += 1 }
    var query = input; query.limit = 1; query.filter = .equal("id", .int(2)); return query
  }
}

private final class ListProbe: RuntimeTelemetry, @unchecked Sendable {
  struct Entry { let phase: String; let cardinality: Int64? }
  private let lock = NSLock()
  private var entries: [Entry] = []
  var roots: [Entry] { lock.withLock { entries } }
  func withOperation<Result: Sendable>(_ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result) async rethrows -> Result {
    if operation.family != "query" { return try await body() }
    lock.withLock { entries.append(Entry(phase: "start", cardinality: nil)) }
    do {
      let result = try await body()
      let count: Int64?
      if case let .integer(value) = completion(result)["teaql.result.cardinality"] { count = value } else { count = nil }
      lock.withLock { entries.append(Entry(phase: "success", cardinality: count)) }
      return result
    } catch {
      lock.withLock { entries.append(Entry(phase: "failure", cardinality: nil)) }
      throw error
    }
  }
  func withSynchronousOperation<Result>(_ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue], _ body: () throws -> Result) rethrows -> Result { try body() }
  func flush() async {}
  func shutdown() async {}
}
