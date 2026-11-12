import Foundation

public enum CheckerMessageResourceError: Error, Sendable { case invalid }
public enum CheckerMessageShape: String, CaseIterable, Sendable { case one, two, deep }

enum CheckerMessageJSON {
  static func invalid() -> CheckerMessageResourceError { .invalid }
  static func object(_ value: Any?, allowed: Set<String>? = nil) throws -> [String: Any] {
    guard let result = value as? [String: Any], allowed.map({ Set(result.keys).isSubset(of: $0) }) ?? true else { throw invalid() }
    return result
  }
  static func text(_ value: Any?) throws -> String {
    guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid() }; return text
  }
  static func resource(_ name: String) -> Data {
    // Warm these immutable resources during Context composition, never error rendering.
    try! Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json")!)
  }
  static func parse(_ data: Data) throws -> [String: Any] {
    // Foundation dictionaries discard duplicate keys. Inspect the token stream
    // first, including escaped keys, before decoding any resource into a map.
    var scanner = UniqueJSON(bytes: Array(data)); try scanner.value(depth: 0); scanner.space()
    guard scanner.offset == scanner.bytes.count else { throw invalid() }
    return try object(JSONSerialization.jsonObject(with: data))
  }
  private struct UniqueJSON {
    let bytes: [UInt8]; var offset = 0
    mutating func space() { while offset < bytes.count && [9,10,13,32].contains(bytes[offset]) { offset += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { space(); if offset < bytes.count && bytes[offset] == byte { offset += 1; return true }; return false }
    mutating func string() throws -> String {
      space(); let start = offset; guard take(34) else { throw invalid() }
      var escaped = false
      while offset < bytes.count {
        let byte = bytes[offset]; offset += 1
        if !escaped && byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
        if !escaped && byte == 92 { escaped = true } else { escaped = false }
      }
      throw invalid()
    }
    mutating func value(depth: Int) throws {
      space(); guard depth < 128, offset < bytes.count else { throw invalid() }
      if take(123) {
        var keys = Set<String>(); if take(125) { return }
        repeat { let key = try string(); guard keys.insert(key).inserted, take(58) else { throw invalid() }; try value(depth: depth+1)
          if take(125) { return }; guard take(44) else { throw invalid() }
        } while true
      } else if take(91) {
        if take(93) { return }
        repeat { try value(depth: depth+1); if take(93) { return }; guard take(44) else { throw invalid() } } while true
      } else if bytes[offset] == 34 { _ = try string() }
      else {
        let start = offset
        while offset < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[offset]) { offset += 1 }
        guard offset > start else { throw invalid() }
      }
    }
  }
}

enum CheckerTemplateNode: Sendable { case literal(String), argument(String) }
struct CheckerMessageTemplate: Sendable {
  let nodes: [CheckerTemplateNode]
  init(nodes: [CheckerTemplateNode]) { self.nodes = nodes }
  init(_ source: String, allowed: Set<String>, required: Set<String>) throws {
    _ = try CheckerMessageJSON.text(source); let chars = Array(source); var offset = 0, literal = "", result: [CheckerTemplateNode] = [], seen = Set<String>()
    while offset < chars.count {
      let value = chars[offset]
      if (value == "{" || value == "}") && offset+1 < chars.count && chars[offset+1] == value { literal.append(value); offset += 2; continue }
      if value == "}" { throw CheckerMessageJSON.invalid() }
      if value != "{" { literal.append(value); offset += 1; continue }
      guard let end = chars[(offset+1)...].firstIndex(of: "}") else { throw CheckerMessageJSON.invalid() }
      let name = String(chars[(offset+1)..<end]); guard allowed.contains(name) else { throw CheckerMessageJSON.invalid() }
      if !literal.isEmpty { result.append(.literal(literal)); literal = "" }; result.append(.argument(name)); seen.insert(name); offset = end+1
    }
    if !literal.isEmpty { result.append(.literal(literal)) }; guard required.isSubset(of: seen) else { throw CheckerMessageJSON.invalid() }; nodes = result
  }
  func render(_ arguments: [String: String]) -> String { nodes.map { switch $0 { case .literal(let text): text; case .argument(let name): arguments[name] ?? "-" } }.joined() }
  func project(_ project: (String) -> String) -> Self { Self(nodes: nodes.map { if case .literal(let text) = $0 { return .literal(project(text)) }; return $0 }) }
}

public struct CheckerMessageSelection: Sendable {
  public let locale: TeaQLLocale
  let template: CheckerMessageTemplate
  let application: Bool
  public func render(_ arguments: [String: String]) -> String { template.render(arguments) }
  func project(_ project: (String) -> String) -> Self { Self(locale: locale, template: template.project(project), application: application) }
}

public final class CheckerMessageCatalog: Sendable {
  private struct Patterns: Sendable { let reference: CheckerMessageTemplate; let item: CheckerMessageTemplate; let separator: String }
  private struct Entry: Sendable { let rules: [String: [CheckerMessageShape: CheckerMessageTemplate]]; let patterns: Patterns? }
  private let entries: [TeaQLLocale: Entry]
  private let application: Bool
  public static let builtin = try! CheckerMessageCatalog(data: CheckerMessageJSON.resource("natural-messages-v1"), complete: true)
  private init(entries: [TeaQLLocale: Entry], application: Bool = false) { self.entries = entries; self.application = application }
  public convenience init(data: Data) throws { try self.init(data: data, complete: false) }
  private init(data: Data, complete: Bool) throws {
    let root = try CheckerMessageJSON.parse(data)
    _ = try CheckerMessageJSON.object(root, allowed: ["schema","defaultLocale","locales"])
    guard root["schema"] as? String == "teaql.checker-messages/v1", root["defaultLocale"] as? String == "en" else { throw CheckerMessageJSON.invalid() }
    var entries: [TeaQLLocale: Entry] = [:]
    for (code, rawEntry) in try CheckerMessageJSON.object(root["locales"]) {
      let locale = try TeaQLLocale.parse(code); guard entries[locale] == nil else { throw CheckerMessageJSON.invalid() }
      let entry = try CheckerMessageJSON.object(rawEntry, allowed: ["rules","locationPatterns"]); var rules: [String: [CheckerMessageShape: CheckerMessageTemplate]] = [:]
      for (rule, rawShapes) in try CheckerMessageJSON.object(entry["rules"] ?? [:]) {
        guard rule.hasPrefix("checker."), rule.count > 8 else { throw CheckerMessageJSON.invalid() }
        var shapes: [CheckerMessageShape: CheckerMessageTemplate] = [:]
        for (shapeName, rawTemplate) in try CheckerMessageJSON.object(rawShapes) {
          guard let shape = CheckerMessageShape(rawValue: shapeName) else { throw CheckerMessageJSON.invalid() }
          var allowed: Set<String> = ["field","system","input","input_len","unit"], required: Set<String> = ["field"]
          switch rule {
          case "checker.required","checker.invalid": allowed = ["field"]
          case "checker.min","checker.max": allowed = ["field","system","input"]; required.insert("system")
          case "checker.minLength","checker.maxLength": allowed = ["field","system","input_len","unit"]; required.formUnion(["system","input_len","unit"])
          default: break
          }
          if shape != .one { let owner = shape == .two ? "object" : "objectPath"; allowed.insert(owner); required.insert(owner) }
          shapes[shape] = try CheckerMessageTemplate(CheckerMessageJSON.text(rawTemplate), allowed: allowed, required: required)
        }
        rules[rule] = shapes
      }
      var patterns: Patterns?
      if let raw = entry["locationPatterns"] {
        let object = try CheckerMessageJSON.object(raw, allowed: ["reference","item","separator"])
        let reference = try CheckerMessageTemplate(CheckerMessageJSON.text(object["reference"]), allowed: ["relation"], required: ["relation"])
        let item = try CheckerMessageTemplate(CheckerMessageJSON.text(object["item"]), allowed: ["relation","position","ordinal","classifier"], required: ["relation"])
        guard item.nodes.contains(where: { if case .argument(let name) = $0 { return name == "position" || name == "ordinal" }; return false }) else { throw CheckerMessageJSON.invalid() }
        let separator = try CheckerMessageJSON.text(object["separator"])
        guard !separator.contains("{"), !separator.contains("}"), !separator.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CheckerMessageJSON.invalid() }
        patterns = Patterns(reference: reference, item: item, separator: separator)
      }
      entries[locale] = Entry(rules: rules, patterns: patterns)
    }
    if complete { for locale in TeaQLLocale.allCases {
      guard let entry = entries[locale], entry.patterns != nil else { throw CheckerMessageJSON.invalid() }
      for rule in ["checker.required","checker.min","checker.max","checker.minLength","checker.maxLength","checker.invalid"] {
        for shape in CheckerMessageShape.allCases { guard entry.rules[rule]?[shape] != nil else { throw CheckerMessageJSON.invalid() } }
      }
    } }
    self.entries = entries; application = !complete
  }
  public func lookup(_ locale: TeaQLLocale, rule: String, shape: CheckerMessageShape) -> CheckerMessageSelection? {
    guard let template = entries[locale]?.rules[rule]?[shape] else { return nil }; return CheckerMessageSelection(locale: locale, template: template, application: application)
  }
  func override(_ locale: TeaQLLocale, rule: String, shape: CheckerMessageShape) -> CheckerMessageSelection? { application ? lookup(locale, rule: rule, shape: shape) : nil }
  public func select(_ locale: TeaQLLocale, rule: String, shape: CheckerMessageShape) -> CheckerMessageSelection {
    for candidate in [locale,.en] { if let found = lookup(candidate, rule: rule, shape: shape) ?? Self.builtin.lookup(candidate, rule: rule, shape: shape) { return found } }
    return Self.builtin.lookup(locale, rule: "checker.invalid", shape: shape)!
  }
  private func patterns(_ locale: TeaQLLocale) -> Patterns { entries[locale]?.patterns ?? Self.builtin.entries[locale]!.patterns! }
  func projectPatterns(_ locale: TeaQLLocale, _ project: (String) -> String) -> CheckerMessageCatalog {
    guard self !== Self.builtin, let original = entries[locale]?.patterns else { return Self.builtin }
    return CheckerMessageCatalog(entries: [locale: Entry(rules: [:], patterns: Patterns(reference: original.reference.project(project), item: original.item.project(project), separator: project(original.separator)))])
  }
  public func reference(_ locale: TeaQLLocale, label: String) -> String { patterns(locale).reference.render(["relation":label]) }
  func item(_ locale: TeaQLLocale, label: String, index: Int, classifier: String) -> String {
    // Avoid Int overflow for a valid zero-based selector at the platform limit.
    let position = UInt64(index) + 1
    return patterns(locale).item.render(["relation":label,"position":String(position),"ordinal":Self.ordinal(position),"classifier":classifier])
  }
  public func separator(_ locale: TeaQLLocale) -> String { patterns(locale).separator }
  public static func ordinal(_ position: UInt64) -> String {
    let suffix = (11...13).contains(position % 100) ? "th" : [1:"st",2:"nd",3:"rd"][position % 10] ?? "th"
    return String(position) + suffix
  }
}
