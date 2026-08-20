import Foundation
import TeaQLCore
import Testing

@testable import TeaQLFederal

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Test func liveSwiftToRustTFPQueryAndAuditedMutation() async throws {
  guard let rawURL = ProcessInfo.processInfo.environment["TEAQL_TFP_BASE_URL"],
    let url = URL(string: rawURL)
  else { return }
  let client = TeaQLFederalClient(baseURL: url)

  var query = FederalQuery(entity: "CustomerOrder")
  query.filters = [.contains("orderNumber", "ORD-00")]
  query.orderBy = [OrderBy("orderNumber", .ascending), OrderBy("id", .ascending)]
  query.select = ["id"]
  query.limit = 10
  query.comment = "Federated generated Swift order query"
  query.purpose = "Request tenant order search"
  let result = try await client.execute(query)
  #expect(result.data.compactMap { $0["id"]?.int64Value } == [7])

  let mutation = FederalMutation(
    entity: "CustomerOrder",
    action: .update,
    payload: [
      "status": .string("PAID")
    ],
    id: .int(42),
    expectedVersion: 3,
    auditReason: "Verify Swift audited federation mutation"
  )
  let mutationResult = try await client.execute(mutation)
  #expect(mutationResult.affectedRows == 1)
}
