import XCTest
@testable import TeaQLCore

private struct CreatedEntity: TeaQLEntity {
  static let descriptor = EntityDescriptor(name: "CreatedEntity", table: "created", properties: [])
  var id: Int64 = 0
  var version: Int64 = 0
  var tenant = ""
  static func from(record: TeaQLRecord) throws -> Self { Self() }
  func toRecord() -> TeaQLRecord { [:] }
}

final class ContextEntityCreationTests: XCTestCase {
  func testTrustedInitializerPreservesConcreteType() {
    let context = UserContext(
      queryExecutor: RejectingCreationExecutor(), mutationExecutor: RejectingCreationExecutor(),
      requestPolicy: RequestPolicy { $0 },
      entityInitializers: [{ _, name, entity in
        guard name == "CreatedEntity", var created = entity as? CreatedEntity else { return }
        created.tenant = "trusted"
        entity = created
      }])
    XCTAssertEqual(context.initializeEntity("CreatedEntity", CreatedEntity()).tenant, "trusted")
  }
}

private struct RejectingCreationExecutor: QueryExecutor, MutationExecutor {
  func execute(_ query: SelectQuery) async throws -> QueryResult {
    throw TeaQLError.execution("not used")
  }
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    throw TeaQLError.execution("not used")
  }
}
