import XCTest
@testable import TeaQLCore

final class WireFieldsTests:XCTestCase{
  func testNormalizeAliasAndProvenance() throws {let meta=try WireEntityMetadata(entityType:"School",canonicalFields:["name","school_type"],aliases:["school_type":["school_type"]]);let value=try normalizeWireInput(["school_type":.int(1001)],metadata:meta,parentPointer:"/school");XCTAssertEqual(value.values["school_type"],.int(1001));let result=CheckResult(ruleID:"required",location:.property("school_type"));XCTAssertEqual(retainSubmittedPaths([result],normalized:value)[0].sourceInstancePath,"/school/school_type")}
  func testUnknownAndCollisionRejected() throws {let meta=try WireEntityMetadata(entityType:"School",canonicalFields:["school_type"],aliases:["school_type":["school_type"]]);XCTAssertThrowsError(try normalizeWireInput(["bad/name":.null],metadata:meta)){XCTAssertEqual(($0 as? WireInputError)?.instancePath,"/bad~1name")};XCTAssertThrowsError(try normalizeWireInput(["schoolType":.int(1),"school_type":.int(2)],metadata:meta)){XCTAssertEqual(($0 as? WireInputError)?.code,.fieldCollision)}}
  func testWireDTOUsesProfile() throws {let result=CheckResult(ruleID:"required",location:.property("school_type"),entityType:"School",sourceInstancePath:"/school_type");let wire=result.wire();XCTAssertEqual(wire.instancePath,"/schoolType");XCTAssertEqual(wire.sourceInstancePath,"/school_type");let encoded=try JSONEncoder().encode(wire);let json=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any]);XCTAssertEqual(json["ruleId"] as? String,"required");XCTAssertNil(json["ruleID"]);XCTAssertEqual(json["instancePath"] as? String,"/schoolType");let segments=try XCTUnwrap(json["location"] as? [[String:Any]]);XCTAssertEqual(segments.first?["kind"] as? String,"property");XCTAssertEqual(segments.first?["name"] as? String,"school_type")}

  func testParentAliasNeverTruncatesDescendantProvenance() throws {
    let normalized = NormalizedWireInput(values: [:], sourceInstancePaths: [
      "order_item_list": "/legacy~1items", "product_name": "/legacy~0name"])
    let location = ObjectLocation.property("order_item_list").index(2).property("product_name")
    let exact = "/legacy~1items/2/legacy~0name"
    let original = CheckResult(ruleID: "required", location: location, sourceInstancePath: exact)
    let result = retainSubmittedPaths([
      original, CheckResult(ruleID: "required", location: location),
      CheckResult(ruleID: "required", location: ObjectLocation().index(2).property("product_name")),
      CheckResult(ruleID: "required", location: .property("order_item_list"))
    ], normalized: normalized)
    XCTAssertEqual(result.map(\.sourceInstancePath), [exact, nil, nil, "/legacy~1items"])
    XCTAssertEqual(original.sourceInstancePath, exact)
  }

  func testStandardChildRetainsAncestorProvenance() throws {
    let parent = try WireEntityMetadata(entityType: "Order", canonicalFields: ["order_item_list"],
      aliases: ["order_item_list": ["legacy/items~"]])
    for profile in [JsonFieldNamingProfile.camelCase, .snakeCase, .pascalCase] {
      let child = try WireEntityMetadata(entityType: "OrderItem", canonicalFields: ["product_name", "unit_count"], profile: profile)
      let name = try XCTUnwrap(child.fields["product_name"]).wireName
      for value in [TeaQLValue.null, .string("submitted item")] {
        let childObject = [name: value]
        let parentInput = try normalizeWireInput(["legacy/items~": .array([.null, .null, .object(childObject)])], metadata: parent)
        let boundary = try XCTUnwrap(parentInput.sourceInstancePaths["order_item_list"]) + "/2"
        let normalized = try normalizeWireInput(childObject, metadata: child, parentPointer: boundary)
        XCTAssertEqual(normalized.values, ["product_name": value])
        XCTAssertEqual(normalized.sourceInstancePaths, ["product_name": boundary + "/" + name])
        let original = CheckResult(ruleID: "required", location: .property("product_name"), entityType: "OrderItem")
        let leaf = retainSubmittedPaths([original], normalized: normalized)[0]
        let location = ObjectLocation.property("order_item_list").index(2).property("product_name")
        let prefixed = CheckResult(ruleID: leaf.ruleID, location: location, entityType: leaf.entityType,
          sourceInstancePath: leaf.sourceInstancePath)
        let actual = retainSubmittedPaths([prefixed], normalized: parentInput)[0]
        XCTAssertEqual(actual.sourceInstancePath, "/legacy~1items~0/2/" + name)
        XCTAssertEqual(actual.location, location)
        XCTAssertNil(original.sourceInstancePath)
      }
      XCTAssertTrue(try normalizeWireInput([name: .null], metadata: child).sourceInstancePaths.isEmpty)
    }
  }
}
