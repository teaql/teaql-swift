import Foundation

public enum TeaQLLocale: String, CaseIterable, Sendable, Codable { case en, zhCN="zh-CN", zhTW="zh-TW", ja, ko, de, fr, es, pt, ar, th, id, fil, uk, vi
  public static func parse(_ code:String)throws->Self{let n=code.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"_",with:"-").lowercased();if let value=allCases.first(where:{$0.rawValue.lowercased()==n}){return value};if let value=aliases[n]{return value};throw UnsupportedLocaleError(localeCode:code)}
  private static let aliases:[String:Self]=["en-us":.en,"en-gb":.en,"zh":.zhCN,"zh-hans":.zhCN,"zh-sg":.zhCN,"cn":.zhCN,"zh-hant":.zhTW,"zh-hk":.zhTW,"zh-mo":.zhTW,"tw":.zhTW,"ja-jp":.ja,"ko-kr":.ko,"de-de":.de,"fr-fr":.fr,"es-mx":.es,"pt-br":.pt,"pt-pt":.pt,"ar-sa":.ar,"th-th":.th,"id-id":.id,"tl":.fil,"fil-ph":.fil,"uk-ua":.uk,"vi-vn":.vi]
}
public struct UnsupportedLocaleError:Error,Equatable,Sendable{public let localeCode:String}
public struct CheckResult:Sendable{public let ruleID:String;public let location:ObjectLocation;public let inputValue:String?;public let systemValue:String?;public var message:String?;public init(ruleID:String,location:ObjectLocation,inputValue:String?=nil,systemValue:String?=nil,message:String?=nil){self.ruleID=ruleID;self.location=location;self.inputValue=inputValue;self.systemValue=systemValue;self.message=message}}
private struct CatalogLocale:Codable,Sendable{let messages:[String:String];let vocabulary:[String:String]}
private struct CatalogFile:Codable,Sendable{let schema:String;let defaultLocale:String;let locales:[String:CatalogLocale]}
public struct I18nCatalog:Sendable{
  private let file:CatalogFile;private let fallback:CatalogFile?
  public static let builtin:I18nCatalog={let url=Bundle.module.url(forResource:"builtin-messages-v1",withExtension:"json")!;return try! I18nCatalog(data:Data(contentsOf:url))}()
  public init(data:Data,fallback:I18nCatalog?=nil)throws{let value=try JSONDecoder().decode(CatalogFile.self,from:data);guard value.schema=="teaql.i18n/v1" else{throw CocoaError(.fileReadCorruptFile)};for code in value.locales.keys{_ = try TeaQLLocale.parse(code)};file=value;self.fallback=fallback?.file}
  public func message(_ locale:TeaQLLocale,_ key:String)->String{file.locales[locale.rawValue]?.messages[key] ?? fallback?.locales[locale.rawValue]?.messages[key] ?? file.locales["en"]?.messages[key] ?? fallback?.locales["en"]?.messages[key] ?? key}
  public func translate(_ source:CheckResult,locale:TeaQLLocale)->CheckResult{var result=source;let keys=["required":"checker.required","min":"checker.min","max":"checker.max","min_str_len":"checker.minLength","min_length":"checker.minLength","max_str_len":"checker.maxLength","max_length":"checker.maxLength"];let key=keys[result.ruleID.lowercased()] ?? "checker.\(result.ruleID.lowercased())";result.message=message(locale,key).replacingOccurrences(of:"{location}",with:result.location.nativePath).replacingOccurrences(of:"{system}",with:result.systemValue ?? "nil").replacingOccurrences(of:"{input}",with:result.inputValue ?? "nil").replacingOccurrences(of:"{input_len}",with:String(result.inputValue?.count ?? 0));return result}
}
