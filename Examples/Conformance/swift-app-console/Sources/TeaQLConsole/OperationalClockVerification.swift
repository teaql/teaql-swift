import Foundation
import TeaQLCore

private final class ExampleBusinessClock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 4_102_444_800)
  private var calls = 0
  var reads: Int { lock.withLock { calls } }
  func now() -> Date { lock.withLock { calls += 1; return value } }
  func set(_ value: Date) { lock.withLock { self.value = value } }
}
private struct NoOperationalIO: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw TeaQLError.execution("unexpected example query") }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw TeaQLError.execution("unexpected example mutation") }
}

func verifyOperationalClock() async throws {
  let clock = ExampleBusinessClock(), cache = LocalCache()
  let context = UserContext(queryExecutor: NoOperationalIO(), mutationExecutor: NoOperationalIO(),
    requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry(), businessClock: clock)
  try require(context.businessTime == Date(timeIntervalSince1970: 4_102_444_800), "business clock calibration")
  try require(clock.reads == 1, "calibrate exactly one Business Clock read")
  cache.put("finite", value: "live", timeToLiveInSeconds: 1)
  cache.put("zero", value: 0, timeToLiveInSeconds: 0)
  cache.put("false", value: false); cache.put("empty", value: "")
  cache.put("null", value: TeaQLValue.null)
  clock.set(Date(timeIntervalSince1970: 7_226_755_200))
  try require(cache.get("finite", as: String.self) == "live", "business future cannot expire a live cache entry")
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while cache.get("finite", as: String.self) != nil, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  try require(cache.get("finite", as: String.self) == nil, "real operational TTL must expire")
  clock.set(Date(timeIntervalSince1970: -2_208_988_800))
  try require(cache.get("finite", as: String.self) == nil, "business past cannot revive an expired entry")
  try require(cache.get("zero", as: Int.self) == 0 && cache.get("false", as: Bool.self) == false,
    "zero/false values and zero/omitted TTL must remain")
  try require(cache.get("empty", as: String.self) == "" && cache.get("null", as: TeaQLValue.self) == .null,
    "empty and typed-null cache values must remain")
  try require(clock.reads == 1, "operational cache must not consume Business Clock")
  let value: [String: Any] = ["passed": true, "calibrationCalls": 1, "additionalBusinessReads": 0,
    "facts": ["futureBusinessDoesNotExpire": true, "realExpiry": true, "businessPastCannotRevive": true,
      "zeroAndOmittedTtlRemain": true, "zeroFalseEmptyNullRemainValues": true]]
  let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  print("SWIFT_OPERATIONAL_CLOCK_EXAMPLE=" + String(decoding: data, as: UTF8.self))
}
