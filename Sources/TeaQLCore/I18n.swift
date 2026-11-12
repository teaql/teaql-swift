import Foundation

public enum TeaQLLocale: String, CaseIterable, Sendable, Codable { case en, zhCN="zh-CN", zhTW="zh-TW", ja, ko, de, fr, es, pt, ar, th, id, fil, uk, vi
  public static func parse(_ code:String)throws->Self{let n=code.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"_",with:"-").lowercased();if let value=allCases.first(where:{$0.rawValue.lowercased()==n}){return value};if let value=aliases[n]{return value};throw UnsupportedLocaleError(localeCode:code)}
  private static let aliases:[String:Self]=["en-us":.en,"en-gb":.en,"zh":.zhCN,"zh-hans":.zhCN,"zh-sg":.zhCN,"cn":.zhCN,"zh-hant":.zhTW,"zh-hk":.zhTW,"zh-mo":.zhTW,"tw":.zhTW,"ja-jp":.ja,"ko-kr":.ko,"de-de":.de,"fr-fr":.fr,"es-mx":.es,"pt-br":.pt,"pt-pt":.pt,"ar-sa":.ar,"th-th":.th,"id-id":.id,"tl":.fil,"fil-ph":.fil,"uk-ua":.uk,"vi-vn":.vi]
}
public struct UnsupportedLocaleError:Error,Equatable,Sendable{public let localeCode:String}
public struct CheckResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let ruleID: String
  public let location: ObjectLocation
  public let inputValue: String?
  public let systemValue: String?
  private var storedMessage: String?
  public var message: String? {
    get { storedMessage }
    set {
      storedMessage = newValue
      presentation?.automaticMessage = false
      presentation?.messageEdited = true
    }
  }
  public let entityType: String?
  public let sourceInstancePath: String?
  // Safe alternatives and original length only; never a Context or raw-secret list.
  var presentation: CheckerPresentation?
  var naturalPresentation: CheckerNaturalBinding?
  var observedLength: Int?
  var observedLengthUnit: CheckerLengthUnit?

  public init(ruleID: String, location: ObjectLocation, inputValue: String? = nil,
              systemValue: String? = nil, message: String? = nil, entityType: String? = nil,
              sourceInstancePath: String? = nil) {
    self.ruleID = ruleID; self.location = location; self.inputValue = inputValue
    self.systemValue = systemValue; self.storedMessage = message
    self.entityType = entityType; self.sourceInstancePath = sourceInstancePath
  }

  func replacing(location: ObjectLocation? = nil, entityType: String? = nil,
                 sourceInstancePath: String? = nil) -> Self {
    var result = Self(ruleID: ruleID, location: location ?? self.location, inputValue: inputValue,
      systemValue: systemValue, message: storedMessage, entityType: entityType ?? self.entityType,
      sourceInstancePath: sourceInstancePath ?? self.sourceInstancePath)
    result.presentation = presentation
    result.naturalPresentation = naturalPresentation
    result.observedLength = observedLength
    result.observedLengthUnit = observedLengthUnit
    return result
  }
  /// Attach the exact measurement made by a checker before presentation/masking.
  /// This does not alter the wire DTO or change the checker's counting rule.
  public func withLengthMeasurement(_ measurement: CheckerLengthMeasurement) -> Self {
    var result = self; result.observedLength = measurement.count; result.observedLengthUnit = measurement.unit; return result
  }
  func withNaturalPresentation(_ message: String, snapshot: CheckerMessagePresentation, plan: CheckerMessagePlan) -> Self {
    var result = self; result.storedMessage = message
    if var state = result.presentation {
      state = CheckerPresentation(safeInput:state.safeInput,safeSystem:state.safeSystem,safeMessage:message,
        inputLength:state.inputLength,masked:state.masked,credential:state.credential,sensitive:state.sensitive,automaticMessage:true)
      result.presentation = state
    }
    result.naturalPresentation = CheckerNaturalBinding(snapshot:snapshot,automaticMessage:message,plan:plan)
    return result
  }
  /// Rebase structural identity without changing the original submitted path
  /// or the declaring child Checker. Relocalize with the caller's context when
  /// the message comes from a catalog template.
  public func prefixed(by prefix: ObjectLocation) -> Self {
    replacing(location: location.prefixed(by: prefix))
  }
  func bindingDeclaringEntity(_ declaringEntityType: String) -> Self {
    if let entityType, !entityType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return self }
    return replacing(entityType: declaringEntityType)
  }
  public func wire(profile: JsonFieldNamingProfile = .camelCase) -> WireCheckResult {
    let safe = CheckerPrivacy.project(self, allowPlaintext: false)
    let segments = location.segments.map { segment in
      switch segment {
      case .property(let name): WireLocationSegment(kind: "property", name: name)
      case .index(let index): WireLocationSegment(kind: "index", index: index)
      }
    }
    return WireCheckResult(ruleID: ruleID, entityType: entityType, location: segments,
      instancePath: location.instancePath(profile: profile), sourceInstancePath: sourceInstancePath,
      inputValue: safe.inputValue, systemValue: safe.systemValue, message: safe.message)
  }
  public var description: String {
    let safe = CheckerPrivacy.project(self, allowPlaintext: false)
    return "CheckResult(ruleID: \(ruleID), location: \(location.nativePath), inputValue: \(safe.inputValue ?? "[omitted]"), systemValue: \(safe.systemValue ?? "[omitted]"), message: \(safe.message ?? "[omitted]"))"
  }
  public var debugDescription: String { description }
}
public struct WireLocationSegment:Sendable,Codable,Equatable{public let kind:String;public let name:String?;public let index:Int?;public init(kind:String,name:String?=nil,index:Int?=nil){self.kind=kind;self.name=name;self.index=index}}
public struct WireCheckResult:Sendable,Codable{public let ruleId:String;public let entityType:String?;public let location:[WireLocationSegment];public let instancePath:String;public let sourceInstancePath:String?;public let inputValue:String?;public let systemValue:String?;public let message:String?;public init(ruleID:String,entityType:String?,location:[WireLocationSegment],instancePath:String,sourceInstancePath:String?,inputValue:String?,systemValue:String?,message:String?){self.ruleId=ruleID;self.entityType=entityType;self.location=location;self.instancePath=instancePath;self.sourceInstancePath=sourceInstancePath;self.inputValue=inputValue;self.systemValue=systemValue;self.message=message}}
private struct CatalogLocale:Codable,Sendable{let messages:[String:String];let vocabulary:[String:String]}
private struct CatalogFile:Codable,Sendable{let schema:String;let defaultLocale:String;let locales:[String:CatalogLocale]}
/// Immutable catalog shared by every context unless an application supplies
/// an override.  This is deliberately a reference type: Swift 6.3 on Linux
/// can race while copying a lazily initialized static value-type catalog from
/// concurrent default-argument evaluation.  An immutable final instance keeps
/// the shared default both cheap and safe to publish.
public final class I18nCatalog:@unchecked Sendable{
  private let file:CatalogFile;private let fallback:CatalogFile?
  public static let builtin:I18nCatalog={let url=Bundle.module.url(forResource:"builtin-messages-v1",withExtension:"json")!;return try! I18nCatalog(data:Data(contentsOf:url))}()
  public init(data:Data,fallback:I18nCatalog?=nil)throws{let value=try JSONDecoder().decode(CatalogFile.self,from:data);guard value.schema=="teaql.i18n/v1" else{throw CocoaError(.fileReadCorruptFile)};for code in value.locales.keys{_ = try TeaQLLocale.parse(code)};file=value;self.fallback=fallback?.file}
  public func message(_ locale:TeaQLLocale,_ key:String)->String{file.locales[locale.rawValue]?.messages[key] ?? fallback?.locales[locale.rawValue]?.messages[key] ?? file.locales["en"]?.messages[key] ?? fallback?.locales["en"]?.messages[key] ?? key}
  func applicationMessage(_ locale: TeaQLLocale, _ key: String) -> String? {
    self === Self.builtin ? nil : file.locales[locale.rawValue]?.messages[key]
  }
  public func translate(_ source: CheckResult, locale: TeaQLLocale) -> CheckResult {
    CheckerPrivacy.project(source, catalog: self, locale: locale)
  }
}
