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

private final class RecordingRuntimeTelemetry: RuntimeTelemetry, @unchecked Sendable {
  struct Event: Sendable, Equatable {
    let operation: RuntimeOperation
    let outcome: String
  }
  private let lock = NSLock()
  private var storedEvents: [Event] = []
  var events: [Event] { lock.withLock { storedEvents } }
  var injectedTraceparent: String?

  func inject(_ carrier: inout [String: String]) {
    if let injectedTraceparent { carrier["traceparent"] = injectedTraceparent }
  }

  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    do {
      let result = try await body()
      lock.withLock { storedEvents.append(Event(operation: operation, outcome: "success")) }
      return result
    } catch {
      lock.withLock { storedEvents.append(Event(operation: operation, outcome: "failure")) }
      throw error
    }
  }

  func withSynchronousOperation<Result>(
    _ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result
  ) rethrows -> Result {
    try body()
  }

  func flush() async {}
  func shutdown() async {}
}

private struct FailingTransport: FederalTransport {
  let error: FederalError
  func send(_ request: FederalHTTPRequest) async throws -> FederalHTTPResponse { throw error }
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
  #expect(payload["limitValue"] as? Int == 10)
  #expect(payload["filterCondition"] != nil)
  #expect(payload["commentText"] as? String == "Federated Swift order query")
  #expect(payload["purposeText"] as? String == "Render order browser")
  #expect(payload["_limit"] == nil)
  #expect(payload["_filters"] == nil)
  #expect(payload["tenant"] == nil)
  #expect(payload["permissions"] == nil)
  #expect(payload["hardLimit"] == nil)
}

@Test func tfpClientInjectsTraceMetadataWithoutSerializingIt() async throws {
  let transport = RecordingTransport(
    json: #"{"data":[],"resultCode":0,"status":"YES","execution":{}}"#)
  let telemetry = RecordingRuntimeTelemetry()
  telemetry.injectedTraceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  let client = TeaQLFederalClient(
    baseURL: URL(string: "https://example.test/api/")!,
    transport: transport, runtimeTelemetry: telemetry)
  var query = FederalQuery(entity: "School")
  query.comment = "list schools"
  query.purpose = "verify trace propagation"

  _ = try await client.execute(query)

  let request = try #require(await transport.requests.first)
  #expect(request.headers["traceparent"] == telemetry.injectedTraceparent)
  #expect(!String(decoding: request.body, as: UTF8.self).contains("traceparent"))
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
  #expect(payload["limitValue"] as? Int == 1)
  #expect(payload["hardLimit"] == nil)
}

@Test func IDSET_015_federationPayloadCannotInjectRetentionControls() async throws {
  let transport = RecordingTransport(
    json: #"{"data":[{"id":7}],"resultCode":0,"status":"YES","execution":{}}"#)
  let service = FederalDataService(
    client: TeaQLFederalClient(
      baseURL: URL(string: "https://example.test/")!, transport: transport))
  let entity = EntityDescriptor(
    name: "CustomerOrder", table: "customer_order_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
  var query = SelectQuery(entity: entity)
  query.limit = 1
  query.idSetPagination = IdSetPaginationOptions(
    namespace: "must-remain-local", ttlSeconds: 99_999, maxIds: 9_999_999)
  query.comment = "verify local retention boundary"
  query.purpose = "prevent TFP retention injection"
  _ = try await service.execute(query)
  let request = try #require(await transport.requests.first)
  let payload = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
  #expect(payload["idSetPagination"] == nil)
  #expect(payload["namespace"] == nil)
  #expect(payload["ttlSeconds"] == nil)
  #expect(payload["maxIds"] == nil)
}

@Test func federalClientRecordsBalancedTFPLifecyclesAndRethrowsTransportFailure() async throws {
  let telemetry = RecordingRuntimeTelemetry()
  let transport = RecordingTransport(
    json: #"{"data":[{"id":7}],"resultCode":0,"status":"YES","execution":{}}"#)
  let client = TeaQLFederalClient(
    baseURL: URL(string: "https://example.test/")!,
    transport: transport,
    runtimeTelemetry: telemetry)
  var query = FederalQuery(entity: "CustomerOrder")
  query.comment = "Telemetry query"
  query.purpose = "Verify TFP lifecycle"

  _ = try await client.execute(query)
  let success = try #require(telemetry.events.first)
  #expect(success.operation.family == "tfp")
  #expect(success.operation.name == "client.query")
  #expect(success.operation.attributes["teaql.tfp.role"] == .string("client"))
  #expect(success.outcome == "success")

  let mutationTransport = RecordingTransport(
    json: #"{"affectedRows":1,"data":[{"id":9}],"resultCode":0,"status":"YES"}"#)
  let mutationClient = TeaQLFederalClient(
    baseURL: URL(string: "https://example.test/")!,
    transport: mutationTransport,
    runtimeTelemetry: telemetry)
  _ = try await mutationClient.execute(FederalMutation(
    entity: "Task", action: .create, payload: [:], auditReason: "Telemetry mutation"))
  let mutation = try #require(telemetry.events.last)
  #expect(mutation.operation.name == "client.mutation")
  #expect(mutation.operation.attributes["teaql.tfp.role"] == .string("client"))
  #expect(mutation.outcome == "success")

  let original = FederalError.transport(status: 503, message: "unavailable")
  let failing = TeaQLFederalClient(
    baseURL: URL(string: "https://example.test/")!,
    transport: FailingTransport(error: original),
    runtimeTelemetry: telemetry)
  await #expect(throws: original) { try await failing.execute(query) }
  let failure = try #require(telemetry.events.last)
  #expect(failure.operation.name == "client.query")
  #expect(failure.outcome == "failure")
}
