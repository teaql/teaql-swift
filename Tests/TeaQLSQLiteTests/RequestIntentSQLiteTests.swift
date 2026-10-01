import XCTest
import TeaQLCore
import TeaQLSQLite

final class RequestIntentSQLiteTests: XCTestCase {
  func testDirectProviderRejectsMissingIntentWithoutSchemaOrStatementExecution() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let entity = EntityDescriptor(name: "AbsentTable", table: "absent_table",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    let query = SelectQuery(entity: entity)
    do { _ = try await provider.execute(query); XCTFail("query reached absent table") }
    catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.field, "comment")
    }
    do { _ = try await provider.count(query); XCTFail("count reached absent table") }
    catch let error as RequestIntentError { XCTAssertEqual(error.field, "comment") }
    do { _ = try await provider.execute(Mutation(kind: .create, entity: entity)); XCTFail("mutation reached absent table") }
    catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.requestKind, "mutation")
    }
    try await provider.beginGraphTransaction()
    do {
      do { _ = try await provider.execute(Mutation(kind: .update, entity: entity)); XCTFail("transaction bypassed gate") }
      catch let error as RequestIntentError { XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED") }
      try await provider.rollbackGraphTransaction()
    } catch {
      try? await provider.rollbackGraphTransaction()
      throw error
    }
  }
}
