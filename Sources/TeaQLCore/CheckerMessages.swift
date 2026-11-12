import Foundation

public struct CheckerMessageRequest: Sendable {
  public let presentation: CheckerMessagePresentation
  public let catalog: CheckerMessageCatalog
  public let selection: CheckerMessageSelection
  public let arguments: [String: String]
}
public typealias CheckerMessageRenderer = @Sendable (CheckerMessageRequest) throws -> CheckerMessageOutput
public typealias CheckerMessageWarningSink = @Sendable (CheckerMessageWarning) -> Void

final class CheckerMessageServices: Sendable {
  let model: CheckerPresentationModel; let catalog: CheckerMessageCatalog
  let renderer: CheckerMessageRenderer?; let warning: CheckerMessageWarningSink
  init(model: CheckerPresentationModel = .empty, catalog: CheckerMessageCatalog = .builtin,
       renderer: CheckerMessageRenderer? = nil, warning: @escaping CheckerMessageWarningSink = { code in
         FileHandle.standardError.write(Data((code.rawValue+"\n").utf8))
       }) { self.model = model; self.catalog = catalog; self.renderer = renderer; self.warning = warning; _ = CheckerMessageWords.additionalUnits }
  func replacing(model: CheckerPresentationModel? = nil, catalog: CheckerMessageCatalog? = nil,
    renderer: CheckerMessageRenderer? = nil, warning: CheckerMessageWarningSink? = nil) -> CheckerMessageServices {
    CheckerMessageServices(model:model ?? self.model,catalog:catalog ?? self.catalog,renderer:renderer ?? self.renderer,warning:warning ?? self.warning)
  }
}
package struct CheckerMessageConfiguration: Sendable { let services: CheckerMessageServices; let locale: TeaQLLocale; let legacy: I18nCatalog }
struct CheckerNaturalBinding: Sendable { let snapshot: CheckerMessagePresentation; let automaticMessage: String?; let plan: CheckerMessagePlan? }
struct CheckerMessagePlan: Sendable {
  struct Key: Hashable, Sendable { let locale: TeaQLLocale; let shape: CheckerMessageShape }
  struct Entry: Sendable { let selection: CheckerMessageSelection?; let catalog: CheckerMessageCatalog; let legacy: CheckerMessageTemplate?; let generic: Bool }
  let entries: [Key: Entry]; let literal: String?
  init(literal: String) { self.entries = [:]; self.literal = literal }
  init(entries: [Key: Entry]) { self.entries = entries; literal = nil }
  static func prepare(_ config: CheckerMessageConfiguration, rule: String, project: (String) -> String) -> Self {
    var entries: [Key: Entry] = [:], patterns: [TeaQLLocale: CheckerMessageCatalog] = [:]
    for locale in TeaQLLocale.allCases { for shape in CheckerMessageShape.allCases {
      var selection: CheckerMessageSelection?, legacy: CheckerMessageTemplate?
      for candidate in [locale,.en] {
        if let found = config.services.catalog.override(candidate,rule:rule,shape:shape) { selection = found.project(project); break }
        if let source = config.legacy.applicationMessage(candidate,rule) {
          // Legacy catalogs retain their historical four-placeholder contract.
          let regex = try! NSRegularExpression(pattern:"\\{(location|system|input|input_len)\\}")
          var nodes: [CheckerTemplateNode] = [], cursor = source.startIndex
          for match in regex.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
            let range = Range(match.range,in:source)!, name = Range(match.range(at:1),in:source)!
            nodes.append(.literal(project(String(source[cursor..<range.lowerBound])))); nodes.append(.argument(String(source[name]))); cursor = range.upperBound
          }
          nodes.append(.literal(project(String(source[cursor...])))); legacy = CheckerMessageTemplate(nodes:nodes); break
        }
        if let found = CheckerMessageCatalog.builtin.lookup(candidate,rule:rule,shape:shape) { selection = found; break }
      }
      let generic = selection == nil && legacy == nil
      if generic { selection = CheckerMessageCatalog.builtin.select(locale,rule:"checker.invalid",shape:shape) }
      let effective = selection?.locale ?? locale
      if patterns[effective] == nil { patterns[effective] = config.services.catalog.projectPatterns(effective,project) }
      entries[Key(locale:locale,shape:shape)] = Entry(selection:selection,catalog:patterns[effective]!,legacy:legacy,generic:generic)
    } }
    return Self(entries:entries)
  }
  func projected(_ project: (String) -> String) -> Self {
    if let literal { return Self(literal:project(literal)) }
    return Self(entries:entries.mapValues { entry in
      Entry(selection:entry.selection.map { $0.application ? $0.project(project) : $0 },
        catalog:entry.catalog.projectPatterns(entry.selection?.locale ?? .en,project),legacy:entry.legacy?.project(project),generic:entry.generic)
    })
  }
  func render(_ snapshot: CheckerMessagePresentation, result: CheckResult, locale: TeaQLLocale) -> CheckerMessageOutput {
    if let literal { return CheckerMessageOutput(literal) }
    let item = entries[Key(locale:locale,shape:snapshot.shape)]!
    var arguments = CheckerMessages.arguments(result,locale:item.selection?.locale ?? locale)
    if let legacy = item.legacy { arguments["location"] = result.location.nativePath; return CheckerMessageOutput(legacy.render(arguments)) }
    let output = snapshot.render(catalog:item.catalog,selection:item.selection!,arguments:arguments)
    return CheckerMessageOutput(output.message,warnings:output.warnings+(item.generic ? [.genericRule] : []))
  }
}

enum CheckerMessages {
  static func rule(_ value: String) -> String {
    "checker." + (["required":"required","min":"min","max":"max","min_length":"minLength","max_length":"maxLength","min_str_len":"minLength","max_str_len":"maxLength"][value.lowercased()] ?? value.lowercased())
  }
  static func automatic(_ value: CheckResult) -> Bool {
    value.message == nil || value.naturalPresentation?.automaticMessage == value.message && value.naturalPresentation != nil || value.presentation?.automaticMessage == true
  }
  static func bind(_ source: CheckResult, model: CheckerPresentationModel, origin: String) -> CheckResult {
    var value = source
    if let snapshot = try? CheckerMessagePresentation(model:model,origin:origin,location:source.location) {
      value.naturalPresentation = CheckerNaturalBinding(snapshot:snapshot,automaticMessage:automatic(source) ? source.message : nil,plan:automatic(source) ? source.naturalPresentation?.plan : nil)
    }
    return value
  }
  static func arguments(_ value: CheckResult, locale: TeaQLLocale) -> [String: String] {
    ["input":CheckerMessageWords.sanitize(value.presentation?.safeInput ?? "[omitted]"),"system":CheckerMessageWords.sanitize(value.presentation?.safeSystem ?? value.systemValue ?? "[omitted]"),
      "input_len":value.presentation?.inputLength.map(String.init) ?? "[omitted]","unit":CheckerMessageWords.lengthUnit(locale,value.observedLengthUnit ?? .scalar)]
  }
  static func translate(_ sources: [CheckResult], config: CheckerMessageConfiguration, runtime: TeaQLRuntime,
    owner: EntityDescriptor? = nil, scope: CheckerPrivateScope = CheckerPrivateScope(), origin: String? = nil) -> [CheckResult] {
    var combined = scope
    for value in sources { combined.append(CheckerPrivacy.prepared(value,runtime:runtime,owner:owner,scope:scope).scope) }
    var seen = Set<CheckerMessageWarning>()
    func warn(_ warning: CheckerMessageWarning) { if seen.insert(warning).inserted { config.services.warning(warning) } }
    return sources.map { source in
      var result = CheckerPrivacy.project(source,runtime:runtime,owner:owner,scope:combined)
      guard automatic(source) else { return result }
      let model = origin != nil ? config.services.model : source.naturalPresentation?.snapshot.model ?? config.services.model
      let resolved = origin ?? source.naturalPresentation?.snapshot.origin
      let snapshot = (try? CheckerMessagePresentation(model:model,origin:resolved,location:source.location))
        ?? (try! CheckerMessagePresentation(model:.empty,origin:nil,location:ObjectLocation()))
      func project(_ text: String) -> String { CheckerPrivacy.scrub(text,secrets:combined.safe) ?? "" }
      var plan = source.naturalPresentation?.plan?.projected(project)
      let output: CheckerMessageOutput
      do {
        if plan == nil {
          plan = CheckerMessagePlan.prepare(config,rule:rule(source.ruleID),project:project)
          let item = plan!.entries[.init(locale:config.locale,shape:snapshot.shape)]!
          if let renderer = config.services.renderer, item.legacy == nil {
            if item.generic { warn(.genericRule) }
            let rendered = try renderer(CheckerMessageRequest(presentation:snapshot,catalog:item.catalog,selection:item.selection!,arguments:arguments(result,locale:item.selection!.locale)))
            output = CheckerMessageOutput(project(rendered.message),warnings:rendered.warnings); plan = CheckerMessagePlan(literal:output.message)
          } else { output = plan!.render(snapshot,result:result,locale:config.locale) }
        } else { output = plan!.render(snapshot,result:result,locale:config.locale) }
        guard !output.message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CheckerMessageJSON.invalid() }
      } catch {
        warn(.renderFallback)
        let fallback = snapshot.render(catalog:.builtin,selection:CheckerMessageCatalog.builtin.select(config.locale,rule:"checker.invalid",shape:snapshot.shape),arguments:[:])
        for warning in fallback.warnings { warn(warning) }
        return result.withNaturalPresentation(fallback.message,snapshot:snapshot,plan:CheckerMessagePlan(literal:fallback.message))
      }
      for warning in output.warnings { warn(warning) }
      result = result.withNaturalPresentation(output.message,snapshot:snapshot,plan:plan!)
      return result
    }
  }
}
