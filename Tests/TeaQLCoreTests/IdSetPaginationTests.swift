import Foundation
import Testing

@testable import TeaQLCore

private let idSetEntity = EntityDescriptor(
  name: "School", table: "school_data",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
  ])

private func idSetQuery(
  offset: Int = 0, namespace: String = "tests", ttl: Int = 60, maxIds: Int = 100
) -> SelectQuery {
  var query = SelectQuery(entity: idSetEntity)
  query.orderBy = [OrderBy("id", .descending)]
  query.offset = offset
  query.limit = 2
  query.idSetPagination = IdSetPaginationOptions(
    namespace: namespace, ttlSeconds: ttl, maxIds: maxIds)
  query.comment = "load retained school page"
  query.purpose = "verify ID-set conformance"
  return query
}

private func context(
  _ executor: TestIdSetExecutor, store: any IdSetStore = InMemoryIdSetStore(),
  actor: String = "tester", tenant: String? = nil, root: Int64? = nil,
  policy: RequestPolicy? = nil
) -> UserContext {
  UserContext(
    actor: actor, trustedTenant: tenant,
    activeRoot: root.map { ContextEntityRef(entity: "Platform", id: .int($0)) },
    queryExecutor: executor, mutationExecutor: RejectingMutationExecutor(),
    requestPolicy: policy ?? RequestPolicy { $0 }, idSetStore: store)
}

@Test func IDSET_001_isOptInAndDisabledByDefault() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1])
  var query = idSetQuery(); query.idSetPagination = nil
  let ctx = context(executor)
  #expect(try await ids(ctx.execute(query)) == [5, 4])
  #expect(await ctx.idSetPaginationObservation().plan == "ID_SET_DISABLED")
  #expect(await executor.calls == 1)
}

@Test func IDSET_002_003_005_006_buildsWithoutCountAndPreservesJumpOrder() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1])
  let store = InMemoryIdSetStore()
  let policy = RequestPolicy { $0 }
  let first = context(executor, store: store, policy: policy)
  let second = context(executor, store: store, policy: policy)
  #expect(try await ids(first.execute(idSetQuery())) == [5, 4])
  #expect(await first.idSetPaginationObservation() == .init(
    plan: "ID_SET_BUILD", count: 5, countAccuracy: "EXACT"))
  #expect(try await ids(second.execute(idSetQuery(offset: 2))) == [3, 2])
  #expect(await second.idSetPaginationObservation().plan == "ID_SET_HIT")
  #expect(await executor.idBuildCalls == 1)
  #expect(await executor.countCalls == 0)
}

@Test func IDSET_004_emptySetIsRetainedWithExactZeroCount() async throws {
  let executor = TestIdSetExecutor(ids: [])
  let ctx = context(executor)
  #expect(try await ctx.execute(idSetQuery()).records.isEmpty)
  let observation = await ctx.idSetPaginationObservation()
  #expect(observation.count == 0)
  #expect(observation.countAccuracy == "EXACT")
  #expect(await executor.calls == 2)
}

@Test func IDSET_007_addsDeterministicIdTieBreaker() async throws {
  let executor = TestIdSetExecutor(ids: [3, 2, 1])
  var query = idSetQuery(); query.orderBy = [OrderBy("name", .ascending)]
  _ = try await context(executor).execute(query)
  #expect(await executor.buildOrders.contains(where: { $0.field == "id" }))
}

@Test func IDSET_008_overflowDoesNotReportFalseExactCount() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1])
  let ctx = context(executor)
  #expect(try await ids(ctx.execute(idSetQuery(maxIds: 2))) == [5, 4])
  let observation = await ctx.idSetPaginationObservation()
  #expect(observation.plan == "ID_SET_FALLBACK_LIMIT_EXCEEDED")
  #expect(observation.countAccuracy == "LOWER_BOUND")
  #expect(observation.count == 3)
}

@Test func IDSET_009_ttlExpiryRebuilds() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1])
  let store = InMemoryIdSetStore(); let policy = RequestPolicy { $0 }
  let ctx = context(executor, store: store, policy: policy)
  _ = try await ctx.execute(idSetQuery(namespace: "ttl", ttl: 1))
  try await Task.sleep(for: .milliseconds(1_100))
  _ = try await ctx.execute(idSetQuery(namespace: "ttl", ttl: 1))
  #expect(await executor.idBuildCalls == 2)
  #expect(await ctx.idSetPaginationObservation().plan == "ID_SET_BUILD")
}

@Test func IDSET_010_securityParametersAndDataSourceIsolateIdentity() async throws {
  let store = InMemoryIdSetStore(); let sharedPolicy = RequestPolicy { $0 }
  let first = TestIdSetExecutor(ids: [5, 4, 3], identity: "source-a")
  func run(
    _ executor: TestIdSetExecutor, actor: String, tenant: String, root: Int64,
    parameter: String, policy: RequestPolicy
  ) async throws {
    var query = idSetQuery(namespace: "identity")
    query.filter = .equal("name", .string(parameter))
    _ = try await context(
      executor, store: store, actor: actor, tenant: tenant, root: root, policy: policy
    ).execute(query)
  }
  try await run(first, actor: "a", tenant: "a", root: 1, parameter: "a", policy: sharedPolicy)
  try await run(first, actor: "b", tenant: "a", root: 1, parameter: "a", policy: sharedPolicy)
  try await run(first, actor: "a", tenant: "b", root: 1, parameter: "a", policy: sharedPolicy)
  try await run(first, actor: "a", tenant: "a", root: 2, parameter: "a", policy: sharedPolicy)
  try await run(first, actor: "a", tenant: "a", root: 1, parameter: "b", policy: sharedPolicy)
  try await run(first, actor: "a", tenant: "a", root: 1, parameter: "a", policy: RequestPolicy { $0 })
  let second = TestIdSetExecutor(ids: [5, 4, 3], identity: "source-b")
  try await run(second, actor: "a", tenant: "a", root: 1, parameter: "a", policy: sharedPolicy)
  #expect(await first.idBuildCalls == 6)
  #expect(await second.idBuildCalls == 1)
}

@Test func IDSET_011_concurrentCrossContextMissUsesSingleFlight() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1], delay: .milliseconds(100))
  let store = InMemoryIdSetStore(); let policy = RequestPolicy { $0 }
  let first = context(executor, store: store, policy: policy)
  let second = context(executor, store: store, policy: policy)
  async let a = first.execute(idSetQuery(namespace: "single-flight"))
  async let b = second.execute(idSetQuery(offset: 2, namespace: "single-flight"))
  _ = try await (a, b)
  #expect(await executor.idBuildCalls == 1)
  #expect(Set([await first.idSetPaginationObservation().plan,
               await second.idSetPaginationObservation().plan]) == ["ID_SET_BUILD", "ID_SET_HIT"])
}

@Test func IDSET_012_storeFailureFallsBackWithoutChangingRows() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1])
  let ctx = context(executor, store: FailingIdSetStore())
  #expect(try await ids(ctx.execute(idSetQuery())) == [5, 4])
  #expect(await ctx.idSetPaginationObservation().plan == "ID_SET_FALLBACK_STORE_UNAVAILABLE")
}

@Test func IDSET_013_unsupportedShapeFallsBackVisibly() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3])
  var query = idSetQuery(); query.aggregates = [QueryAggregate(.count, field: "id", alias: "count")]
  let ctx = context(executor)
  _ = try await ctx.execute(query)
  #expect(await ctx.idSetPaginationObservation().plan == "ID_SET_FALLBACK_UNSUPPORTED_SHAPE")
}

@Test func IDSET_014_deletionDoesNotShiftRetainedPage() async throws {
  let executor = TestIdSetExecutor(ids: [5, 4, 3, 2, 1])
  let store = InMemoryIdSetStore(); let policy = RequestPolicy { $0 }
  let ctx = context(executor, store: store, policy: policy)
  _ = try await ctx.execute(idSetQuery(namespace: "delete"))
  await executor.delete(4)
  #expect(try await ids(ctx.execute(idSetQuery(offset: 2, namespace: "delete"))) == [3, 2])
  #expect(await executor.idBuildCalls == 1)
}

private func ids(_ result: QueryResult) -> [Int64] {
  result.records.compactMap { $0["id"]?.int64Value }
}

private actor TestIdSetExecutor: QueryExecutor {
  private var storedIds: [Int64]
  private(set) var calls = 0
  private(set) var countCalls = 0
  private(set) var idBuildCalls = 0
  private(set) var buildOrders: [OrderBy] = []
  nonisolated let idSetDataSourceIdentity: String
  let delay: Duration?

  init(ids: [Int64], identity: String = UUID().uuidString, delay: Duration? = nil) {
    storedIds = ids; idSetDataSourceIdentity = identity; self.delay = delay
  }

  func delete(_ id: Int64) { storedIds.removeAll { $0 == id } }

  func execute(_ query: SelectQuery) async throws -> QueryResult {
    calls += 1
    let build = query.projection == ["id"] && query.idSetPagination == nil
    if build {
      idBuildCalls += 1; buildOrders = query.orderBy
      if let delay { try await Task.sleep(for: delay) }
    }
    var selected = requestedIds(query.filter) ?? storedIds
    if query.orderBy.first?.direction == .descending { selected.sort(by: >) }
    else { selected.sort() }
    selected = Array(selected.dropFirst(query.offset).prefix(query.limit ?? selected.count))
    return QueryResult(
      records: selected.map { ["id": .int($0), "name": .string("school-\($0)")] },
      backend: "fixture")
  }

  func count(_ query: SelectQuery) async throws -> Int { countCalls += 1; return storedIds.count }

  private func requestedIds(_ expression: TeaQLExpression?) -> [Int64]? {
    switch expression {
    case .inList("id", let values): return values.compactMap(\.int64Value)
    case .and(let parts): return parts.compactMap(requestedIds).first
    default: return nil
    }
  }
}

private struct RejectingMutationExecutor: MutationExecutor {
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    throw TeaQLError.execution("mutation is not part of ID-set tests")
  }
}

private struct FailingIdSetStore: IdSetStore {
  func obtain(
    key: String, build: @escaping @Sendable () async throws -> RetainedIdSet
  ) async throws -> (RetainedIdSet, Bool) {
    throw TeaQLError.execution("store unavailable")
  }
}
