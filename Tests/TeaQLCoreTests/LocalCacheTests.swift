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
