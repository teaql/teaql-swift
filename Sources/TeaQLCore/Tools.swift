import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ToolRisk: String, Sendable { case memoryOnly, externalResource, privileged }

public struct HTTPToolToken: Sendable {
  public let id = "http"
  public let risk = ToolRisk.externalResource
  public init() {}
}

public let httpTool = HTTPToolToken()

public struct ToolPolicy: Sendable {
  private let allowed: Set<String>
  private let allowMemoryOnly: Bool

  private init(allowed: Set<String>, allowMemoryOnly: Bool) {
    self.allowed = allowed
    self.allowMemoryOnly = allowMemoryOnly
  }

  public static let standard = ToolPolicy(allowed: [], allowMemoryOnly: true)
  public static let denyAll = ToolPolicy(allowed: [], allowMemoryOnly: false)
  public static func allowing(_ token: HTTPToolToken) -> ToolPolicy {
    ToolPolicy(allowed: [token.id], allowMemoryOnly: true)
  }

  func allows(id: String, risk: ToolRisk) -> Bool {
    (risk == .memoryOnly && allowMemoryOnly) || allowed.contains(id)
  }
}

public protocol HTTPTransport: Sendable {
  func send(method: String, url: URL, body: Data?) async throws -> (Data, Int)
}

public struct URLSessionHTTPTransport: HTTPTransport {
  public init() {}
  public func send(method: String, url: URL, body: Data?) async throws -> (Data, Int) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}

public struct HTTPTool: Sendable {
  fileprivate let transport: any HTTPTransport
  public func get(_ url: String) -> HTTPIntentPhase { .init(method: "GET", url: url, body: nil, transport: transport) }
  public func post<T: Encodable & Sendable>(_ url: String, body: T) throws -> HTTPIntentPhase {
    .init(method: "POST", url: url, body: try JSONEncoder().encode(body), transport: transport)
  }
}

public struct HTTPIntentPhase: Sendable {
  fileprivate let method: String
  fileprivate let url: String
  fileprivate let body: Data?
  fileprivate let transport: any HTTPTransport
  public func purpose(_ intent: String) -> ExecutableHTTPTool { executable(intent) }
  public func auditAs(_ intent: String) -> ExecutableHTTPTool { executable(intent) }
  private func executable(_ intent: String) -> ExecutableHTTPTool {
    .init(method: method, url: url, body: body, intent: intent, transport: transport)
  }
}

public struct ExecutableHTTPTool: Sendable {
  fileprivate let method: String
  fileprivate let url: String
  fileprivate let body: Data?
  fileprivate let intent: String
  fileprivate let transport: any HTTPTransport

  public func execute() async throws -> String {
    guard !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ToolError.blankIntent
    }
    guard let endpoint = URL(string: url), let scheme = endpoint.scheme,
          scheme == "http" || scheme == "https" else { throw ToolError.invalidURL(url) }
    let (data, status) = try await transport.send(method: method, url: endpoint, body: body)
    guard (200..<300).contains(status) else { throw ToolError.httpStatus(status) }
    guard let text = String(data: data, encoding: .utf8) else { throw ToolError.invalidUTF8 }
    return text
  }
}

public enum ToolError: Error, Equatable {
  case unavailable(String), denied(String), blankIntent, invalidURL(String), httpStatus(Int), invalidUTF8
}

public struct ContextTools: Sendable {
  private let policy: ToolPolicy
  private let httpTransport: (any HTTPTransport)?
  fileprivate init(policy: ToolPolicy, httpTransport: (any HTTPTransport)?) {
    self.policy = policy; self.httpTransport = httpTransport
  }
  public static func builder(_ context: UserContext) -> ContextToolsBuilder { .init(context: context) }
  public static func of(_ context: UserContext) -> ContextTools { builder(context).build() }
  public func has(_ token: HTTPToolToken) -> Bool { httpTransport != nil }
  public func get(_ token: HTTPToolToken) throws -> HTTPTool {
    guard let transport = httpTransport else { throw ToolError.unavailable(token.id) }
    guard policy.allows(id: token.id, risk: token.risk) else { throw ToolError.denied(token.id) }
    return HTTPTool(transport: transport)
  }
  public func requireUnknown(_ id: String) throws -> Never { throw ToolError.unavailable(id) }
}

public struct ContextToolsBuilder: Sendable {
  private let context: UserContext
  private var selectedPolicy = ToolPolicy.standard
  private var httpTransport: (any HTTPTransport)?
  fileprivate init(context: UserContext) { self.context = context }
  public func policy(_ policy: ToolPolicy) -> ContextToolsBuilder {
    var copy = self; copy.selectedPolicy = policy; return copy
  }
  public func http(transport: any HTTPTransport = URLSessionHTTPTransport()) -> ContextToolsBuilder {
    var copy = self; copy.httpTransport = transport; return copy
  }
  public func build() -> ContextTools {
    _ = context
    return ContextTools(policy: selectedPolicy, httpTransport: httpTransport)
  }
}
