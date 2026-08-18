import Foundation
import Testing
@testable import TeaQLCore

@Test func localCacheStoresRemovesAndExpiresValues() async throws {
  let cache = LocalCache()
  cache.put("persistent", value: 7)
  #expect(cache.get("persistent", as: Int.self) == 7)
  cache.remove("persistent")
  #expect(cache.get("persistent", as: Int.self) == nil)

  cache.put("temporary", value: "value", timeToLiveInSeconds: 1)
  try await Task.sleep(for: .seconds(1.1))
  #expect(cache.get("temporary", as: String.self) == nil)
}

@Test func localCacheEmitsBalancedHitMissTelemetryWithoutKeys() {
  let telemetry = CacheRecordingTelemetry()
  let cache = LocalCache(runtimeTelemetry: telemetry)
  cache.put("sensitive-key", value: 7)
  #expect(cache.get("sensitive-key", as: Int.self) == 7)
  cache.remove("sensitive-key")
  #expect(cache.get("sensitive-key", as: Int.self) == nil)
  #expect(telemetry.events.map(\.0.name) == [
    "local.put", "local.get", "local.remove", "local.get",
  ])
  #expect(telemetry.events.map { $0.1["teaql.cache.result"] } == [
    .string("stored"), .string("hit"), .string("removed"), .string("miss"),
  ])
  #expect(telemetry.events.allSatisfy { !$0.0.attributes.description.contains("sensitive-key") })
}

private final class CacheRecordingTelemetry: RuntimeTelemetry, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [(RuntimeOperation, [String: RuntimeTelemetryValue])] = []
  var events: [(RuntimeOperation, [String: RuntimeTelemetryValue])] { lock.withLock { stored } }

  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result { try await body() }

  func withSynchronousOperation<Result>(
    _ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result
  ) rethrows -> Result {
    let result = try body()
    lock.withLock { stored.append((operation, completion(result))) }
    return result
  }

  func flush() async {}
  func shutdown() async {}
}
