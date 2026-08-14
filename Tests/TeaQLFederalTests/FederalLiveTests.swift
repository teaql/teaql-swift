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
  let (directData, directResponse) = try await URLSession.shared.data(
    from: url.appendingPathComponent("direct"))
  #expect((directResponse as? HTTPURLResponse)?.statusCode == 200)
  let direct = try JSONDecoder().decode(FederalQueryResponse.self, from: directData)
  #expect(
    result.data.compactMap { $0["id"]?.int64Value }
      == direct.data.compactMap { $0["id"]?.int64Value })

  let mutation = FederalMutation(
    entity: "OrderSearchPreset",
    action: .update,
    payload: [
      "name": .string("Swift federation verified")
    ],
    id: .int(900_001),
    auditReason: "Verify Swift audited federation mutation"
  )
  let mutationResult = try await client.execute(mutation)
  #expect(mutationResult.affectedRows == 1)
}
