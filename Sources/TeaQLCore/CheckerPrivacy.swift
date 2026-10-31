import Foundation

/// Immutable-value presentation provenance. No original masked input, Context,
/// mutable request owner, or raw values from another field are retained here.
struct CheckerPresentation: Sendable {
  let safeInput: String?
  let safeSystem: String?
  let safeMessage: String?
  let inputLength: Int?
  let masked: Bool
  let credential: Bool
  let sensitive: Bool
  var automaticMessage: Bool
  var messageEdited = false
}

struct CheckerPrivateScope: Sendable {
  var safe: [String] = []
  var debug: [String] = []
  mutating func append(_ other: Self) { safe += other.safe; debug += other.debug }
}

/// All policy resolution and sensitive-value scope are invocation arguments,
/// not mutable state on the shared UserContext, runtime, or cached diagnostic.
enum CheckerPrivacy {
  static let redacted = "[REDACTED]"
  private struct Policy {
    var masked = false
    var credential = false
    var target: EntityDescriptor?
  }

  private static func spellings(_ property: PropertyDescriptor) -> Set<String> {
    let canonical = property.modelName ?? property.name
    return Set([canonical, property.name, property.column,
      JsonFieldNamingProfile.camelCase.render(canonical), JsonFieldNamingProfile.pascalCase.render(canonical)])
  }
  private static func property(_ entity: EntityDescriptor?, _ name: String,
                               runtime: TeaQLRuntime?) -> PropertyDescriptor? {
    guard let entity else { return nil }
    let canonical = runtime?.wireMetadata(named: entity.name)?.fields.values.first {
      $0.wireName == name || $0.aliases.contains(name)
    }?.canonicalName
    return entity.properties.first { spellings($0).contains(canonical ?? name) }
  }
  private static func fieldPolicy(_ entity: EntityDescriptor?, _ name: String,
                                  runtime: TeaQLRuntime?) -> Policy {
    let prop = property(entity, name, runtime: runtime)
    let names = prop.map(spellings) ?? Set([name])
    return Policy(masked: !names.isDisjoint(with: Set(entity?.auditMaskFields ?? [])),
      credential: names.contains(where: LogPrivacy.credential),
      target: prop?.isRelation == true ? prop?.referencedEntity.flatMap { runtime?.entity(named: $0) } : nil)
  }
  private static func at(_ entity: EntityDescriptor?, location: ObjectLocation,
                         runtime: TeaQLRuntime?) -> Policy {
    let names = location.segments.compactMap { segment -> String? in
      if case .property(let name) = segment { return name }; return nil
    }
    var result = Policy(credential: names.contains(where: LogPrivacy.credential), target: entity)
    for (index, name) in names.enumerated() {
      let current = result.target, prop = property(current, name, runtime: runtime)
      let policy = fieldPolicy(current, name, runtime: runtime)
      result.masked = result.masked || policy.masked
      result.credential = result.credential || policy.credential
      if prop?.isRelation == true {
        result.target = policy.target // A real relation precedes a declaring-leaf shortcut.
      } else {
        if prop == nil, index == 0, names.count > 1, let leaf = names.last {
          let leafPolicy = fieldPolicy(current, leaf, runtime: runtime)
          result.masked = result.masked || leafPolicy.masked
          result.credential = result.credential || leafPolicy.credential
        }
        result.target = nil // Scalar JSON is not the parent's model namespace.
      }
    }
    return result
  }

  private static func value(_ source: TeaQLValue, entity: EntityDescriptor?, runtime: TeaQLRuntime?,
                            masked: Bool = false, credential: Bool = false, allow: Bool) -> TeaQLValue {
    if source == .null { return source }
    if source == .string(redacted) { return source }
    if credential { return .string(redacted) }
    if masked && !allow {
      if case .array(let values) = source {
        return .array(values.map { value($0, entity: nil, runtime: runtime, masked: true, allow: false) })
      }
      if case .object = source { return .string(redacted) }
      return .string(LogPrivacy.maskAuditValue(LogPrivacy.strings(source).first ?? ""))
    }
    switch source {
    case .object(let fields):
      return .object(fields.reduce(into: [:]) { output, item in
        let policy = fieldPolicy(entity, item.key, runtime: runtime)
        output[item.key] = value(item.value, entity: policy.target, runtime: runtime,
          masked: policy.masked, credential: policy.credential, allow: allow)
      })
    case .array(let values):
      return .array(values.map { value($0, entity: entity, runtime: runtime, allow: allow) })
    default: return source
    }
  }
  private static func changed(_ raw: TeaQLValue, _ safe: TeaQLValue) -> [String] {
    guard raw != safe else { return [] }
    switch (raw, safe) {
    case (.object(let fields), .object(let result)):
      return fields.flatMap { changed($0.value, result[$0.key] ?? .null) }
    case (.array(let fields), .array(let result)):
      return fields.enumerated().flatMap { changed($0.element, $0.offset < result.count ? result[$0.offset] : .null) }
    default: return LogPrivacy.strings(raw)
    }
  }
  static func capture(_ mutation: Mutation, owner: EntityDescriptor, runtime: TeaQLRuntime) -> CheckerPrivateScope {
    var result = CheckerPrivateScope()
    for fields in [mutation.loadedValues, mutation.values] {
      let raw = TeaQLValue.object(fields)
      result.safe += changed(raw, value(raw, entity: owner, runtime: runtime, allow: false))
      result.debug += changed(raw, value(raw, entity: owner, runtime: runtime, allow: true))
    }
    return result
  }
  static func scrub(_ text: String?, secrets: [String]) -> String? {
    guard let text, !secrets.isEmpty else { return text }
    var variants = Set(secrets.filter { !$0.isEmpty })
    for secret in Array(variants) {
      for format: JSONEncoder.OutputFormatting in [[], .withoutEscapingSlashes] {
        let encoder = JSONEncoder(); encoder.outputFormatting = format
        if let bytes = try? encoder.encode(secret), let encoded = String(data: bytes, encoding: .utf8) {
          variants.insert(String(encoded.dropFirst().dropLast()))
        }
      }
    }
    guard !variants.isEmpty else { return text }
    let pattern = variants.sorted { $0.unicodeScalars.count > $1.unicodeScalars.count }
      .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return redacted }
    return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
      withTemplate: redacted)
  }
  private static func structured(_ text: String) -> TeaQLValue? {
    guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first,
      first == "{" || first == "[", let data = text.data(using: .utf8),
      let value = try? JSONDecoder().decode(TeaQLValue.self, from: data) else { return nil }
    return value
  }
  private static func text(_ value: TeaQLValue) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return redacted }
    return text
  }
  private static func projected(_ input: String?, policy: Policy, runtime: TeaQLRuntime?, allow: Bool) -> (String?, [String]) {
    guard let input else { return (nil, []) }
    if input == redacted { return (input, []) }
    let raw = structured(input) ?? .string(input)
    let result = value(raw, entity: policy.target, runtime: runtime,
      masked: policy.masked, credential: policy.credential, allow: allow)
    let display: String
    if case .string(let string) = result { display = string }
    else { display = result == raw ? input : text(result) }
    return (display, changed(raw, result))
  }
  private static func system(_ source: String?, rule: String, credential: Bool, secrets: [String]) -> String? {
    guard let source else { return nil }
    // Swift's existing diagnostic API uses strings for numeric bounds. Preserve
    // known bound syntax as a whole, not arbitrary numeric substrings of secrets.
    let bounds = ["min", "max", "min_str_len", "max_str_len", "min_length", "max_length"]
    if bounds.contains(rule.lowercased()), source.range(of: "^[+-]?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil {
      return source
    }
    return credential ? redacted : scrub(source, secrets: secrets)
  }
  private static func key(_ rule: String) -> String {
    let keys = ["required":"required", "min":"min", "max":"max", "min_str_len":"minLength",
      "min_length":"minLength", "max_str_len":"maxLength", "max_length":"maxLength"]
    return "checker." + (keys[rule.lowercased()] ?? rule.lowercased())
  }
  private static func render(_ template: String, source: CheckResult, input: String?, system: String?,
                             length: Int?, secrets: [String], builtin: Bool) -> String {
    let expression = try! NSRegularExpression(pattern: "\\{(location|system|input|input_len)\\}")
    let values = ["location": source.location.nativePath, "system": system ?? "[omitted]",
      "input": input ?? "[omitted]", "input_len": length.map(String.init) ?? "[omitted]"]
    var output = "", cursor = template.startIndex
    for match in expression.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
      guard let range = Range(match.range, in: template), let name = Range(match.range(at: 1), in: template) else { continue }
      let literal = String(template[cursor..<range.lowerBound])
      output += (builtin ? literal : scrub(literal, secrets: secrets) ?? "") + (values[String(template[name])] ?? "")
      cursor = range.upperBound
    }
    let literal = String(template[cursor...])
    return output + (builtin ? literal : scrub(literal, secrets: secrets) ?? "")
  }

  static func project(_ source: CheckResult, runtime: TeaQLRuntime? = nil, owner: EntityDescriptor? = nil,
                      scope: CheckerPrivateScope = CheckerPrivateScope(), catalog: I18nCatalog? = nil,
                      locale: TeaQLLocale = .en, allowPlaintext: Bool? = nil) -> CheckResult {
    let allow = allowPlaintext ?? LogPrivacy.plaintextEnabled(), previous = source.presentation
    let declared = source.entityType.flatMap { runtime?.entity(named: $0) }
    let policies = [owner, declared].compactMap { $0 }.map { at($0, location: source.location, runtime: runtime) }
    var combined = Policy(masked: previous?.masked ?? false, credential: previous?.credential ?? false)
    combined.credential = combined.credential || source.location.segments.contains {
      if case .property(let name) = $0 { return LogPrivacy.credential(name) }; return false
    }
    for policy in policies { combined.masked = combined.masked || policy.masked; combined.credential = combined.credential || policy.credential }
    var safeInput = previous?.safeInput ?? source.inputValue, displayInput = source.inputValue
    var safeSecrets = scope.safe, displaySecrets = allow ? scope.debug : scope.safe
    for policy in policies.isEmpty ? [combined] : policies.map({ Policy(masked: combined.masked, credential: combined.credential, target: $0.target) }) {
      let safe = projected(safeInput, policy: policy, runtime: runtime, allow: false)
      safeInput = safe.0; safeSecrets += safe.1
      let displayed = projected(displayInput, policy: policy, runtime: runtime, allow: allow)
      displayInput = displayed.0; displaySecrets += displayed.1
    }
    safeInput = scrub(safeInput, secrets: scope.safe)
    displayInput = allow ? scrub(displayInput, secrets: scope.debug) : safeInput
    let safeSystem = system(previous?.safeSystem ?? source.systemValue, rule: source.ruleID,
      credential: combined.credential, secrets: safeSecrets)
    let displaySystem = allow ? system(source.systemValue, rule: source.ruleID,
      credential: combined.credential, secrets: displaySecrets) : safeSystem
    if safeSystem != source.systemValue, let raw = source.systemValue { safeSecrets.append(raw) }
    if displaySystem != source.systemValue, let raw = source.systemValue { displaySecrets.append(raw) }
    let length = previous?.inputLength ?? source.inputValue.map { $0.unicodeScalars.count }
    let automatic = source.message == nil || previous?.automaticMessage == true
    let safeMessage: String?, displayMessage: String?
    if let catalog, automatic {
      let k = key(source.ruleID), template = catalog.message(locale, k)
      let builtin = template == I18nCatalog.builtin.message(locale, k)
      safeMessage = render(template, source: source, input: safeInput, system: safeSystem,
        length: length, secrets: safeSecrets, builtin: builtin)
      displayMessage = render(template, source: source, input: displayInput, system: displaySystem,
        length: length, secrets: displaySecrets, builtin: builtin)
    } else if previous?.messageEdited == true && previous?.sensitive == true {
      // No raw-secret cache is kept to inspect new free text added to a cached
      // private diagnostic. Rebind through a fresh Checker invocation instead.
      safeMessage = source.message == nil ? nil : redacted
      displayMessage = allow ? scrub(source.message, secrets: displaySecrets) : safeMessage
    } else {
      safeMessage = scrub(previous?.safeMessage ?? source.message, secrets: safeSecrets)
      displayMessage = allow ? scrub(source.message, secrets: displaySecrets) : safeMessage
    }
    var result = CheckResult(ruleID: source.ruleID, location: source.location, inputValue: displayInput,
      systemValue: displaySystem, message: displayMessage, entityType: source.entityType,
      sourceInstancePath: source.sourceInstancePath)
    result.presentation = CheckerPresentation(safeInput: safeInput, safeSystem: safeSystem,
      safeMessage: safeMessage, inputLength: length, masked: combined.masked, credential: combined.credential,
      sensitive: previous?.sensitive == true || combined.masked || combined.credential || !safeSecrets.isEmpty,
      automaticMessage: automatic)
    return result
  }
}

/// Custom callback failures cross the same safe diagnostic boundary. Retain
/// only sanitized text, not the original Error, userInfo, or an unsafe cause.
struct CheckerExecutionError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
  let description: String
  var debugDescription: String { description }
  var errorDescription: String? { description }
}
