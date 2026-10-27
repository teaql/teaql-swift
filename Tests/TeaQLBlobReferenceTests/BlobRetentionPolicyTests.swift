import Crypto
import Foundation
import TeaQLBlobReference
import TeaQLCore
import Testing

@Test
func swiftSharedBlobRetentionVectorsKeepExactBytesAndDeadlines() throws {
  let url = try #require(Bundle.module.url(forResource: "blob-policy-cases",
    withExtension: "json", subdirectory: "fixtures"))
  let data = try Data(contentsOf: url)
  let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  #expect(hash == "b93cff3f8dabd5690aac5f8f2096633dcd4e158d3aa0424b9a902a16f6d3c2b6")
  let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let cases = try #require(root["cases"] as? [[String: Any]])
  func vector(_ id: String) throws -> [String: Any] {
    try #require(cases.first { $0["id"] as? String == id })
  }
  let maximum = try vector("maximum-retention-across-fields")
  let maxInput = try #require(maximum["input"] as? [String: Any])
  let accepted = try #require(maxInput["acceptedRetentionSeconds"] as? [Int64])
  let seconds = try BlobRetentionPolicy.effectiveRetention(accepted, proposed: 0)
  #expect(seconds == 2_592_000)
  #expect(try BlobRetentionPolicy.unreferencedEligibleAt(100_000, seconds: seconds,
    floorUntilMs: 3_000_000_000) == 3_000_000_000)
  let expired = try vector("unbound-deadline-rejects-bind-before-gc")
  let expiredInput = try #require(expired["input"] as? [String: Any])
  do {
    try BlobRetentionPolicy.requireBindable(status: "uploaded_unbound",
      nowMs: (try #require(expiredInput["nowSeconds"] as? Int64)) * 1000,
      completedMs: (try #require(expiredInput["completedAtSeconds"] as? Int64)) * 1000,
      unboundSeconds: try #require(expiredInput["unboundRetentionSeconds"] as? Int64),
      unreferencedEligibleMs: nil)
    Issue.record("expired reference was bindable")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_REFERENCE_EXPIRED")) }
  #expect(try BlobRetentionPolicy.effectiveRetention([2_592_000], proposed: 3600) == 2_592_000)
}
