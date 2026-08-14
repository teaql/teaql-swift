import Foundation
import TeaQLCore
import Testing

@testable import TeaQLFederal

private actor RecordingTransport: FederalTransport {
  private(set) var requests: [FederalHTTPRequest] = []
  let response: FederalHTTPResponse

  init(json: String) {
    response = FederalHTTPResponse(status: 200, body: Data(json.utf8))
  }

  func send(_ request: FederalHTTPRequest) async throws -> FederalHTTPResponse {
    requests.append(request)
    return response
  }
}

@Test func queryUsesCanonicalTFPShapeWithoutTrustedContext() async throws {
  let transport = RecordingTransport(
    json: #"{"data":[{"id":7}],"resultCode":0,"status":"YES","execution":{}}"#)
  let client = TeaQLFederalClient(
    baseURL: URL(string: "https://example.test/api/")!,
    transport: transport,
    headerProvider: { ["X-TeaQL-Test-Identity": "test-operator"] }
  )
  var query = FederalQuery(entity: "CustomerOrder")
  query.filters = [.contains("orderNumber", "ORD-00")]
  query.orderBy = [OrderBy("id", .descending)]
  query.limit = 10
  query.comment = "Federated Swift order query"
  query.purpose = "Render order browser"

  let response = try await client.execute(query)
  #expect(response.data == [["id": .int(7)]])
  let request = try #require(await transport.requests.first)
  #expect(request.url.absoluteString == "https://example.test/api/query")
  #expect(request.headers["X-TeaQL-Test-Identity"] == "test-operator")
  let payload = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
  #expect(payload["entity"] as? String == "CustomerOrder")
  #expect(payload["_limit"] as? Int == 10)
  #expect(payload["tenant"] == nil)
  #expect(payload["permissions"] == nil)
  #expect(payload["hardLimit"] == nil)
}

@Test func mutationRequiresAndSerializesAuditReason() async throws {
  let transport = RecordingTransport(
    json: #"{"affectedRows":1,"data":[{"id":9}],"resultCode":0,"status":"YES"}"#)
  let client = TeaQLFederalClient(
    baseURL: URL(string: "https://example.test/")!, transport: transport)
  await #expect(throws: FederalError.missingAuditReason) {
    try await client.execute(
      FederalMutation(entity: "Task", action: .create, payload: [:], auditReason: " "))
  }
  let response = try await client.execute(
    FederalMutation(
      entity: "Task",
      action: .create,
      payload: ["name": .string("First")],
      auditReason: "Create first task"
    ))
  #expect(response.affectedRows == 1)
  let request = try #require(await transport.requests.last)
  let payload = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
  #expect(payload["comment"] as? String == "Create first task")
  #expect(payload["action"] as? String == "Create")
}

@Test func generatedRuntimeExecutorsUseFederalProtocolWithoutSendingHardLimit() async throws {
  let transport = RecordingTransport(
    json: #"{"data":[{"id":7}],"resultCode":0,"status":"YES","execution":{}}"#)
  let service = FederalDataService(
    client: TeaQLFederalClient(
      baseURL: URL(string: "https://example.test/")!,
      transport: transport
    ))
  let order = EntityDescriptor(
    name: "CustomerOrder", table: "customer_order_data",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true)
    ])
  let context = UserContext(
    queryExecutor: service,
    mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }
  )
  var query = SelectQuery(entity: order)
  query.filter = .equal("id", .int(7))
  query.limit = 1
  query.hardLimit = 2
  query.comment = "Generated request adapter test"
  query.purpose = "Verify transparent federation"

  let result = try await context.execute(query)
  #expect(result.backend == "teaql-federal")
  #expect(result.records == [["id": .int(7)]])
  let request = try #require(await transport.requests.first)
  let payload = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
  #expect(payload["_limit"] as? Int == 1)
  #expect(payload["hardLimit"] == nil)
}
