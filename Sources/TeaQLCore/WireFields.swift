import Foundation

public struct WireFieldMetadata: Sendable, Hashable {
  public let canonicalName: String; public let wireName: String; public let aliases: [String]
  public init(canonicalName:String, wireName:String, aliases:[String]=[]){self.canonicalName=canonicalName;self.wireName=wireName;self.aliases=aliases}
}
public struct WireEntityMetadata: Sendable {
  public let entityType:String; public let profile:JsonFieldNamingProfile; public let fields:[String:WireFieldMetadata]
  public init(entityType:String, canonicalFields:[String], profile:JsonFieldNamingProfile = .camelCase, aliases:[String:[String]]=[:]) throws {
    self.entityType=entityType; self.profile=profile; var built:[String:WireFieldMetadata]=[:]; var spellings:[String:String]=[:]
    for canonical in canonicalFields { let field=WireFieldMetadata(canonicalName:canonical,wireName:profile.render(canonical),aliases:aliases[canonical] ?? [])
      for spelling in [field.wireName]+field.aliases { if let previous=spellings[spelling],previous != canonical { throw WireInputError(code:.fieldCollision,instancePath:"",message:"Wire field spelling '\(spelling)' maps to both '\(previous)' and '\(canonical)'") };spellings[spelling]=canonical };built[canonical]=field }
    fields=built
  }
}
public struct NormalizedWireInput: Sendable { public let values:[String:TeaQLValue];public let sourceInstancePaths:[String:String] }
public struct WireInputError: Error, Sendable { public enum Code:String,Sendable{case unknownField="WIRE_UNKNOWN_FIELD",fieldCollision="WIRE_FIELD_COLLISION"};public let code:Code;public let instancePath:String;public let message:String }

public func normalizeWireInput(_ input:[String:TeaQLValue],metadata:WireEntityMetadata,parentPointer:String="") throws -> NormalizedWireInput {
  var lookup:[String:WireFieldMetadata]=[:];for field in metadata.fields.values { lookup[field.wireName]=field;for alias in field.aliases{lookup[alias]=field} }
  var values:[String:TeaQLValue]=[:],paths:[String:String]=[:],submitted:[String:String]=[:]
  for (name,value) in input { let pointer="\(parentPointer)/\(name.replacingOccurrences(of:"~",with:"~0").replacingOccurrences(of:"/",with:"~1"))";guard let field=lookup[name] else{throw WireInputError(code:.unknownField,instancePath:pointer,message:"Unknown \(metadata.entityType) field '\(name)'")};if let previous=submitted[field.canonicalName]{throw WireInputError(code:.fieldCollision,instancePath:pointer,message:"Fields '\(previous)' and '\(name)' both map to canonical field '\(field.canonicalName)'")};submitted[field.canonicalName]=name;values[field.canonicalName]=value;if name != field.wireName{paths[field.canonicalName]=pointer} }
  return NormalizedWireInput(values:values,sourceInstancePaths:paths)
}
public func retainSubmittedPaths(_ results:[CheckResult],normalized:NormalizedWireInput)->[CheckResult]{results.map{result in let canonical=result.location.segments.compactMap{if case .property(let name)=$0{return name};return nil}.first;return CheckResult(ruleID:result.ruleID,location:result.location,inputValue:result.inputValue,systemValue:result.systemValue,message:result.message,entityType:result.entityType,sourceInstancePath:canonical.flatMap{normalized.sourceInstancePaths[$0]} ?? result.sourceInstancePath)}}
