import Foundation
import Testing
@testable import TeaQLCore

private struct StubHTTPTransport: HTTPTransport {
  let status: Int
  func send(method: String, url: URL, body: Data?) async throws -> (Data, Int) {
    (Data("\(method):\(url.host ?? "")".utf8), status)
  }
}

private struct UnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ query: SelectQuery) async throws -> QueryResult { throw TeaQLError.execution("unused") }
  func execute(_ mutation: Mutation) async throws -> MutationResult { throw TeaQLError.execution("unused") }
}

private func toolContext() -> UserContext {
  UserContext(queryExecutor: UnusedExecutor(), mutationExecutor: UnusedExecutor(),
              requestPolicy: RequestPolicy { $0 })
}

@Test func contextToolPolicyAndNativeResponse() async throws {
  let context = toolContext()
  let tools = ContextTools.builder(context)
    .policy(.allowing(httpTool)).http(transport: StubHTTPTransport(status: 200)).build()
  let value: String = try await tools.get(httpTool).get("https://example.com")
    .purpose("read status").execute()
  #expect(value == "GET:example.com")
}

@Test func contextToolNegativesRemainExplicit() async throws {
  let context = toolContext()
  let denied = ContextTools.builder(context).http(transport: StubHTTPTransport(status: 200)).build()
  #expect(throws: ToolError.denied("http")) { try denied.get(httpTool) }
  #expect(throws: ToolError.unavailable("unknown")) { try denied.requireUnknown("unknown") }

  let allowed = ContextTools.builder(context)
    .policy(.allowing(httpTool)).http(transport: StubHTTPTransport(status: 200)).build()
  await #expect(throws: ToolError.blankIntent) {
    try await allowed.get(httpTool).get("https://example.com").purpose(" ").execute()
  }
  let failing = ContextTools.builder(context)
    .policy(.allowing(httpTool)).http(transport: StubHTTPTransport(status: 503)).build()
  await #expect(throws: ToolError.httpStatus(503)) {
    try await failing.get(httpTool).get("https://example.com").auditAs("health check").execute()
  }
}
