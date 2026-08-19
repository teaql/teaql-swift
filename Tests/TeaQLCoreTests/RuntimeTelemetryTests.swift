import XCTest
@testable import TeaQLCore

final class RuntimeTelemetryTests: XCTestCase {
  func testErrorCategoryUsesTypeName() {
    XCTAssertEqual(runtimeErrorCategory("DatabaseTimeoutError"), "timeout")
    XCTAssertEqual(runtimeErrorCategory("PermissionError"), "authorization")
    XCTAssertEqual(runtimeErrorCategory("UnknownTeaQLError"), "internal")
  }

  func testOperationDropsSensitiveAttributesAndNoopReturnsBodyValue() async throws {
    let operation = RuntimeOperation(
      family: "query", name: "School.list",
      attributes: [
        "teaql.entity.type": .string("School"),
        "teaql.entity.id": .integer(42),
        "teaql.audit.reason": .string("secret"),
      ])

    XCTAssertEqual(operation.attributes["teaql.entity.type"], .string("School"))
    XCTAssertNil(operation.attributes["teaql.entity.id"])
    XCTAssertNil(operation.attributes["teaql.audit.reason"])
    let result = try await NoopRuntimeTelemetry().withOperation(operation) { 7 }
    XCTAssertEqual(result, 7)
  }

  func testContextEmitsProviderAndSafeCompletionSemantics() async throws {
    let telemetry = RecordingTelemetry()
    let entity = EntityDescriptor(
      name: "School", table: "school",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    let context = UserContext(
      queryExecutor: StubExecutor(), mutationExecutor: StubExecutor(),
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: telemetry)
    var query = SelectQuery(entity: entity)
    query.comment = "list schools"
    query.purpose = "verify telemetry"

    _ = try await context.execute(query)
    _ = try await context.execute(Mutation(
      kind: .create, entity: entity, values: [:], auditReason: "create school"))

    let events = telemetry.events
    XCTAssertEqual(events.map(\.operation.family), ["provider", "query", "provider", "mutation"])
    XCTAssertEqual(
      events[0].operation.attributes["teaql.provider.operation"], .string("query"))
    XCTAssertEqual(events[1].completion["teaql.result.cardinality"], .integer(2))
    XCTAssertEqual(events[2].operation.attributes["teaql.provider.operation"], .string("create"))
    XCTAssertEqual(events[3].operation.attributes["teaql.mutation.kind"], .string("create"))
  }
}

private struct StubExecutor: QueryExecutor, MutationExecutor {
  func execute(_ query: SelectQuery) async throws -> QueryResult {
    QueryResult(records: [["id": .int(1)], ["id": .int(2)]], backend: "stub")
  }

  func execute(_ mutation: Mutation) async throws -> MutationResult {
    MutationResult(affectedRows: 1)
  }
}

private final class RecordingTelemetry: RuntimeTelemetry, @unchecked Sendable {
  struct Event {
    let operation: RuntimeOperation
    let completion: [String: RuntimeTelemetryValue]
  }
  private let lock = NSLock()
  private var stored: [Event] = []
  var events: [Event] { lock.withLock { stored } }

  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    let result = try await body()
    lock.withLock { stored.append(Event(operation: operation, completion: completion(result))) }
    return result
  }

  func withSynchronousOperation<Result>(
    _ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result
  ) rethrows -> Result {
    let result = try body()
    lock.withLock { stored.append(Event(operation: operation, completion: completion(result))) }
    return result
  }

  func flush() async {}
  func shutdown() async {}
}
