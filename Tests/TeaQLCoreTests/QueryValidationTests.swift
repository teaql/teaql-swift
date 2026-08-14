import Testing

@testable import TeaQLCore

@Test func purposeCommentAndHardLimitFailClosed() throws {
  let entity = EntityDescriptor(
    name: "Order", table: "orders",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true)
    ])
  var query = SelectQuery(entity: entity)
  #expect(throws: TeaQLError.missingComment) { try query.validatedForExecution() }
  query.comment = "Load orders"
  #expect(throws: TeaQLError.missingPurpose) { try query.validatedForExecution() }
  query.purpose = "Render order browser"
  query.limit = 10_001
  #expect(throws: TeaQLError.hardLimitExceeded(limit: 10_001, hardLimit: 10_000)) {
    try query.validatedForExecution()
  }
}
