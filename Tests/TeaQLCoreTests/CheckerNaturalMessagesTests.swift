import Foundation
import Testing
@testable import TeaQLCore

private func naturalFixture(_ name: String) throws -> [String: Any] {
  let url = try #require(Bundle.module.url(forResource:name,withExtension:"json"))
  return try CheckerMessageJSON.parse(Data(contentsOf:url))
}
private func naturalModel() throws -> CheckerPresentationModel {
  var model = try naturalFixture("cases-v1"); model["schema"] = "teaql.checker-model/v1"; model.removeValue(forKey:"origin"); model.removeValue(forKey:"cases")
  return try CheckerPresentationModel(data:JSONSerialization.data(withJSONObject:model))
}
private struct NaturalUnusedProvider: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw TeaQLError.execution("unexpected provider query") }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw TeaQLError.execution("unexpected provider mutation") }
}
private func naturalContext() throws -> UserContext {
  var context = UserContext(queryExecutor:NaturalUnusedProvider(),mutationExecutor:NaturalUnusedProvider(),requestPolicy:RequestPolicy { $0 },querySQLLogEnabled:false,mutationSQLLogEnabled:false)
  context.installCheckerPresentation(try naturalModel()); context.installCheckerMessageWarning { _ in }; return context
}
private func naturalError(_ field: String = "name", rule: String = "required", input: String? = nil, system: String? = nil) -> CheckResult {
  CheckResult(ruleID:rule,location:.property(field),inputValue:input,systemValue:system,entityType:"Entry")
}
private func naturalOverride(_ shape: String, _ text: String, item: String? = nil) throws -> Data {
  var entry: [String: Any] = ["rules":["checker.required":[shape:text]]]
  if let item { entry["locationPatterns"] = ["reference":"the {relation}","item":item,"separator":" → "] }
  return try JSONSerialization.data(withJSONObject:["schema":"teaql.checker-messages/v1","defaultLocale":"en","locales":["en":entry]])
}
private final class NaturalProbe: @unchecked Sendable {
  private let lock = NSLock(); private var count = 0; private var values: [CheckerMessageWarning] = []
  func called() { lock.withLock { count += 1 } }; var calls: Int { lock.withLock { count } }
  func warn(_ value: CheckerMessageWarning) { lock.withLock { values.append(value) } }; var warnings: [CheckerMessageWarning] { lock.withLock { values } }
}
private struct NaturalLengthChecker: EntityChecker {
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if case .string(let text) = mutation.values["name"], text.count > 1 {
      return [CheckResult(ruleID:"max_length",location:.property("name"),systemValue:"1")]
    }
    return []
  }
}

@Suite("Natural Checker messages") struct CheckerNaturalMessagesTests {
  @Test func allTwentyFourSharedGoldens() throws {
    let fixture = try naturalFixture("cases-v1"), roots = try naturalFixture("root-cases-v1"), model = try naturalModel()
    let tests = try #require(fixture["cases"] as? [[String: Any]]) + #require(roots["cases"] as? [[String: Any]])
    for item in tests {
      var location = ObjectLocation()
      for part in try #require(item["path"] as? [Any]) {
        if let field = part as? String { location = location.property(field) } else { location = location.index(try #require(part as? Int)) }
      }
      let origin: String? = item.keys.contains("origin") ? item["origin"] as? String : "Catalog"
      let snapshot = try CheckerMessagePresentation(model:model,origin:origin,location:location)
      let locale = try TeaQLLocale.parse(#require(item["locale"] as? String)), rule = try #require(item["rule"] as? String)
      let arguments = (item["arguments"] as? [String: Any] ?? [:]).mapValues { String(describing:$0) }
      let output = snapshot.render(catalog:.builtin,selection:CheckerMessageCatalog.builtin.select(locale,rule:rule,shape:snapshot.shape),arguments:arguments)
      #expect(snapshot.shape.rawValue.uppercased() == item["shape"] as? String)
      #expect(output.message == item["expected"] as? String)
      if let expected = item["instancePath"] as? String { #expect(location.instancePath == expected) }
    }
    #expect(tests.count == 24)
  }
  @Test func all270TemplatesAndEnglishOrdinals() {
    var count = 0
    for locale in TeaQLLocale.allCases { for rule in ["required","min","max","minLength","maxLength","invalid"] { for shape in CheckerMessageShape.allCases {
      #expect(CheckerMessageCatalog.builtin.lookup(locale,rule:"checker."+rule,shape:shape) != nil); count += 1
    } } }
    #expect(count == 270)
    for (position,expected) in [(1,"1st"),(2,"2nd"),(3,"3rd"),(11,"11th"),(12,"12th"),(13,"13th"),(21,"21st")] {
      #expect(CheckerMessageCatalog.ordinal(UInt64(position)) == expected)
    }
  }
  @Test(arguments:["{field","{field} {secret}","{field.toString()}","{field} {input}","{field} {object}","field}"])
  func malformedOrExecutableTemplatesAreRejected(_ text: String) throws {
    let data = try naturalOverride("one",text)
    #expect(throws:(any Error).self) { try CheckerMessageCatalog(data:data) }
  }
  @Test func duplicateKeysAndAliasesRejectAtomically() throws {
    let data = try naturalOverride("one","{field}")
    let duplicate = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\"schema\":",with:"\"schema\":\"bad\",\"schema\":")
    #expect(throws:(any Error).self) { try CheckerMessageCatalog(data:Data(duplicate.utf8)) }
    let escaped = "{\"schema\":\"teaql.checker-messages/v1\",\"defaultLocale\":\"en\",\"locales\":{\"en\":{},\"\\u0065n\":{}}}"
    #expect(throws:(any Error).self) { try CheckerMessageCatalog(data:Data(escaped.utf8)) }
    var root = try CheckerMessageJSON.parse(data), locales = try CheckerMessageJSON.object(root["locales"])
    locales["en-US"] = locales["en"]; root["locales"] = locales
    let aliases = try JSONSerialization.data(withJSONObject:root)
    #expect(throws:(any Error).self) { try CheckerMessageCatalog(data:aliases) }
    var context = try naturalContext(); try context.installCheckerMessageCatalog(data:naturalOverride("one","Good {field}"))
    #expect(throws:(any Error).self) { try context.installCheckerMessageCatalog(data:aliases) }
    #expect(context.translateCheckResults([naturalError()],from:"Catalog").first?.message == "Good name")
  }
  @Test func defaultEnglishAndLiteralBraces() throws {
    var context = try naturalContext()
    #expect(context.locale == .en)
    #expect(context.translateCheckResults([naturalError()],from:"Catalog").first?.message == "The name is required.")
    #expect(throws:UnsupportedLocaleError.self) { try context.setLocaleCode("unsupported") }
    #expect(context.locale == .en)
    try context.installCheckerMessageCatalog(data:naturalOverride("one","{{literal}} {field}"))
    #expect(context.translateCheckResults([naturalError()],from:"Catalog").first?.message == "{literal} name")
  }
  @Test func safeScalarMeasurementSurvivesPrefixAndLocale() throws {
    var context = try naturalContext(); let input = "密钥🔑abcdef"
    let original = try #require(context.translateCheckResults([naturalError("password",rule:"max_length",input:input,system:"8")],from:"Entry").first)
    let relocated = try #require(context.translateCheckResults([original.prefixed(by:.property("entry_list").index(1))],from:"Catalog").first)
    #expect(relocated.message?.contains("2nd entry") == true); #expect(relocated.message?.contains("length is 9") == true)
    #expect(relocated.instancePathForTest == "/entryList/1/password"); #expect(original.location.instancePath == "/password")
    try context.setLocaleCode("zh-CN")
    let translated = try #require(context.translateCheckResults([relocated]).first)
    #expect(translated.message?.contains("第2条明细") == true && translated.message?.contains("9") == true)
    #expect(!String(describing:CheckException([translated])).contains(input))
  }
  @Test func retainedCustomNodesAreReprojectedForNewSensitiveSibling() throws {
    let secret = "LATER-PRIVATE-CANARY"; var context = try naturalContext()
    try context.installCheckerMessageCatalog(data:naturalOverride("one",secret+" {field}",item:secret+" {ordinal} {relation}"))
    let retained = try #require(context.translateCheckResults([naturalError()],from:"Catalog").first)
    #expect(retained.message?.contains(secret) == true)
    let projected = context.translateCheckResults([retained,naturalError("password",rule:"max_length",input:secret,system:"128")])
    #expect(projected[0].message?.contains(secret) == false); #expect(projected[1].message?.contains("128") == true)
    let relocated = try #require(context.translateCheckResults([projected[0].prefixed(by:.property("entry_list").index(1))],from:"Catalog").first)
    #expect(relocated.message?.contains(secret) == false); #expect(relocated.message?.contains("2nd") == true)
  }
  @Test func depthSpecificPrivateTemplateNeverReopensRawResource() throws {
    let secret = "DEPTH-PRIVATE-CANARY"; var context = try naturalContext()
    try context.installCheckerMessageCatalog(data:naturalOverride("two",secret+" {field} of {object}"))
    let first = try #require(context.translateCheckResults([naturalError("password",input:secret)],from:"Entry").first)
    let relocated = try #require(context.translateCheckResults([first.prefixed(by:.property("entry_list").index(1))],from:"Catalog").first)
    #expect(!String(describing:relocated).contains(secret)); #expect(relocated.message?.contains("2nd entry") == true)
  }
  @Test func customRendererCalledOnceAndCausesRemainPrivate() throws {
    let probe = NaturalProbe(); var context = try naturalContext()
    context.installCheckerMessageRenderer { _ in probe.called(); return CheckerMessageOutput("customer literal") }
    let first = try #require(context.translateCheckResults([naturalError()],from:"Entry").first)
    let relocated = context.translateCheckResults([first.prefixed(by:.property("entry_list").index(1))],from:"Catalog")
    #expect(relocated.first?.message == "customer literal"); #expect(probe.calls == 1)
    context.installCheckerMessageWarning { probe.warn($0) }
    context.installCheckerMessageRenderer { _ in throw TeaQLError.execution("PRIVATE-RENDERER-CAUSE") }
    let fallback = try #require(context.translateCheckResults([naturalError()],from:"Catalog").first)
    #expect(fallback.message == "The name is invalid."); #expect(probe.warnings.contains(.renderFallback))
    #expect(!String(describing:CheckException([fallback])).contains("PRIVATE-RENDERER-CAUSE"))
  }
  @Test func explicitLiteralAndSourcePointerStayAuthoritative() throws {
    let original = CheckResult(ruleID:"required",location:.property("name"),message:"Contact support",entityType:"PrivateEntry",sourceInstancePath:"/payload/name~1alias")
    let result = try #require(naturalContext().translateCheckResults([original.prefixed(by:.property("entry_list").index(1))],from:"Catalog").first)
    #expect(result.message == "Contact support"); #expect(result.entityType == original.entityType)
    #expect(result.sourceInstancePath == original.sourceInstancePath); #expect(result.location.instancePath == "/entryList/1/name")
  }
  @Test func modelSharingMergeAndNoMutableContextRetention() throws {
    let model = try naturalModel(), other = try naturalModel()
    #expect(try model.merging(other) === model)
    let one = try CheckerMessagePresentation(model:model,origin:"Catalog",location:.property("name"))
    let two = try one.relocated(.property("entry_list").index(1).property("name"))
    #expect(one.model === two.model)
    #expect(throws:(any Error).self) { try CheckerMessagePresentation(model:model,origin:"Catalog",location:.property("entry_list").index(-1)) }
  }
  @Test func actualCheckerReportsItsGraphemeMeasurementWithoutInputDisclosure() throws {
    let entity = EntityDescriptor(name:"Entry",table:"entry_data",properties:[PropertyDescriptor(name:"name",type:.string)])
    var runtime = TeaQLRuntime(); try runtime.install(RuntimeModule(name:"Natural measurements",entities:[entity],checkers:["Entry":NaturalLengthChecker()],checkerPresentation:try naturalModel()))
    let context = UserContext(runtime:runtime,queryExecutor:NaturalUnusedProvider(),mutationExecutor:NaturalUnusedProvider(),requestPolicy:RequestPolicy { $0 })
    let input = "e\u{301}e\u{301}"
    #expect(input.count == 2 && input.unicodeScalars.count == 4)
    do {
      _ = try context.preflightMutation(Mutation(kind:.create,entity:entity,values:["name":.string(input)],auditReason:"Reject before provider access"))
      Issue.record("Expected a grapheme length violation")
    } catch let error as CheckException {
      let result = try #require(error.violations.first)
      #expect(result.message == "The name must not exceed 1 grapheme clusters; its current length is 2.")
      #expect(result.inputValue == nil); #expect(result.entityType == "Entry"); #expect(result.location.instancePath == "/name")
    }
  }
  @Test func explicitCheckerMeasurementOverridesLegacyScalarFallback() throws {
    let context = try naturalContext(), input = "e\u{301}e\u{301}"
    let value = naturalError("password",rule:"max_length",input:input,system:"1")
      .withLengthMeasurement(try CheckerLengthMeasurement(input.count,unit:.grapheme))
    let rendered = try #require(context.translateCheckResults([value],from:"Entry").first)
    #expect(rendered.message?.contains("grapheme clusters") == true && rendered.message?.contains("length is 2") == true)
    #expect(!String(describing:rendered).contains(input))
    #expect(throws:CheckerMessageResourceError.self) { try CheckerLengthMeasurement(-1,unit:.scalar) }
  }
}

private extension CheckResult { var instancePathForTest: String { location.instancePath } }
