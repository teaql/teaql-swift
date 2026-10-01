import Testing

@testable import TeaQLCore

@Test func purposeCommentAndHardLimitFailClosed() throws {
  let entity = EntityDescriptor(
    name: "Order", table: "orders",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true)
    ])
  var query = SelectQuery(entity: entity)
  #expect(throws: RequestIntentError(code: "REQUEST_COMMENT_REQUIRED", field: "comment", requestKind: "query")) { try query.validatedForExecution() }
  query.comment = "Load orders"
  #expect(throws: RequestIntentError(code: "QUERY_PURPOSE_REQUIRED", field: "purpose", requestKind: "query")) { try query.validatedForExecution() }
  query.purpose = "Render order browser"
  query.limit = 10_001
  #expect(throws: TeaQLError.hardLimitExceeded(limit: 10_001, hardLimit: 10_000)) {
    try query.validatedForExecution()
  }
}
