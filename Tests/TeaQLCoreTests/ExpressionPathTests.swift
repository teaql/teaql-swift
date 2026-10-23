import XCTest
import TeaQLCore

final class ExpressionPathTests: XCTestCase {
  func testEarlyRepeatedRelationPreservesTheSuffixAndOnlyOneMarker() {
    let parent = ExpressionPath("E.node(<root>)").member("parent", method: "parent").markMissing()
    let leaf = parent.member("parent", method: "parent").member("user_url", method: "userUrl")
    let error = TeaQLNotLoadedError(path: parent, breakPoint: "parent").withPath(leaf).terminal("eval()")
    let wire = error.toWire()
    XCTAssertEqual(wire.code, "NOT_LOADED")
    XCTAssertEqual(wire.instancePath, "/parent")
    XCTAssertEqual(wire.attemptedInstancePath, "/parent/parent/userUrl")
    XCTAssertEqual(wire.originalExpression, "E.node(<root>).parent().parent().userUrl().eval()")
    XCTAssertEqual(wire.expressionWithBrokenPoint, "E.node(<root>).parent()<broken>.parent().userUrl().eval()")
    XCTAssertEqual(wire.breakPointIndex, 0)
    XCTAssertEqual(wire.suggestedFix.location, wire.location)
  }

  func testIndicesProfilesAndNontraversalCallsAreSeparate() {
    for profile: JsonFieldNamingProfile in [.camelCase, .snakeCase, .pascalCase] {
      let items = ExpressionPath("E.order(<root>)", profile: profile).member("order_items", method: "orderItems").markMissing()
      let error = TeaQLNotLoadedError(path: items.index(12).member("user_url", method: "userUrl"), breakPoint: "order_items").terminal("eval()")
      XCTAssertEqual(error.toWire().attemptedLocation[1].kind, "index")
      XCTAssertEqual(error.toWire().attemptedLocation[1].index, 12)
      XCTAssertTrue(error.toWire().originalExpression.contains(".get(12).userUrl().eval()"))
      let first = TeaQLNotLoadedError(path: items.index(0, first: true), breakPoint: "order_items").terminal("eval()")
      XCTAssertTrue(first.toWire().originalExpression.contains(".first().eval()"))
      let size = TeaQLNotLoadedError(path: items.operation("size()"), breakPoint: "order_items")
      XCTAssertEqual(size.toWire().attemptedLocation, size.toWire().location)
    }
  }

  func testSiblingsAndPunctuationAreNotParsedAndWireOmitsRootValues() throws {
    let parent = ExpressionPath("E.node(<root>)").member("a~/b.c", method: "safeMethod").markMissing()
    let first = TeaQLNotLoadedError(path: parent.member("name", method: "name"), breakPoint: "a~/b.c").terminal("orElse(<fallback>)")
    let second = TeaQLNotLoadedError(path: parent.member("code", method: "code"), breakPoint: "a~/b.c").terminal("eval()")
    XCTAssertEqual(first.toWire().instancePath, "/a~0~1b.c")
    XCTAssertFalse(first.toWire().originalExpression.contains(".code()"))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(second.toWire())) as? [String: Any])
    XCTAssertNil(json["root"])
    XCTAssertNil(json["inputValue"])
  }
}
