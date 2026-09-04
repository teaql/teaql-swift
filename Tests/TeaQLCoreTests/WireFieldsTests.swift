import XCTest
@testable import TeaQLCore

final class WireFieldsTests:XCTestCase{
  func testNormalizeAliasAndProvenance() throws {let meta=try WireEntityMetadata(entityType:"School",canonicalFields:["name","school_type"],aliases:["school_type":["school_type"]]);let value=try normalizeWireInput(["school_type":.int(1001)],metadata:meta,parentPointer:"/school");XCTAssertEqual(value.values["school_type"],.int(1001));let result=CheckResult(ruleID:"required",location:.property("school_type"));XCTAssertEqual(retainSubmittedPaths([result],normalized:value)[0].sourceInstancePath,"/school/school_type")}
  func testUnknownAndCollisionRejected() throws {let meta=try WireEntityMetadata(entityType:"School",canonicalFields:["school_type"],aliases:["school_type":["school_type"]]);XCTAssertThrowsError(try normalizeWireInput(["bad/name":.null],metadata:meta)){XCTAssertEqual(($0 as? WireInputError)?.instancePath,"/bad~1name")};XCTAssertThrowsError(try normalizeWireInput(["schoolType":.int(1),"school_type":.int(2)],metadata:meta)){XCTAssertEqual(($0 as? WireInputError)?.code,.fieldCollision)}}
  func testWireDTOUsesProfile(){let result=CheckResult(ruleID:"required",location:.property("school_type"),entityType:"School",sourceInstancePath:"/school_type");XCTAssertEqual(result.wire().instancePath,"/schoolType");XCTAssertEqual(result.wire().sourceInstancePath,"/school_type")}
}
