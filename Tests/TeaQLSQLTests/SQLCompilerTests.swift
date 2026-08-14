import TeaQLCore
import Testing

@testable import TeaQLSQL

@Test func compilerBindsValuesAndAppliesDefaultHardLimit() throws {
  let entity = EntityDescriptor(
    name: "Order", table: "orders",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "orderNumber", column: "order_number", type: .string),
    ])
  var query = SelectQuery(entity: entity)
  query.filter = .contains("orderNumber", "A-10")
  query.orderBy = [OrderBy("id", .descending)]
  query.comment = "Search orders"
  query.purpose = "Render order browser"
  let compiled = try SQLiteCompiler().compile(query)
  #expect(
    compiled.sql
      == "SELECT \"id\", \"order_number\" FROM \"orders\" WHERE \"order_number\" LIKE ? ORDER BY \"id\" DESC LIMIT ?"
  )
  #expect(compiled.parameters == [.string("%A-10%"), .int(10_000)])
}
