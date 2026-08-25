import XCTest
@testable import TeaQLCore
final class I18nTests:XCTestCase{
 func testFifteenLocalesTimesFiveRules(){let rules=[CheckResult(ruleID:"required",location:.property("name")),CheckResult(ruleID:"min",location:.property("age"),inputValue:"1",systemValue:"2"),CheckResult(ruleID:"max",location:.property("age"),inputValue:"3",systemValue:"2"),CheckResult(ruleID:"min_length",location:.property("name"),inputValue:"a",systemValue:"2"),CheckResult(ruleID:"max_length",location:.property("name"),inputValue:"abc",systemValue:"2")];var cells=0;for locale in TeaQLLocale.allCases{for source in rules{let result=I18nCatalog.builtin.translate(source,locale:locale);XCTAssertNotNil(result.message);XCTAssertFalse(result.message!.hasPrefix("checker."));cells += 1}};XCTAssertEqual(cells,75)}
 func testAliases(){XCTAssertEqual(try TeaQLLocale.parse("ZH_hans"),.zhCN);XCTAssertThrowsError(try TeaQLLocale.parse("xx"))}
}
