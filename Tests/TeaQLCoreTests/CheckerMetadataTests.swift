import Foundation
import Testing
@testable import TeaQLCore

private let metadataEntity = EntityDescriptor(name: "First", table: "checker_metadata", properties: [
  PropertyDescriptor(name: "id", type: .int, isID: true),
  PropertyDescriptor(name: "contactPhone", modelName: "contact_phone", type: .string),
])

@Test func checkerMetadataBindsOnlyMissingDeclaringTypesBeforeProvider() async throws {
  let suppliedTypes: [String?] = [nil, "", " \t", "ReviewedItem"]
  for supplied in suppliedTypes {
    let original = CheckResult(ruleID: "required",
      location: .property("order_item_list").index(2).property("product_name"),
      systemValue: "required", entityType: supplied,
      sourceInstancePath: "/old~1items/2/product~0name")
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "metadata", entities: [metadataEntity],
      checkers: [metadataEntity.name: MetadataChecker(results: [original])]))
    let provider = MetadataProvider()
    var context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 })
    for locale in [TeaQLLocale.en, .zhCN, .en] {
      try context.setLocaleCode(locale.rawValue)
      do {
        _ = try await context.execute(Mutation(kind: .create, entity: metadataEntity,
          values: ["contact_phone": .string("synthetic")], auditReason: "Verify declaring Checker identity"))
        Issue.record("Invalid Checker result reached the provider")
      } catch let error as CheckException {
        #expect(error.violations.count == 1)
        guard let value = error.violations.first else { continue }
        let expected = supplied?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? supplied : "First"
        #expect(value.entityType == expected)
        #expect(value.ruleID == original.ruleID)
        #expect(value.location == original.location)
        #expect(value.sourceInstancePath == original.sourceInstancePath)
        #expect(value.systemValue == original.systemValue)
        #expect(value.message?.contains("product name") == true)
        #expect(value.message?.contains(locale == .zhCN ? "第3" : "3rd") == true)
        #expect(value.location.nativePath == "orderItemList[2].productName")
        for profile in [JsonFieldNamingProfile.camelCase, .snakeCase, .pascalCase] {
          let bytes = try JSONEncoder().encode(value.wire(profile: profile))
          let wire = try JSONDecoder().decode(WireCheckResult.self, from: bytes)
          #expect(wire.entityType == expected)
          #expect(wire.sourceInstancePath == original.sourceInstancePath)
          #expect(wire.location == original.wire(profile: profile).location)
        }
      }
    }
    #expect(original.entityType == supplied)
    #expect(original.message == nil)
    #expect(await provider.writes == 0)
    #expect(await provider.queries == 0)
  }
}

@Test func checkerMetadataRetainsOriginalDeclaringTypeWhenFixChangesTarget() async throws {
  let replacement = EntityDescriptor(name: "Replacement", table: "replacement", properties: [])
  var runtime = TeaQLRuntime()
  try runtime.install(RuntimeModule(name: "original-type", entities: [metadataEntity],
    checkers: [metadataEntity.name: MetadataChecker(results: [CheckResult(ruleID: "required", location: .property("contact_phone"))], replacement: replacement)]))
  let provider = MetadataProvider()
  let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 })
  do {
    _ = try await context.execute(Mutation(kind: .create, entity: metadataEntity,
      values: ["contact_phone": .string("synthetic")], auditReason: "Reject a Fix target change"))
    Issue.record("Checker replaced the mutation target")
  } catch let error as CheckException {
    #expect(error.violations.contains { $0.ruleID == "required" && $0.entityType == "First" })
    #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.entityType == "First" })
  }
  #expect(await provider.writes == 0)
}

@Test func checkerMetadataTranslationRetainsOpaqueCustomerTextAndMarksOmittedInputs() {
  let source = CheckResult(ruleID: "customer_policy", location: .property("contact_phone"),
    message: "Customer policy rejected this value", entityType: "ReviewedItem")
  let opaque = I18nCatalog.builtin.translate(source, locale: .en)
  #expect(opaque.message == source.message)
  let omitted = I18nCatalog.builtin.translate(CheckResult(ruleID: "max_length",
    location: .property("contact_phone"), systemValue: "32"), locale: .en)
  #expect(omitted.message?.contains("[omitted]") == true)
  #expect(omitted.message?.contains("nil") == false)
  #expect(omitted.message?.contains("is 0") == false)
}

@Test func checkerMetadataPrefixPreservesAllMetadataAndRelocalizesEveryBuiltinRule() throws {
  let prefix = ObjectLocation.property("order_item_list").index(2)
  let rules = [
    CheckResult(ruleID: "required", location: .property("product_name")),
    CheckResult(ruleID: "min", location: .property("unit_price"), inputValue: "0", systemValue: "1"),
    CheckResult(ruleID: "max", location: .property("unit_price"), inputValue: "3", systemValue: "2"),
    CheckResult(ruleID: "min_length", location: .property("product_name"), inputValue: "a", systemValue: "2"),
    CheckResult(ruleID: "max_length", location: .property("product_name"), inputValue: "abc", systemValue: "2"),
  ]
  var cells = 0
  for locale in TeaQLLocale.allCases {
    for rule in rules {
      let original = CheckResult(ruleID: rule.ruleID, location: rule.location, inputValue: rule.inputValue,
        systemValue: rule.systemValue, entityType: "ReviewedItem", sourceInstancePath: "/old~1items/2/product~0name")
      let translated = I18nCatalog.builtin.translate(original, locale: locale)
      let prefixed = translated.prefixed(by: prefix)
      let final = I18nCatalog.builtin.translate(prefixed, locale: locale)
      #expect(final.entityType == original.entityType)
      #expect(final.sourceInstancePath == original.sourceInstancePath)
      #expect(final.ruleID == original.ruleID)
      #expect(final.inputValue == original.inputValue)
      #expect(final.systemValue == original.systemValue)
      #expect(final.location.modelPath == "order_item_list[2]." + original.location.modelPath)
      #expect(final.message?.contains(final.location.nativePath) == true)
      #expect(original.message == nil)
      #expect(translated.location == original.location)
      cells += 1
    }
  }
  #expect(cells == 75)
  let json = """
  {"schema":"teaql.i18n/v1","defaultLocale":"en","locales":{"en":{"messages":{"checker.domain_rule":"Policy at {location}: {system}"},"vocabulary":{}},"zh-CN":{"messages":{"checker.domain_rule":"业务规则 {location}: {system}"},"vocabulary":{}}}}
  """
  let catalog = try I18nCatalog(data: Data(json.utf8), fallback: .builtin)
  let custom = CheckResult(ruleID: "domain_rule", location: .property("unit_price"), systemValue: "approved ceiling", entityType: "ReviewedItem")
  let localized = catalog.translate(custom, locale: .zhCN)
  #expect(catalog.translate(localized.prefixed(by: prefix), locale: .zhCN).message == "业务规则 orderItemList[2].unitPrice: approved ceiling")
}

private struct MetadataChecker: EntityChecker {
  let results: [CheckResult]
  var replacement: EntityDescriptor? = nil
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if let replacement {
      mutation = Mutation(kind: mutation.kind, entity: replacement, id: mutation.id,
        values: mutation.values, expectedVersion: mutation.expectedVersion,
        auditReason: mutation.auditReason, actor: mutation.actor,
        auditCategory: mutation.auditCategory, mutationLineage: mutation.mutationLineage)
    }
    return results
  }
}

private actor MetadataProvider: MutationExecutor, QueryExecutor {
  private(set) var writes = 0, queries = 0
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes += 1
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    queries += 1
    return QueryResult(records: [], backend: "checker-metadata")
  }
}
