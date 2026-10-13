import Foundation

public struct TelemetryStartupConfiguration: Sendable, Equatable {
  public static let enabledVariable = "TEAQL_TELEMETRY_ENABLED"
  public static let serviceVariable = "TEAQL_TELEMETRY_SERVICE_NAME"
  public static let endpointVariable = "TEAQL_TELEMETRY_OTLP_ENDPOINT"
  public static let hints = "TEAQL_TELEMETRY_ENABLED=true TEAQL_TELEMETRY_SERVICE_NAME=<application-name> TEAQL_TELEMETRY_OTLP_ENDPOINT=<collector-url>"
  public let enabled: Bool
  public let serviceName: String
  public let endpoint: String
  public let errorCode: String

  private init(enabled: Bool = false, serviceName: String = "", endpoint: String = "", errorCode: String = "") {
    self.enabled = enabled; self.serviceName = serviceName; self.endpoint = endpoint; self.errorCode = errorCode
  }
  public static func read(_ environment: [String: String]) -> Self {
    let flag = environment[enabledVariable, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if flag.isEmpty || flag == "false" { return Self() }
    if flag != "true" { return Self(errorCode: "invalid-enable") }
    let service = environment[serviceVariable, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    guard service.range(of: #"\A[a-zA-Z0-9_.-]{1,120}\z"#, options: .regularExpression) != nil else { return Self(errorCode: "invalid-service") }
    let endpoint = environment[endpointVariable, default: ""]
    guard !endpoint.contains("?"), !endpoint.contains("#"), !endpoint.contains("@"),
      !endpoint.contains(where: { $0.isWhitespace }),
      let components = URLComponents(string: endpoint),
      components.scheme == "http" || components.scheme == "https",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.url != nil
    else { return Self(errorCode: "invalid-endpoint") }
    return Self(enabled: true, serviceName: service, endpoint: endpoint.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression))
  }
  public var message: String {
    if !errorCode.isEmpty { return "TeaQL telemetry: disabled; configuration=\(errorCode). \(Self.hints)" }
    if !enabled { return "TeaQL telemetry: supported, disabled. Enable full masked diagnostics with \(Self.hints)" }
    return "TeaQL telemetry: starting standard module; full recording, masked SQL; \(Self.enabledVariable)=true \(Self.serviceVariable)=\(serviceName) \(Self.endpointVariable)=\(endpoint)"
  }
}

public protocol StandardTelemetryLifecycle: Sendable { var isShutdown: Bool { get } }
public enum RuntimeTelemetryStartup {
  public typealias Factory = @Sendable (TelemetryStartupConfiguration) throws -> any RuntimeTelemetry
  private final class State: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var factory: Factory?
    var announced: Set<String> = []
    var pipelines: [String: Initialization] = [:]
  }
  private final class Initialization: @unchecked Sendable {
    private let condition = NSCondition()
    private var pipeline: (any RuntimeTelemetry)?
    private var finished = false
    private var abandoned = false
    private var announced = false

    var reusable: Bool {
      condition.withLock {
        !abandoned && (!finished || (pipeline != nil &&
          (pipeline as? any StandardTelemetryLifecycle)?.isShutdown != true))
      }
    }

    func complete(_ result: (any RuntimeTelemetry)?) {
      let discard = condition.withLock {
        finished = true
        if !abandoned { pipeline = result }
        condition.broadcast()
        return abandoned
      }
      // An initializer that finishes after the startup deadline must not leak
      // its owned SDK, nor publish it into a newer context's pipeline.
      if discard, let result { Task { await result.shutdown() } }
    }

    func awaitResult() -> any RuntimeTelemetry {
      let deadline = Date(timeIntervalSinceNow: 5)
      condition.lock()
      while !finished && !abandoned {
        if !condition.wait(until: deadline), !finished { abandoned = true }
      }
      let result = abandoned ? nil : pipeline
      let message: String
      if abandoned { message = "TeaQL telemetry: initialization timed out; business continues without export." }
      else if result == nil { message = "TeaQL telemetry: initialization failed; business continues without export." }
      else { message = "TeaQL telemetry: enabled; full recording, traces, metrics, logs and masked SQL." }
      let shouldAnnounce = !announced
      announced = true
      condition.unlock()
      if shouldAnnounce { RuntimeTelemetryStartup.notice(message) }
      return result ?? NoopRuntimeTelemetry()
    }
  }
  private static let state = State()
  public static func register(_ factory: @escaping Factory) { state.lock.withLock { state.factory = factory } }
  public static func notice(_ safeMessage: String) {
    if let data = (safeMessage + "\n").data(using: .utf8) { try? FileHandle.standardError.write(contentsOf: data) }
  }
  public static func defaultTelemetry(environment: [String: String] = ProcessInfo.processInfo.environment) -> any RuntimeTelemetry {
    let config = TelemetryStartupConfiguration.read(environment)
    let initialization: Initialization? = state.lock.withLock {
      if state.announced.insert(config.message).inserted { notice(config.message) }
      guard config.enabled else { return nil }
      let key = config.serviceName + "\u{0}" + config.endpoint
      if let initialization = state.pipelines[key], initialization.reusable {
        return initialization
      }
      guard let factory = state.factory else {
        let message = "TeaQL telemetry: standard module unavailable; register TeaQLStandardTelemetry at application assembly. " + TelemetryStartupConfiguration.hints
        if state.announced.insert(message).inserted { notice(message) }
        return nil
      }
      let initialization = Initialization()
      state.pipelines[key] = initialization
      DispatchQueue.global().async {
        initialization.complete(try? factory(config))
      }
      return initialization
    }
    return initialization?.awaitResult() ?? NoopRuntimeTelemetry()
  }
}

