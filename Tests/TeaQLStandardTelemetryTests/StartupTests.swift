import TeaQLCore
import Foundation
import XCTest
@testable import TeaQLStandardTelemetry

final class StartupTests: XCTestCase {
  private func environment(_ name: String = UUID().uuidString) -> [String: String] {
    [TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: name,
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318"]
  }

  func testDisabledAndInvalidSettingsNeverConstructSDK() {
    let calls = FactoryCalls()
    RuntimeTelemetryStartup.register { _ in calls.create() }
    XCTAssertTrue(RuntimeTelemetryStartup.defaultTelemetry(environment: [:]) is NoopRuntimeTelemetry)
    XCTAssertTrue(RuntimeTelemetryStartup.defaultTelemetry(environment: [
      TelemetryStartupConfiguration.enabledVariable: "not-a-boolean"]) is NoopRuntimeTelemetry)
    XCTAssertEqual(calls.count, 0)
  }

  func testConcurrentContextsInitializeExactlyOnceAndSharePipeline() {
    let calls = FactoryCalls(), results = PipelineResults(), env = environment()
    RuntimeTelemetryStartup.register { _ in calls.create() }
    DispatchQueue.concurrentPerform(iterations: 24) { _ in
      if let pipeline = RuntimeTelemetryStartup.defaultTelemetry(environment: env) as? TestPipeline {
        results.append(pipeline)
      }
    }
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(results.values.count, 24)
    XCTAssertEqual(Set(results.values.map(ObjectIdentifier.init)).count, 1)
  }

  func testClosedPipelineIsNotReused() async {
    let calls = FactoryCalls(), env = environment()
    RuntimeTelemetryStartup.register { _ in calls.create() }
    let first = RuntimeTelemetryStartup.defaultTelemetry(environment: env) as? TestPipeline
    await first?.shutdown()
    let second = RuntimeTelemetryStartup.defaultTelemetry(environment: env) as? TestPipeline
    XCTAssertNotNil(first); XCTAssertNotNil(second)
    XCTAssertFalse(first === second)
    XCTAssertEqual(calls.count, 2)
  }

  func testFailedInitializationIsFailOpenAndCanBeRetried() {
    RuntimeTelemetryStartup.register { _ in throw InitializationError.failed }
    let env = environment()
    XCTAssertTrue(RuntimeTelemetryStartup.defaultTelemetry(environment: env) is NoopRuntimeTelemetry)
    RuntimeTelemetryStartup.register { _ in TestPipeline() }
    XCTAssertTrue(RuntimeTelemetryStartup.defaultTelemetry(environment: env) is TestPipeline)
  }

  func testInitializationDeadlineDiscardsAndClosesLateSDK() async {
    let gate = DispatchSemaphore(value: 0), late = TestPipeline()
    RuntimeTelemetryStartup.register { _ in gate.wait(); return late }
    let start = ContinuousClock.now
    let result = RuntimeTelemetryStartup.defaultTelemetry(environment: environment())
    let elapsed = start.duration(to: .now)
    // Release immediately even on assertion failure; no blocked worker remains.
    gate.signal()
    XCTAssertTrue(result is NoopRuntimeTelemetry)
    XCTAssertGreaterThanOrEqual(elapsed, .seconds(4.8))
    XCTAssertLessThan(elapsed, .seconds(6))
    for _ in 0..<100 where !late.isShutdown { try? await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(late.isShutdown)
  }
  func testDisabledGuidanceNamesThreeSettingsWithoutEchoingUnusedValues() {
    let config = TelemetryStartupConfiguration.read([TelemetryStartupConfiguration.serviceVariable: "PRIVATE-SERVICE"])
    XCTAssertFalse(config.enabled)
    XCTAssertFalse(config.message.contains("PRIVATE-SERVICE"))
    for name in [TelemetryStartupConfiguration.enabledVariable, TelemetryStartupConfiguration.serviceVariable, TelemetryStartupConfiguration.endpointVariable] {
      XCTAssertTrue(config.message.contains(name))
    }
  }
  func testInvalidEndpointsDoNotEchoSecrets() {
    for endpoint in ["http://SECRET:password@localhost", "http://localhost?token=SECRET", "http://localhost?", "http://localhost/#SECRET", "file:///SECRET"] {
      let config = TelemetryStartupConfiguration.read([
        TelemetryStartupConfiguration.enabledVariable: "true", TelemetryStartupConfiguration.serviceVariable: "example", TelemetryStartupConfiguration.endpointVariable: endpoint])
      XCTAssertFalse(config.enabled); XCTAssertEqual(config.errorCode, "invalid-endpoint")
      XCTAssertFalse(config.message.contains("SECRET"))
    }
  }
  func testSafeEffectiveConfigurationShowsFullRecording() {
    let config = TelemetryStartupConfiguration.read([
      TelemetryStartupConfiguration.enabledVariable: "TRUE", TelemetryStartupConfiguration.serviceVariable: "example", TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318/"])
    XCTAssertTrue(config.enabled); XCTAssertEqual(config.endpoint, "http://localhost:4318")
    XCTAssertTrue(config.message.contains("full recording"))
  }
}

private enum InitializationError: Error { case failed }
private final class FactoryCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var created = 0
  var count: Int { lock.withLock { created } }
  func create() -> TestPipeline { lock.withLock { created += 1 }; return TestPipeline() }
}
private final class PipelineResults: @unchecked Sendable {
  private let lock = NSLock()
  private var pipelines: [TestPipeline] = []
  var values: [TestPipeline] { lock.withLock { pipelines } }
  func append(_ pipeline: TestPipeline) { lock.withLock { pipelines.append(pipeline) } }
}
private final class TestPipeline: RuntimeTelemetry, StandardTelemetryLifecycle, @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  var isShutdown: Bool { lock.withLock { closed } }
  func withOperation<Result: Sendable>(_ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result) async rethrows -> Result { try await body() }
  func withSynchronousOperation<Result>(_ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result) rethrows -> Result { try body() }
  func flush() async {}
  func shutdown() async { lock.withLock { closed = true } }
}
