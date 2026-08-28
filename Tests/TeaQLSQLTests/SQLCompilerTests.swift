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

@Test func countCompilerUsesOnlyTheSameFilter() throws {
  let entity = EntityDescriptor(
    name: "Order", table: "orders",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "status", type: .string),
    ])
  var query = SelectQuery(entity: entity)
  query.filter = .equal("status", .string("ACTIVE"))
  query.orderBy = [OrderBy("id", .ascending)]
  query.offset = 20
  query.limit = 10
  query.comment = "Count active orders"
  query.purpose = "Render an exact page total"
  let compiled = try SQLiteCompiler().compileCount(query)
  #expect(compiled.sql == "SELECT COUNT(*) FROM \"orders\" WHERE \"status\" = ?")
  #expect(compiled.parameters == [.string("ACTIVE")])
}

@Test func sqliteCompilesProviderRegisteredSoundingLike() throws {
  let entity = EntityDescriptor(
    name: "School", table: "school_data",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "name", type: .string),
    ])
  var query = SelectQuery(entity: entity)
  query.filter = .soundingLike("name", "Robert")
  query.comment = "Test provider-aware phonetic predicate"
  query.purpose = "Execute registered SQLite SoundingLike"
  let compiled = try SQLiteCompiler().compile(query)
  #expect(compiled.sql.contains("SOUNDEX(\"name\") = SOUNDEX(?)"))
  #expect(compiled.parameters == [.string("Robert")])
}

@Test func debugSQLRendersCopyPasteStatement() {
  let compiled = CompiledSQL(
    sql: "SELECT * FROM school WHERE name = ? AND active = ? AND phone IS ? AND note = '?'",
    parameters: [.string("O'Brien School"), .bool(true), .null]
  )
  #expect(
    compiled.debugSQL()
      == "SELECT * FROM school WHERE name = 'O''Brien School' AND active = TRUE AND phone IS NULL AND note = '?'"
  )
}

@Test func debugSQLPreservesCommentsAndTemporalStorageLiterals() {
  let compiled = CompiledSQL(
    sql: "-- line ? $1\nSELECT '?', \"identifier?\", ?, ? /* block ? */",
    parameters: [.calendarDate("2024-02-29"), .timestamp(1_787_110_200_123)]
  )
  #expect(
    compiled.debugSQL()
      == "-- line ? $1\nSELECT '?', \"identifier?\", '2024-02-29', 1787110200123 /* block ? */"
  )
}
