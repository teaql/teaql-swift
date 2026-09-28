import TeaQLCore
import TeaQLSQL
import Testing

@Test func compilerCarriesCanonicalMaskPolicyThroughListsAndNestedQueries() throws {
  let entity = EntityDescriptor(name: "Customer", table: "customer", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "displayName", modelName: "display_name", column: "legal_name", type: .string),
    PropertyDescriptor(name: "status", type: .string),
    PropertyDescriptor(name: "password", type: .string),
  ], auditMaskFields: ["display_name"])
  var query = SelectQuery(entity: entity)
  query.comment = "what: combine policies"; query.purpose = "why: retain provenance"; query.limit = 10
  query.filter = .and([
    .contains("displayName", "Riverside"), .inList("status", [.string("A"), .string("B")]),
    .equal("password", .string("PASSWORD-CANARY")), .between("id", .int(1), .int(2))
  ])
  let compiled = try SQLiteCompiler().compile(query)
  #expect(compiled.generatedSQL)
  #expect(compiled.parameterLogPolicies == [.masked, .plain, .plain, .credential, .plain, .plain, .plain])
  #expect(compiled.parameters[0] == .string("%Riverside%"))
  #expect(try SQLiteCompiler().compileCount(query).parameterLogPolicies == Array(compiled.parameterLogPolicies.dropLast()))
  let childEntity = EntityDescriptor(name: "Other", table: "other", properties: entity.properties)
  var child = SelectQuery(entity: childEntity)
  child.filter = .equal("displayName", .string("Public"))
  child.comment = query.comment; child.purpose = query.purpose
  query.filter = .and([.equal("displayName", .string("Private")),
    .inSubquery("id", RelationQueryPlan(child), "id"), .equal("status", .string("Visible"))])
  let nested = try SQLiteCompiler().compile(query)
  #expect(nested.parameterLogPolicies == [.masked, .unknown, .plain, .plain])
}

@Test func legacyDescriptorWithoutMaskMetadataFailsClosed() throws {
  let properties = [
    PropertyDescriptor(name: "displayName", modelName: "display_name", type: .string),
    PropertyDescriptor(name: "password", type: .string),
  ]
  let legacy = EntityDescriptor(name: "Customer", table: "customer", properties: properties)
  #expect(legacy.auditMaskFields == nil)
  var query = SelectQuery(entity: legacy)
  query.filter = .and([
    .equal("displayName", .string("CUSTOMER-CANARY")),
    .equal("password", .string("PASSWORD-CANARY")),
  ])
  query.limit = 1; query.comment = "what: legacy metadata"; query.purpose = "why: avoid log disclosure"
  let compiled = try SQLiteCompiler().compile(query)
  #expect(compiled.parameterLogPolicies == [.unknown, .credential, .plain])
  #expect(compiled.parameters[0] == .string("CUSTOMER-CANARY"))

  let explicitEmpty = EntityDescriptor(name: "Customer", table: "customer", properties: properties,
    auditMaskFields: [])
  #expect(explicitEmpty.auditMaskFields == [])
  query = SelectQuery(entity: explicitEmpty)
  query.filter = .equal("displayName", .string("CUSTOMER-CANARY"))
  query.limit = 1; query.comment = "what: explicit policy"; query.purpose = "why: allow ordinary diagnostic"
  #expect(try SQLiteCompiler().compile(query).parameterLogPolicies == [.plain, .plain])
}
