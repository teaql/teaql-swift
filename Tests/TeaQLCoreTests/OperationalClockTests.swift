import Foundation
import Testing
@testable import TeaQLCore

private final class OperationalBusinessClock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 4_102_444_800)
  private var calls = 0
  var reads: Int { lock.withLock { calls } }
  func now() -> Date { lock.withLock { calls += 1; return value } }
  func set(_ value: Date) { lock.withLock { self.value = value } }
}

private struct NoClockIO: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    throw TeaQLError.execution("operational clock fixture must not query a provider")
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    throw TeaQLError.execution("operational clock fixture must not mutate a provider")
  }
}

private func calibratedClock() throws -> (UserContext, OperationalBusinessClock) {
  let clock = OperationalBusinessClock()
  let context = UserContext(queryExecutor: NoClockIO(), mutationExecutor: NoClockIO(),
    requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry(), businessClock: clock)
  try #require(context.businessTime == Date(timeIntervalSince1970: 4_102_444_800))
  try #require(clock.reads == 1)
  return (context, clock)
}

private func emitClock(_ name: String, _ clock: OperationalBusinessClock, _ facts: [String: Bool]) throws {
  try #require(clock.reads == 1)
  try #require(facts.values.allSatisfy { $0 })
  let value: [String: Any] = ["case": name, "passed": true, "calibrationCalls": 1,
    "additionalBusinessReads": 0, "realTime": true, "facts": facts]
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print("SWIFT_OPERATIONAL_CLOCK_CASE=" + String(decoding: data, as: UTF8.self))
}

@Test func operationalClockCacheRealExpiryIsIndependentOfBusinessTime() async throws {
  let (_, clock) = try calibratedClock(), cache = LocalCache()
  cache.put("finite", value: "live", timeToLiveInSeconds: 1)
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  try #require(cache.get("finite", as: String.self) == "live")
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while cache.get("finite", as: String.self) != nil, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(cache.get("finite", as: String.self) == nil)
  clock.set(Date(timeIntervalSince1970: -2_208_988_800))
  try #require(cache.get("finite", as: String.self) == nil)
  try emitClock("cache-real-expiry", clock, ["futureBusinessDoesNotExpire": true,
    "realExpiry": true, "businessPastCannotRevive": true])
}

@Test func operationalClockCachePreservesZeroFalseEmptyNullAndNoExpiry() async throws {
  let (_, clock) = try calibratedClock(), cache = LocalCache()
  cache.put("zero", value: 0, timeToLiveInSeconds: 0)
  cache.put("false", value: false); cache.put("empty", value: "")
  cache.put("null", value: TeaQLValue.null)
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  try await Task.sleep(for: .milliseconds(1_050))
  try #require(cache.get("zero", as: Int.self) == 0)
  try #require(cache.get("false", as: Bool.self) == false)
  try #require(cache.get("empty", as: String.self) == "")
  try #require(cache.get("null", as: TeaQLValue.self) == .null)
  try #require(cache.get("zero", as: String.self) == nil)
  cache.remove("false"); try #require(cache.get("false", as: Bool.self) == nil)
  cache.removeAll(); try #require(cache.get("zero", as: Int.self) == nil)
  try emitClock("cache-values", clock, ["zeroAndOmittedTtlRemain": true,
    "zeroFalseEmptyNullRemainValues": true, "typeFilterPreserved": true, "removeAndClearPreserved": true])
}

@Test func operationalClockLocalLockLeaseAndOwnerAreIndependent() async throws {
  let (_, clock) = try calibratedClock(), lock = LocalLock()
  let first = UUID(), second = UUID(), key = "lease"
  defer { lock.unlock(key, owner: first); lock.unlock(key, owner: second) }
  try #require(lock.tryLock(key, owner: first, timeoutMillis: 0, expireMillis: 100))
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  try #require(!lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 100))
  lock.unlock(key, owner: second)
  try #require(!lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 100))
  try await Task.sleep(for: .milliseconds(120))
  try #require(lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 0))
  clock.set(Date(timeIntervalSince1970: -2_208_988_800))
  lock.unlock(key, owner: first)
  try #require(!lock.tryLock(key, owner: first, timeoutMillis: 0, expireMillis: 0))
  try emitClock("local-lock-lease-owner", clock, ["futureBusinessCannotStealLease": true,
    "wrongOwnerCannotUnlock": true, "realLeaseExpires": true, "pastBusinessCannotStealNewOwner": true])
}

@Test func operationalClockLocalLockWaitIsFiniteWithoutBusinessReads() throws {
  let (_, clock) = try calibratedClock(), lock = LocalLock()
  let first = UUID(), second = UUID(), key = "timeout"
  defer { lock.unlock(key, owner: first); lock.unlock(key, owner: second) }
  try #require(lock.tryLock(key, owner: first, timeoutMillis: 0, expireMillis: 0))
  try #require(lock.tryLock(key, owner: first, timeoutMillis: 0, expireMillis: 0))
  clock.set(Date(timeIntervalSince1970: -2_208_988_800))
  let start = ContinuousClock.now
  try #require(!lock.tryLock(key, owner: second, timeoutMillis: 25, expireMillis: 0))
  let elapsed = start.duration(to: .now)
  try #require(elapsed >= .milliseconds(10) && elapsed < .seconds(2))
  try #require(!lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 0))
  lock.unlock(key, owner: first)
  try #require(lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 0))
  try emitClock("local-lock-finite-wait", clock, ["noExpiryAndReentryPreserved": true,
    "finiteTimeout": true, "timeoutCannotReleaseOwner": true, "acquireAfterRelease": true])
}

@Test func operationalClockWideIDSetUsesItsOwnExpiry() async throws {
  let (_, clock) = try calibratedClock(), store = InMemoryIdSetStore()
  // Leave room for the full suite's concurrent actor scheduling before a hit.
  let expiry = Date().addingTimeInterval(5), ids: [Int64] = [9_007_199_254_740_993]
  let initial = try await store.obtain(key: "wide") { RetainedIdSet(ids: ids, expiresAt: expiry) }
  try #require(initial.0.ids == ids && initial.1)
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  let hit = try await store.obtain(key: "wide") { throw TeaQLError.execution("live snapshot rebuilt") }
  try #require(hit.0.ids == ids && !hit.1)
  try await Task.sleep(for: .milliseconds(5_100))
  let rebuilt = try await store.obtain(key: "wide") { RetainedIdSet(ids: [], expiresAt: Date().addingTimeInterval(60)) }
  try #require(rebuilt.0.ids.isEmpty && rebuilt.1)
  clock.set(Date(timeIntervalSince1970: -2_208_988_800))
  let after = try await store.obtain(key: "wide") { throw TeaQLError.execution("expired wide IDs revived") }
  try #require(after.0.ids.isEmpty && !after.1)
  try emitClock("id-set-wide", clock, ["exactWideIdentity": true, "futureBusinessDoesNotExpire": true,
    "realExpiryRebuilds": true, "pastBusinessCannotReviveOldSnapshot": true])
}

@Test func operationalClockEmptyIDSetIsAHitUntilItsExpiry() async throws {
  let (_, clock) = try calibratedClock(), store = InMemoryIdSetStore()
  let expiry = Date().addingTimeInterval(5)
  let initial = try await store.obtain(key: "empty") { RetainedIdSet(ids: [], expiresAt: expiry) }
  try #require(initial.0.ids.isEmpty && initial.1)
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  let hit = try await store.obtain(key: "empty") { throw TeaQLError.execution("empty hit treated as missing") }
  try #require(hit.0.ids.isEmpty && !hit.1)
  try await Task.sleep(for: .milliseconds(5_100))
  let rebuilt = try await store.obtain(key: "empty") { RetainedIdSet(ids: [1], expiresAt: Date().addingTimeInterval(60)) }
  try #require(rebuilt.0.ids == [1] && rebuilt.1)
  try emitClock("id-set-empty", clock, ["emptyIsHitNotMissing": true,
    "futureBusinessDoesNotExpire": true, "realExpiryRebuilds": true])
}

private actor OperationalPageExecutor: QueryExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    let query = request.query
    var ids: [Int64] = [6, 5, 4, 3, 2, 1]
    if case .lessThan("id", let boundary) = query.filter, let value = boundary.int64Value {
      ids = ids.filter { $0 < value }
    } else if query.filter != nil {
      throw TeaQLError.execution("unexpected continuous-page condition")
    }
    ids = Array(ids.dropFirst(query.offset).prefix(query.limit ?? 0))
    return QueryResult(records: ids.map { ["id": .int($0)] }, backend: "operational-clock-fixture")
  }
}

@Test func operationalClockContinuousPageExpiresByOperationalTime() async throws {
  let clock = OperationalBusinessClock()
  let context = UserContext(queryExecutor: OperationalPageExecutor(), mutationExecutor: NoClockIO(),
    requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry(), businessClock: clock)
  try #require(context.businessTime == Date(timeIntervalSince1970: 4_102_444_800))
  let entity = EntityDescriptor(name: "ClockProbe", table: "clock_probe_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
  var first = SelectQuery(entity: entity)
  first.orderBy = [OrderBy("id", .descending)]; first.limit = 2
  first.continuousPage = ContinuousPageFetchOptions(namespace: "clock-probe", ttlSeconds: 1)
  first.comment = "Load bounded continuous-page clock fixture"
  first.purpose = "Separate cursor expiry from Business Clock"
  try #require(try await context.execute(first).records.compactMap { $0["id"]?.int64Value } == [6, 5])
  var next = first; next.offset = 2
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  try #require(try await context.execute(next).records.compactMap { $0["id"]?.int64Value } == [4, 3])
  try #require(await context.continuousPageObservation().plan == "CURSOR_SEEK")
  try await Task.sleep(for: .milliseconds(1_100))
  clock.set(Date(timeIntervalSince1970: -2_208_988_800))
  try #require(try await context.execute(next).records.compactMap { $0["id"]?.int64Value } == [4, 3])
  try #require(await context.continuousPageObservation().plan == "OFFSET_FALLBACK:CACHE_MISS")
  try emitClock("continuous-page-expiry", clock, ["boundedContextQueries": true,
    "futureBusinessPreservesSeek": true, "realExpiryFallsBack": true,
    "pastBusinessCannotReviveCursor": true])
}
