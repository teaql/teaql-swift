import Foundation

public enum CheckerLengthUnit: String, Sendable { case scalar, utf16, byte, grapheme }
public struct CheckerLengthMeasurement: Sendable {
  public let count: Int
  public let unit: CheckerLengthUnit
  public init(_ count: Int, unit: CheckerLengthUnit) throws {
    guard count >= 0 else { throw CheckerMessageResourceError.invalid }; self.count = count; self.unit = unit
  }
}

public enum CheckerMessageWarning: String, Hashable, Sendable {
  case labelFallback = "CHECKER_MESSAGE_LABEL_FALLBACK"
  case genericRule = "CHECKER_MESSAGE_GENERIC_RULE"
  case renderFallback = "CHECKER_MESSAGE_RENDER_FALLBACK"
}
public struct CheckerMessageOutput: Sendable {
  public let message: String
  public let warnings: [CheckerMessageWarning]
  public init(_ message: String, warnings: [CheckerMessageWarning] = []) { self.message = message; self.warnings = warnings }
}
struct CheckerMessageField: Sendable, Equatable {
  let name: String; let target: String?
  let labels: [TeaQLLocale: String]; let classifiers: [TeaQLLocale: String]
}
struct CheckerMessageEntity: Sendable, Equatable {
  let labels: [TeaQLLocale: String]; let fields: [String: CheckerMessageField]
}

enum CheckerMessageWords {
  static let additionalUnits: [TeaQLLocale: [String: String]] = {
    let root = try! CheckerMessageJSON.parse(CheckerMessageJSON.resource("additional-length-units-v1"))
    precondition(root["schema"] as? String == "teaql.checker-additional-length-units/v1")
    var result: [TeaQLLocale: [String: String]] = [:]
    for (code, raw) in try! CheckerMessageJSON.object(root["locales"]) {
      result[try! TeaQLLocale.parse(code)] = try! CheckerMessageJSON.object(raw).mapValues { try CheckerMessageJSON.text($0) }
    }
    for locale in TeaQLLocale.allCases { precondition(result[locale]?["grapheme"] != nil) }
    return result
  }()
  static let words: [TeaQLLocale: [String: String]] = {
    let root = try! CheckerMessageJSON.parse(CheckerMessageJSON.resource("checker-presentation-v1"))
    precondition(root["schema"] as? String == "teaql.checker-presentation/v1")
    var values: [TeaQLLocale: [String: String]] = [:]
    for (code, object) in try! CheckerMessageJSON.object(root["locales"]) {
      values[try! TeaQLLocale.parse(code)] = try! CheckerMessageJSON.object(object).mapValues { try CheckerMessageJSON.text($0) }
    }
    for locale in TeaQLLocale.allCases { for key in ["currentObject","utf16","scalar","byte"] { precondition(values[locale]?[key] != nil) } }
    return values
  }()
  static func get(_ locale: TeaQLLocale, _ key: String) -> String { words[locale]![key]! }
  static func lengthUnit(_ locale: TeaQLLocale, _ unit: CheckerLengthUnit) -> String {
    unit == .grapheme ? additionalUnits[locale]!["grapheme"]! : get(locale,unit.rawValue)
  }
  static func sanitize(_ source: String) -> String {
    String(String.UnicodeScalarView(source.unicodeScalars.map { scalar in
      switch scalar.properties.generalCategory {
      case .control,.format,.lineSeparator,.paragraphSeparator: Unicode.Scalar(32)!
      default: scalar
      }
    })).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func labels(_ raw: Any?) throws -> [TeaQLLocale: String] {
    guard let raw else { return [:] }; var values: [TeaQLLocale: String] = [:]
    for (code, text) in try CheckerMessageJSON.object(raw) {
      let locale = try TeaQLLocale.parse(code); guard values[locale] == nil else { throw CheckerMessageJSON.invalid() }
      values[locale] = try CheckerMessageJSON.text(text)
    }
    return values
  }
}

/// Shared immutable descriptors; no entity values, IDs, Context or lazy I/O.
public final class CheckerPresentationModel: Sendable {
  public let revision: String
  let entities: [String: CheckerMessageEntity]
  let currentObject: [TeaQLLocale: String]
  public static let empty = CheckerPresentationModel(revision: "unconfigured", entities: [:], currentObject:
    Dictionary(uniqueKeysWithValues: TeaQLLocale.allCases.map { ($0,CheckerMessageWords.get($0,"currentObject")) }))
  private init(revision: String, entities: [String: CheckerMessageEntity], currentObject: [TeaQLLocale: String]) {
    self.revision = revision; self.entities = entities; self.currentObject = currentObject
  }
  public convenience init(data: Data) throws {
    let root = try CheckerMessageJSON.parse(data)
    _ = try CheckerMessageJSON.object(root, allowed: ["schema","revision","entities","currentObject"])
    guard root["schema"] as? String == "teaql.checker-model/v1" else { throw CheckerMessageJSON.invalid() }
    var entities: [String: CheckerMessageEntity] = [:]
    for (identity, raw) in try CheckerMessageJSON.object(root["entities"]) {
      _ = try CheckerMessageJSON.text(identity); let entity = try CheckerMessageJSON.object(raw, allowed: ["labels","fields"])
      guard let rawFields = entity["fields"] as? [Any] else { throw CheckerMessageJSON.invalid() }
      var fields: [String: CheckerMessageField] = [:]
      for rawField in rawFields {
        let field = try CheckerMessageJSON.object(rawField, allowed: ["name","targetType","labels","classifiers","aliases"])
        let name = try CheckerMessageJSON.text(field["name"])
        let target = try field["targetType"].map { try CheckerMessageJSON.text($0) }
        let descriptor = CheckerMessageField(name: name, target: target, labels: try CheckerMessageWords.labels(field["labels"]), classifiers: try CheckerMessageWords.labels(field["classifiers"]))
        let aliases: [String]
        if let rawAliases = field["aliases"] { guard let strings = rawAliases as? [String] else { throw CheckerMessageJSON.invalid() }; aliases = strings } else { aliases = [] }
        for alias in [name]+aliases { _ = try CheckerMessageJSON.text(alias); guard fields[alias] == nil else { throw CheckerMessageJSON.invalid() }; fields[alias] = descriptor }
      }
      entities[identity] = CheckerMessageEntity(labels: try CheckerMessageWords.labels(entity["labels"]), fields: fields)
    }
    var current = Self.empty.currentObject; current.merge(try CheckerMessageWords.labels(root["currentObject"])) { _,new in new }
    self.init(revision: try CheckerMessageJSON.text(root["revision"]), entities: entities, currentObject: current)
  }
  public func merging(_ other: CheckerPresentationModel) throws -> CheckerPresentationModel {
    if self === Self.empty { return other }; if other === Self.empty || self === other { return self }
    guard currentObject == other.currentObject else { throw CheckerMessageJSON.invalid() }; var combined = entities
    for (key, value) in other.entities { guard combined[key] == nil || combined[key] == value else { throw CheckerMessageJSON.invalid() }; combined[key] = value }
    return combined == entities ? self : CheckerPresentationModel(revision: revision+"+"+other.revision, entities: combined, currentObject: currentObject)
  }
}

public struct CheckerMessagePresentation: Sendable {
  private struct Step: Sendable { let identity: String?; let field: CheckerMessageField?; var indices: [Int] }
  public let model: CheckerPresentationModel
  public let origin: String?
  public let shape: CheckerMessageShape
  private let steps: [Step]
  public init(model: CheckerPresentationModel, origin: String?, location: ObjectLocation) throws {
    self.model = model; self.origin = origin
    var entity = origin.flatMap { model.entities[$0] }, unusual = origin.flatMap { model.entities[$0] } == nil, steps: [Step] = []
    for segment in location.segments {
      switch segment {
      case .property(let identity):
        let field = entity?.fields[identity]; entity = field?.target.flatMap { model.entities[$0] }
        steps.append(Step(identity: identity, field: field, indices: []))
      case .index(let index):
        guard index >= 0 else { throw CheckerMessageJSON.invalid() }
        if steps.isEmpty { steps.append(Step(identity: nil, field: nil, indices: [])); unusual = true }
        steps[steps.count-1].indices.append(index); unusual = unusual || steps.last!.indices.count > 1
      }
    }
    unusual = unusual || steps.isEmpty || !steps.last!.indices.isEmpty
    self.steps = steps; shape = unusual || steps.count > 2 ? .deep : steps.count == 1 ? .one : .two
  }
  public func relocated(_ location: ObjectLocation) throws -> Self { try Self(model: model, origin: origin, location: location) }
  public func render(catalog: CheckerMessageCatalog, selection: CheckerMessageSelection, arguments safe: [String: String]) -> CheckerMessageOutput {
    let locale = selection.locale; var warnings = Set<CheckerMessageWarning>()
    func label(_ labels: [TeaQLLocale: String]?, fallback: String) -> String {
      var result = labels?[locale]
      if result == nil { warnings.insert(.labelFallback); result = labels?[.en] }
      let text = CheckerMessageWords.sanitize(result ?? fallback.replacingOccurrences(of: "_", with: " "))
      return text.isEmpty ? CheckerMessageWords.get(locale,"currentObject") : text
    }
    let current = label(model.currentObject, fallback: "current object")
    let root = origin.flatMap { model.entities[$0] }.map { label($0.labels, fallback: origin!) } ?? current
    func fieldLabel(_ step: Step) -> String { label(step.field?.labels, fallback: step.field?.name ?? step.identity ?? "current object") }
    var arguments = safe.filter { ["system","input","input_len","unit"].contains($0.key) }
    let leaf = steps.last
    arguments["field"] = leaf?.identity != nil ? fieldLabel(leaf!) : root
    var owners: [String] = []
    let ownerCount = steps.count - (leaf?.identity != nil && leaf?.indices.isEmpty == true ? 1 : 0)
    for step in steps.prefix(ownerCount) {
      let relation = step.identity != nil ? fieldLabel(step) : root
      if step.indices.isEmpty { owners.append(catalog.reference(locale,label:relation)) }
      else { for (offset,index) in step.indices.enumerated() {
        let classifier = step.field?.classifiers[locale] ?? ([TeaQLLocale.zhCN,.zhTW].contains(locale) ? "项" : "")
        owners.append(catalog.item(locale,label:offset == 0 ? relation : current,index:index,classifier:CheckerMessageWords.sanitize(classifier)))
      } }
    }
    arguments["object"] = owners.first ?? root; arguments["objectPath"] = owners.isEmpty ? root : owners.joined(separator:catalog.separator(locale))
    return CheckerMessageOutput(selection.render(arguments),warnings:Array(warnings))
  }
}
