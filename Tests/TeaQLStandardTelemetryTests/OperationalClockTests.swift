import Foundation
import TeaQLCore
import XCTest
@testable import TeaQLStandardTelemetry

private final class TelemetryBusinessClock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var reads: Int { lock.withLock { calls } }
  func now() -> Date { lock.withLock { calls += 1; return Date(timeIntervalSince1970: 4_102_444_800) } }
}
private struct NoTelemetryClockIO: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw TeaQLError.execution("unexpected query") }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw TeaQLError.execution("unexpected mutation") }
}

final class OperationalClockTests: XCTestCase {
  private func calibrate() -> TelemetryBusinessClock {
    let clock = TelemetryBusinessClock()
    let context = UserContext(queryExecutor: NoTelemetryClockIO(), mutationExecutor: NoTelemetryClockIO(),
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry(), businessClock: clock)
    XCTAssertEqual(context.businessTime, Date(timeIntervalSince1970: 4_102_444_800))
    XCTAssertEqual(clock.reads, 1)
    return clock
  }
  private func emit(_ name: String, _ clock: TelemetryBusinessClock, facts: [String: Bool]) throws {
    XCTAssertEqual(clock.reads, 1)
    let value: [String: Any] = ["case": name, "passed": true, "calibrationCalls": 1,
      "additionalBusinessReads": clock.reads - 1, "realTime": true, "facts": facts]
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print("SWIFT_OPERATIONAL_CLOCK_CASE=" + String(decoding: data, as: UTF8.self))
  }
  func testOperationalClockPrefixWaitUsesFiniteOperationalDeadline() throws {
    let clock = calibrate(), losses = ExportLosses()
    let queue = QueueAdmission(signal: "logs", losses: losses, capacity: 2)
    XCTAssertTrue(queue.submit("held") { true })
    let prefix = queue.prefix, start = ContinuousClock.now
    XCTAssertFalse(queue.wait(prefix: prefix, timeout: 0.025))
    XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(10))
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    XCTAssertEqual(queue.outstanding, 1)
    queue.complete(queue.beginExport(["held"]))
    XCTAssertTrue(queue.wait(prefix: prefix, timeout: 0)); XCTAssertEqual(queue.outstanding, 0)
    XCTAssertTrue(losses.reasons.isEmpty)
    try emit("telemetry-prefix-wait", clock, facts: ["finiteTimeout": true,
      "timeoutDoesNotConsumeAdmission": true, "completionPreserved": true])
  }
  func testOperationalClockAsyncObserverUsesDispatchDeadline() async throws {
    let clock = calibrate(), losses = ExportLosses()
    let queue = QueueAdmission(signal: "logs", losses: losses, capacity: 2)
    XCTAssertTrue(queue.submit("held") { true })
    let start = ContinuousClock.now
    let settled = await withCheckedContinuation { continuation in
      queue.observe(prefix: queue.prefix, timeout: 0.025) { continuation.resume(returning: $0) }
    }
    XCTAssertFalse(settled)
    XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(10))
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    XCTAssertEqual(queue.outstanding, 1)
    queue.complete(queue.beginExport(["held"]))
    let complete = await withCheckedContinuation { continuation in
      queue.observe(prefix: queue.prefix, timeout: 0.025) { continuation.resume(returning: $0) }
    }
    XCTAssertTrue(complete); XCTAssertTrue(losses.reasons.isEmpty)
    try emit("telemetry-async-deadline", clock, facts: ["finiteTimeout": true,
      "timeoutDoesNotConsumeAdmission": true, "completionPreserved": true])
  }
}
