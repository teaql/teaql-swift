import Foundation
import Testing
import XCTest
@testable import TeaQLCore

private let privacyPhone = "customer-contact-9182"
private let privacyToken = "authkey-7734-do-not-share"
private let privacyOwner = EntityDescriptor(name: "PrivacyOrder", table: "privacy_order", properties: [
  PropertyDescriptor(name: "contactPhone", modelName: "contact_phone", column: "stored_phone", type: .string),
  PropertyDescriptor(name: "publicLabel", modelName: "public_label", type: .string),
  PropertyDescriptor(name: "payloadJSON", modelName: "payload_json", type: .json),
  PropertyDescriptor(name: "apiKey", modelName: "api_key", type: .string),
  PropertyDescriptor(name: "child", type: .json, isRelation: true, referencedEntity: "PrivacyChild"),
], auditMaskFields: ["contact_phone", "_private_note"])
private let privacyChild = EntityDescriptor(name: "PrivacyChild", table: "privacy_child", properties: [
  PropertyDescriptor(name: "contactPhone", modelName: "contact_phone", type: .string),
  PropertyDescriptor(name: "publicLabel", modelName: "public_label", type: .string),
], auditMaskFields: ["contact_phone"])
private let privacyPlain = EntityDescriptor(name: "PrivacyPlain", table: "privacy_plain", properties: [
  PropertyDescriptor(name: "contactPhone", modelName: "contact_phone", type: .string),
], auditMaskFields: [])

private struct PrivacyChecker: EntityChecker {
  let body: @Sendable (inout Mutation) throws -> [CheckResult]
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    try body(&mutation)
  }
}
private actor PrivacyProvider: MutationExecutor, QueryExecutor {
  private(set) var writes = 0, queries = 0
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes += 1
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    queries += 1
    return QueryResult(records: [], backend: "privacy-probe")
  }
}
private func privacyContext(_ checker: PrivacyChecker? = nil,
                            owner: EntityDescriptor = privacyOwner) throws -> (UserContext, PrivacyProvider) {
  var runtime = TeaQLRuntime()
  try runtime.install(RuntimeModule(name: "checker-privacy", entities: [owner, privacyChild, privacyPlain],
    checkers: checker.map { [owner.name: $0 as any EntityChecker] } ?? [:]))
  let provider = PrivacyProvider()
  return (UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 }), provider)
}
private func privacyDiagnostic(_ field: String = "contact_phone", value: String = privacyPhone,
                               system: String = "8", declaring: String? = "PrivacyOrder",
                               message: String? = nil) -> CheckResult {
  CheckResult(ruleID: "max_length", location: .property(field), inputValue: value,
    systemValue: system, message: message, entityType: declaring)
}
private func privacyFailure(_ result: CheckResult, values: TeaQLRecord = ["contact_phone": .string(privacyPhone)],
                            body: (@Sendable (inout Mutation) throws -> [CheckResult])? = nil) async throws -> CheckException {
  let (context, provider) = try privacyContext(PrivacyChecker(body: body ?? { _ in [result] }))
  var caught: CheckException?
  do {
    _ = try await context.execute(Mutation(kind: .create, entity: privacyOwner,
      values: values, auditReason: "Reject a private diagnostic before SQL"))
    Issue.record("Invalid Checker result reached SQL")
  } catch let error as CheckException { caught = error }
  #expect(await provider.writes == 0)
  #expect(await provider.queries == 0)
  return try #require(caught)
}
private func privacyPresentation(_ result: CheckResult) throws -> String {
  String(decoding: try JSONEncoder().encode(result.wire()), as: UTF8.self)
    + String(describing: result) + String(reflecting: result)
}

@Test func checkerMetadataPrivacyModeledMaskPreservesCallerAndRejectsBeforeSQL() async throws {
  let original = privacyDiagnostic()
  let error = try await privacyFailure(original)
  let value = try #require(error.violations.first)
  #expect(value.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
  #expect(!(try privacyPresentation(value)).contains(privacyPhone))
  #expect(!String(describing: error).contains(privacyPhone))
  #expect(original.inputValue == privacyPhone && original.message == nil)
}

@Test func checkerMetadataPrivacyEveryJSONProfileRetainsTypePathAndSubmittedAlias() async throws {
  let location = ObjectLocation.property("child").index(2).property("contact_phone")
  let original = CheckResult(ruleID: "max_length", location: location, inputValue: privacyPhone,
    systemValue: "3", entityType: "PrivacyChild", sourceInstancePath: "/old~1items/2/phone~0alias")
  let error = try await privacyFailure(original)
  let result = try #require(error.violations.first)
  for profile in [JsonFieldNamingProfile.camelCase, .snakeCase, .pascalCase] {
    let wire = result.wire(profile: profile)
    #expect(wire.entityType == "PrivacyChild")
    #expect(wire.sourceInstancePath == original.sourceInstancePath)
    #expect(wire.instancePath == location.instancePath(profile: profile))
    #expect(!String(decoding: try JSONEncoder().encode(wire), as: UTF8.self).contains(privacyPhone))
  }
}

@Test func checkerMetadataPrivacyUnicodeLengthSurvivesPrefixAndRelocalization() throws {
  let text = "e\u{301}秘密🙂ABC中文🙂Z"
  var (context, _) = try privacyContext()
  let source = privacyDiagnostic(value: text, system: "2")
  let first = try #require(context.translateCheckResults([source]).first)
  #expect(first.message?.contains(String(text.unicodeScalars.count)) == true)
  try context.setLocaleCode("zh-CN")
  let result = try #require(context.translateCheckResults([first.prefixed(by: .property("child").index(1))]).first)
  #expect(result.inputValue == LogPrivacy.maskAuditValue(text))
  #expect(result.message?.contains(String(text.unicodeScalars.count)) == true)
  #expect(result.message?.contains("child[1].contactPhone") == true)
  #expect(!(try privacyPresentation(result)).contains(text))
}

@Test func checkerMetadataPrivacyReusableCustomerResultsAreNotRebound() async throws {
  let original = privacyDiagnostic(declaring: nil)
  for _ in 0..<2 {
    let error = try await privacyFailure(original)
    #expect(error.violations.first?.entityType == "PrivacyOrder")
    #expect(error.violations.first?.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
  }
  #expect(original.entityType == nil && original.message == nil && original.inputValue == privacyPhone)
}

@Test func checkerMetadataPrivacyDeclaringTypeCannotWeakenActualOwner() async throws {
  for declaring in ["UnregisteredDiagnostic", "PrivacyPlain"] {
    let error = try await privacyFailure(privacyDiagnostic(declaring: declaring))
    #expect(error.violations.first?.entityType == declaring)
    #expect(error.violations.first?.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
  }
}

@Test func checkerMetadataPrivacyUnknownDiagnosticKeepsOrdinaryValue() async throws {
  let error = try await privacyFailure(privacyDiagnostic("public_label", value: "ordinary label",
    declaring: "UnknownDiagnostic"), values: ["public_label": .string("ordinary label")])
  #expect(error.violations.first?.inputValue == "ordinary label")
  #expect(error.violations.first?.systemValue == "8")
}

@Test func checkerMetadataPrivacyCatalogAloneProtectsCredential() throws {
  let original = privacyDiagnostic("api_key", value: privacyToken, system: privacyToken, declaring: nil)
  let result = I18nCatalog.builtin.translate(original, locale: .en)
  #expect(result.inputValue == "[REDACTED]" && result.systemValue == "[REDACTED]")
  #expect(!(try privacyPresentation(result)).contains(privacyToken))
}

@Test func checkerMetadataPrivacyWireAndDescriptionsAloneProtectCredential() throws {
  let source = privacyDiagnostic("password", value: privacyToken, message: "Rejected " + privacyToken)
  #expect(!(try privacyPresentation(source)).contains(privacyToken))
  #expect(source.inputValue == privacyToken)
  #expect(source.message == "Rejected " + privacyToken)
}

@Test func checkerMetadataPrivacyShortCredentialDoesNotCorruptBoundsOrPath() {
  let result = I18nCatalog.builtin.translate(privacyDiagnostic("password", value: "1", system: "1000"), locale: .en)
  #expect(result.inputValue == "[REDACTED]")
  #expect(result.systemValue == "1000")
  #expect(result.message?.contains("password") == true && result.message?.contains("1000") == true)
}

@Test func checkerMetadataPrivacyOrdinaryNumericBoundsAndVocabularyRemain() throws {
  let (context, _) = try privacyContext()
  let source = CheckResult(ruleID: "max", location: .property("public_label"), inputValue: "123.50",
    systemValue: "99.99", entityType: "PrivacyOrder")
  let result = try #require(context.translateCheckResults([source]).first)
  #expect(result.inputValue == "123.50" && result.systemValue == "99.99")
  #expect(result.message?.contains("99.99") == true)
}

@Test func checkerMetadataPrivacyCustomMessageCannotEchoSiblingOrFixedValues() async throws {
  let fixed = "replacement-private-0022"
  let diagnostic = privacyDiagnostic("public_label", value: "visible", message: "Rejected " + privacyPhone + " then " + fixed)
  let error = try await privacyFailure(diagnostic, body: { mutation in
    mutation.values["contact_phone"] = .string(fixed)
    return [diagnostic]
  })
  let result = try #require(error.violations.first)
  #expect(!(try privacyPresentation(result)).contains(privacyPhone))
  #expect(!(try privacyPresentation(result)).contains(fixed))
  #expect(result.inputValue == "visible")
  #expect(result.message?.hasPrefix("Rejected ") == true)
}

@Test func checkerMetadataPrivacyThrownStructuredErrorCannotBypassOwner() async throws {
  let source = privacyDiagnostic(declaring: "PrivacyPlain", message: "Rejected " + privacyPhone)
  let error = try await privacyFailure(source, body: { _ in throw CheckException([source]) })
  #expect(error.violations.first?.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
  #expect(!String(reflecting: error).contains(privacyPhone))
}

private struct PrivateCheckerError: Error, CustomStringConvertible, LocalizedError {
  let text: String
  var description: String { text }
  var errorDescription: String? { text }
}

@Test func checkerMetadataPrivacyArbitraryThrownErrorIsSanitizedAfterFix() async throws {
  let fixed = "replacement-private-0022"
  let (context, provider) = try privacyContext(PrivacyChecker { mutation in
    mutation.values["contact_phone"] = .string(fixed)
    throw PrivateCheckerError(text: privacyPhone + " then " + fixed)
  })
  do {
    _ = try await context.execute(Mutation(kind: .create, entity: privacyOwner,
      values: ["contact_phone": .string(privacyPhone)], auditReason: "Reject a throwing Checker"))
    Issue.record("Expected a Checker error")
  } catch {
    let text = String(describing: error) + String(reflecting: error) + error.localizedDescription
    #expect(!text.contains(privacyPhone) && !text.contains(fixed))
  }
  #expect(await provider.writes == 0)
  #expect(await provider.queries == 0)
}

@Test func checkerMetadataPrivacyStructuredRootProtectsAllSpellings() throws {
  let (context, _) = try privacyContext()
  for spelling in ["contact_phone", "contactPhone", "ContactPhone", "stored_phone"] {
    let text = "{\"\(spelling)\":\"\(privacyPhone)\",\"public_label\":\"visible\",\"apiKey\":\"\(privacyToken)\"}"
    let source = CheckResult(ruleID: "custom", location: ObjectLocation(), inputValue: text,
      entityType: "PrivacyOrder")
    let result = try #require(context.translateCheckResults([source]).first)
    #expect(result.inputValue?.contains("visible") == true)
    #expect(!(try privacyPresentation(result)).contains(privacyPhone))
    #expect(!(try privacyPresentation(result)).contains(privacyToken))
  }
}

@Test func checkerMetadataPrivacyScalarJSONDoesNotBorrowParentNamespace() throws {
  let (context, _) = try privacyContext()
  let text = "{\"contact_phone\":\"ordinary-child\",\"api_key\":\"\(privacyToken)\"}"
  let result = try #require(context.translateCheckResults([
    privacyDiagnostic("payload_json", value: text)]).first)
  #expect(result.inputValue?.contains("ordinary-child") == true)
  #expect(!(try privacyPresentation(result)).contains(privacyToken))
}

@Test func checkerMetadataPrivacyRelationWinsOverParentLeafShortcut() throws {
  let (context, _) = try privacyContext()
  let source = CheckResult(ruleID: "custom", location: .property("child").property("public_label"),
    inputValue: "ordinary-child", entityType: "PrivacyOrder")
  let result = try #require(context.translateCheckResults([source]).first)
  #expect(result.inputValue == "ordinary-child")
  let privateSource = CheckResult(ruleID: "custom", location: .property("child").property("contact_phone"),
    inputValue: privacyPhone, entityType: "PrivacyOrder")
  #expect(context.translateCheckResults([privateSource]).first?.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
}

@Test func checkerMetadataPrivacyDynamicMaskedFieldsAreProtected() throws {
  let (context, _) = try privacyContext()
  let result = try #require(context.translateCheckResults([privacyDiagnostic("_private_note")]).first)
  #expect(result.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
}

@Test func checkerMetadataPrivacyExplicitNullAndOmittedValuesStayAbsent() throws {
  let (context, _) = try privacyContext()
  let source = CheckResult(ruleID: "required", location: .property("contact_phone"), entityType: "PrivacyOrder")
  let result = try #require(context.translateCheckResults([source]).first)
  #expect(result.inputValue == nil && result.systemValue == nil)
  #expect(result.message?.contains("nil") == false)
}

@Test func checkerMetadataPrivacyCustomerTemplateDoesNotRecursivelyExpandInputs() throws {
  let source = privacyDiagnostic("public_label", value: "literal {input_len}", system: "77")
  let result = I18nCatalog.builtin.translate(source, locale: .en)
  #expect(result.inputValue == "literal {input_len}")
  let json = """
  {"schema":"teaql.i18n/v1","defaultLocale":"en","locales":{"en":{"messages":{"checker.maxLength":"{input} / {system}"},"vocabulary":{}}}}
  """
  let catalog = try I18nCatalog(data: Data(json.utf8), fallback: .builtin)
  #expect(catalog.translate(source, locale: .en).message == "literal {input_len} / 77")
}

@Test func checkerMetadataPrivacyCustomerTemplateLiteralIsScrubbed() async throws {
  let json = """
  {"schema":"teaql.i18n/v1","defaultLocale":"en","locales":{"en":{"messages":{"checker.maxLength":"Rejected \(privacyPhone) at {location}: {input} / {system}"},"vocabulary":{}}}}
  """
  var (context, _) = try privacyContext()
  context.installI18nCatalog(try I18nCatalog(data: Data(json.utf8), fallback: .builtin))
  let value = try #require(context.translateCheckResults([privacyDiagnostic()]).first)
  #expect(!(try privacyPresentation(value)).contains(privacyPhone))
  #expect(value.message?.contains("contactPhone") == true)
}

@Test func checkerMetadataPrivacyEditedCachedMessageCannotBypassProtection() throws {
  let (context, _) = try privacyContext()
  var first = try #require(context.translateCheckResults([privacyDiagnostic()]).first)
  first.message = "New echo " + privacyPhone
  let second = try #require(context.translateCheckResults([first]).first)
  // Already-safe input cannot recover the original secret; a changed custom
  // message must not be trusted merely because the input was projected earlier.
  #expect(!(try privacyPresentation(second)).contains(privacyPhone))
}

@Test func checkerMetadataPrivacySameContextConcurrentRequestsKeepLocalScopes() async throws {
  let (context, provider) = try privacyContext(PrivacyChecker { mutation in
    let phone = mutation.values["contact_phone"]?.stringValue ?? "missing"
    let label = mutation.values["public_label"]?.stringValue ?? "missing"
    return [privacyDiagnostic("public_label", value: label, message: "Rejected " + phone + " / " + label)]
  })
  try await withThrowingTaskGroup(of: CheckException.self) { group in
    for index in 0..<8 {
      group.addTask {
        let phone = "private-request-\(index)-9911", label = "public-request-\(index)"
        do {
          _ = try await context.execute(Mutation(kind: .create, entity: privacyOwner,
            values: ["contact_phone": .string(phone), "public_label": .string(label)], auditReason: "Reject concurrent private value"))
          throw PrivateCheckerError(text: "Checker unexpectedly succeeded")
        } catch let error as CheckException {
          #expect(error.violations.first?.inputValue == label)
          #expect(error.violations.first?.message?.contains(label) == true)
          #expect(!String(reflecting: error).contains(phone))
          return error
        }
      }
    }
    for try await _ in group {}
  }
  #expect(await provider.writes == 0)
}

@Test func checkerMetadataPrivacyLoadedOriginalValuesStayInvocationLocal() async throws {
  let old = "loaded-original-phone-1100"
  let source = privacyDiagnostic("public_label", value: "visible", message: "Rejected old " + old)
  let (context, provider) = try privacyContext(PrivacyChecker { _ in [source] })
  var mutation = Mutation(kind: .create, entity: privacyOwner,
    values: ["public_label": .string("visible")], auditReason: "Reject a loaded private snapshot")
  mutation.loadedValues = ["contact_phone": .string(old)]
  do {
    _ = try await context.execute(mutation)
    Issue.record("Expected a rejected snapshot")
  } catch let error as CheckException {
    #expect(!String(reflecting: error).contains(old))
    #expect(error.violations.first?.message == "Rejected old [REDACTED]")
  }
  #expect(mutation.loadedValues["contact_phone"] == .string(old))
  #expect(await provider.writes == 0)
}

@Test func checkerMetadataPrivacyDeclaringPolicyCanAddProtection() async throws {
  let source = privacyDiagnostic(declaring: "PrivacyChild")
  let (context, _) = try privacyContext(PrivacyChecker { _ in [source] }, owner: privacyPlain)
  do {
    _ = try await context.execute(Mutation(kind: .create, entity: privacyPlain,
      values: ["contact_phone": .string(privacyPhone)], auditReason: "Protect child declaring policy"))
    Issue.record("Expected a child policy rejection")
  } catch let error as CheckException {
    #expect(error.violations.first?.entityType == "PrivacyChild")
    #expect(error.violations.first?.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
  }
}

@Test func checkerMetadataPrivacyRelationDoesNotUseParentSameNamedScalar() throws {
  let parent = EntityDescriptor(name: "PrivacyCollision", table: "privacy_collision", properties: [
    PropertyDescriptor(name: "publicLabel", modelName: "public_label", type: .string),
    PropertyDescriptor(name: "child", type: .json, isRelation: true, referencedEntity: "PrivacyChild"),
  ], auditMaskFields: ["public_label"])
  let (context, _) = try privacyContext(owner: parent)
  let source = CheckResult(ruleID: "custom", location: .property("child").property("public_label"),
    inputValue: "ordinary-child", entityType: parent.name)
  #expect(context.translateCheckResults([source]).first?.inputValue == "ordinary-child")
}

@Test func checkerMetadataPrivacyTrustedWireAliasesCannotBypassModelMask() throws {
  var runtime = TeaQLRuntime()
  let wire = try WireEntityMetadata(entityType: privacyOwner.name,
    canonicalFields: ["contact_phone", "public_label"], aliases: ["contact_phone": ["phone~alias"]])
  try runtime.install(RuntimeModule(name: "private-wire", entities: [privacyOwner], wireMetadata: [privacyOwner.name: wire]))
  let provider = PrivacyProvider()
  let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 })
  let source = CheckResult(ruleID: "custom", location: ObjectLocation(),
    inputValue: "{\"phone~alias\":\"\(privacyPhone)\",\"publicLabel\":\"visible\"}", entityType: privacyOwner.name)
  let result = try #require(context.translateCheckResults([source]).first)
  #expect(result.inputValue?.contains("visible") == true)
  #expect(!(try privacyPresentation(result)).contains(privacyPhone))
}

@Test func checkerMetadataPrivacySubmittedPathRebasingKeepsSafePresentation() throws {
  let (context, _) = try privacyContext()
  let result = try #require(context.translateCheckResults([privacyDiagnostic(value: "e\u{301}秘密🙂ABC中文🙂Z")]).first)
  let normalized = NormalizedWireInput(values: [:], sourceInstancePaths: ["contact_phone": "/phone~1alias"])
  let retained = try #require(retainSubmittedPaths([result], normalized: normalized).first)
  let prefixed = retained.prefixed(by: .property("child").index(1))
  let final = try #require(context.translateCheckResults([prefixed]).first)
  #expect(final.sourceInstancePath == "/phone~1alias")
  #expect(final.message?.contains("12") == true)
  #expect(final.message?.contains("child[1].contactPhone") == true)
}

@Test func checkerMetadataPrivacyStructuredArrayRetainsOrdinarySiblings() throws {
  let (context, _) = try privacyContext()
  let source = CheckResult(ruleID: "custom", location: ObjectLocation(),
    inputValue: "[{\"contactPhone\":\"\(privacyPhone)\",\"publicLabel\":\"visible\"}]", entityType: privacyOwner.name)
  let result = try #require(context.translateCheckResults([source]).first)
  #expect(result.inputValue?.contains("visible") == true)
  #expect(!(try privacyPresentation(result)).contains(privacyPhone))
}

@Test func checkerMetadataPrivacyPlainCachedDiagnosticAcquiresStricterOwnerPolicy() async throws {
  let (plainContext, _) = try privacyContext()
  let plain = try #require(plainContext.translateCheckResults([
    privacyDiagnostic(declaring: "PrivacyPlain", message: "Rejected " + privacyPhone)]).first)
  #expect(plain.inputValue == privacyPhone)
  let error = try await privacyFailure(plain)
  #expect(error.violations.first?.entityType == "PrivacyPlain")
  #expect(error.violations.first?.inputValue == LogPrivacy.maskAuditValue(privacyPhone))
  #expect(!String(reflecting: error).contains(privacyPhone))
}

final class CheckerPrivacyI18nTests: XCTestCase {
  func testEnvironmentChild() throws {
    guard ProcessInfo.processInfo.environment["TEAQL_CHECKER_PRIVACY_CHILD"] == "1" else { return }
    let acknowledged = ProcessInfo.processInfo.environment[LogPrivacy.environmentName] == LogPrivacy.acknowledgement
    let (context, _) = try privacyContext()
    let source = privacyDiagnostic(value: "e\u{301}秘密🙂ABC中文🙂Z")
    let result = try XCTUnwrap(context.translateCheckResults([source]).first)
    XCTAssertEqual(result.inputValue, acknowledged ? source.inputValue : LogPrivacy.maskAuditValue(source.inputValue!))
    XCTAssertTrue(result.message!.contains("12"))
    XCTAssertFalse(try privacyPresentation(result).contains(source.inputValue!))
    let credential = try XCTUnwrap(context.translateCheckResults([
      privacyDiagnostic("api_key", value: privacyToken, system: privacyToken)]).first)
    XCTAssertEqual(credential.inputValue, "[REDACTED]")
    XCTAssertFalse(try privacyPresentation(credential).contains(privacyToken))
    let prior = ProcessInfo.processInfo.environment[LogPrivacy.environmentName]
    unsetenv(LogPrivacy.environmentName)
    defer { if let prior { setenv(LogPrivacy.environmentName, prior, 1) } }
    let safeAgain = try XCTUnwrap(context.translateCheckResults([result]).first)
    XCTAssertEqual(safeAgain.inputValue, LogPrivacy.maskAuditValue(source.inputValue!))
    XCTAssertTrue(safeAgain.message!.contains("12"))
    print("SWIFT_CHECKER_PRIVACY_CHILD_DONE")
  }

  func testExactProcessEnvironmentAndDebugCacheReprojection() throws {
    guard ProcessInfo.processInfo.environment["TEAQL_CHECKER_PRIVACY_CHILD"] != "1" else { return }
    for setting: String? in [nil, "true", LogPrivacy.acknowledgement + " ", LogPrivacy.acknowledgement] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("checker-privacy-\(UUID().uuidString).log")
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
      defer { try? FileManager.default.removeItem(at: url) }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      #if os(macOS)
      child.arguments = ["-XCTest", "TeaQLCoreTests.CheckerPrivacyI18nTests/testEnvironmentChild", Bundle(for: Self.self).bundleURL.path]
      #else
      child.arguments = ["TeaQLCoreTests.CheckerPrivacyI18nTests/testEnvironmentChild"]
      #endif
      var environment = ProcessInfo.processInfo.environment
      environment["TEAQL_CHECKER_PRIVACY_CHILD"] = "1"
      environment[LogPrivacy.environmentName] = setting
      environment.removeValue(forKey: "XCTestConfigurationFilePath")
      child.environment = environment; child.standardOutput = handle; child.standardError = handle
      let exit = try runBoundedTestChild(child, output: handle)
      try handle.close()
      let text = try String(contentsOf: url, encoding: .utf8)
      XCTAssertEqual(exit, 0, text)
      XCTAssertTrue(text.contains("SWIFT_CHECKER_PRIVACY_CHILD_DONE"), text)
      XCTAssertEqual(text.contains("may be written to disk"), setting == LogPrivacy.acknowledgement, text)
      XCTAssertFalse(text.contains(privacyToken), text)
      print("SWIFT_CHECKER_PRIVACY_ENV=" + (setting == LogPrivacy.acknowledgement ? "acknowledged" : setting == nil ? "absent" : "rejected"))
    }
  }
}
