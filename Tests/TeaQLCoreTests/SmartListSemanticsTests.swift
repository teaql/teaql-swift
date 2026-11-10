import Foundation
import XCTest
import TeaQLCore

private struct SmartListVectors: Decodable {
  struct State: Decodable { let name: String; let loaded: Bool; let rows: [Int]; let total: Int? }
  struct Transform: Decodable { let rows: [Int]; let total: Int; let mapTimesTen: [Int]; let filterOdd: [Int]; let flatMapTwice: [Int] }
  struct Item: Decodable, Sendable, Equatable { let key: String; let value: Int }
  struct Merge: Decodable { let target: [Item]; let incoming: [Item]; let expected: [Item] }
  struct IdentityRow: Decodable, Sendable, Equatable { let id: TeaQLValue; let version: Int64 }
  struct Identity: Decodable { let rows: [IdentityRow]; let ids: [TeaQLValue]; let versions: [Int64]; let indexedPositions: [Int] }
  struct Metadata: Decodable {
    struct ExactDecimal: Decodable { let value: String }
    let aggregations: TeaQLRecord; let summary: TeaQLRecord; let facets: [String: [TeaQLRecord]]; let decimal: ExactDecimal
  }
  let states: [State]; let transform: Transform; let merge: Merge; let identity: Identity; let metadata: Metadata
}

final class SmartListSemanticsTests: XCTestCase {
  private func vectors() throws -> SmartListVectors {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "smart-list-semantics", withExtension: "json"))
    return try JSONDecoder().decode(SmartListVectors.self, from: Data(contentsOf: url))
  }

  private func sourceList(_ values: SmartListVectors) -> SmartList<Int> {
    SmartList(values.transform.rows, totalCount: values.transform.total,
      aggregations: values.metadata.aggregations, summary: values.metadata.summary,
      facets: values.metadata.facets.mapValues { SmartList($0) })
  }

  func testLoadedUnknownZeroAndPageTotalsAreIndependent() throws {
    for state in try vectors().states {
      let list = state.loaded ? SmartList(state.rows, totalCount: state.total) : SmartList<Int>.empty
      XCTAssertEqual(Array(list), state.rows, state.name); XCTAssertEqual(list.isLoaded, state.loaded, state.name)
      XCTAssertEqual(list.totalCount, state.total, state.name)
      XCTAssertEqual(list.totalCountOrCount, state.total ?? state.rows.count, state.name)
      XCTAssertEqual(list.totalCount, state.total, state.name)
    }
    XCTAssertFalse(SmartList<Int>.empty.mapSmart { $0 }.isLoaded)
    XCTAssertFalse(SmartList<Int>.empty.filterSmart { _ in true }.isLoaded)
    XCTAssertFalse(SmartList<Int>.empty.flatMapSmart { [$0] }.isLoaded)
  }

  func testMapKeepsExactTypesAndIsolatesNestedMetadataAndFacetRecords() throws {
    let fixture = try vectors()
    var source = sourceList(fixture)
    let decimal = try XCTUnwrap(Decimal(string: fixture.metadata.decimal.value, locale: Locale(identifier: "en_US_POSIX")))
    source.aggregations["decimal"] = .decimal(decimal)
    var mapped = source.mapSmart { $0 * 10 }
    XCTAssertEqual(Array(mapped), fixture.transform.mapTimesTen)
    XCTAssertEqual(mapped.totalCount, source.totalCount); XCTAssertTrue(mapped.isLoaded)
    XCTAssertEqual(mapped.aggregations, source.aggregations); XCTAssertEqual(mapped.summary, source.summary)
    XCTAssertEqual(mapped.facets["status"]?.data, source.facets["status"]?.data)
    XCTAssertEqual(mapped.aggregations["nullable"], .null); XCTAssertNil(mapped.aggregations["missing"])
    mapped.aggregations["nested"] = .object(["values": .array([.int(99)])])
    mapped.summary["nested"] = .object(["values": .array([.int(99)])])
    var facet = try XCTUnwrap(mapped.facets["status"])
    var row = facet[0]; row["count"] = .int(99); XCTAssertTrue(facet.set(0, row))
    mapped.facets["status"] = facet; mapped.removeFacet("empty")
    XCTAssertEqual(source.aggregations["nested"], .object(["values": .array([.int(1), .int(2)])]))
    XCTAssertEqual(source.summary["nested"], .object(["values": .array([.int(3)])]))
    XCTAssertEqual(source.facets["status"]?[0]["count"], .int(3)); XCTAssertNotNil(source.facets["empty"])
    XCTAssertEqual(mapped.aggregations["decimal"], .decimal(decimal))
  }

  func testDerivedFilterAndFlatMapClearStatisticsEvenForIdentityPredicate() throws {
    let fixture = try vectors(), source = sourceList(fixture)
    let filtered = source.filterSmart { $0 % 2 == 1 }, expanded = source.flatMapSmart { [$0, $0] }
    XCTAssertEqual(Array(filtered), fixture.transform.filterOdd); XCTAssertEqual(Array(expanded), fixture.transform.flatMapTwice)
    for result in [filtered, expanded, source.filterSmart { _ in true }] {
      XCTAssertNil(result.totalCount); XCTAssertTrue(result.isLoaded)
      XCTAssertTrue(result.aggregations.isEmpty && result.summary.isEmpty && result.facets.isEmpty)
    }
    var native: [Int] = source.map { $0 }; native[0] = 99
    XCTAssertEqual(source.first, 1); XCTAssertEqual(source.totalCount, 9)
  }

  func testDuplicateMergeOrderSafeAccessAndGroupingMatchVectors() throws {
    let fixture = try vectors()
    var source = SmartList(fixture.merge.target, totalCount: 9)
    source.mergeBy(fixture.merge.incoming, key: { $0.key })
    XCTAssertEqual(Array(source), fixture.merge.expected)
    XCTAssertEqual(source.identityMap { $0.key }["a"]?.value, 4)
    XCTAssertEqual(source.groupedBy { $0.key }["a"], Array(fixture.merge.expected.prefix(2)))
    for index in [-1, source.count, 100] {
      XCTAssertNil(source.get(index)); XCTAssertFalse(source.set(index, fixture.merge.expected[0]))
    }
    XCTAssertEqual(Array(source), fixture.merge.expected); XCTAssertEqual(source.totalCount, 9)
    XCTAssertNil(SmartList<Int>.empty.first); XCTAssertNil(SmartList<Int>.empty.last)
    source.retain { $0.key == "a" }; XCTAssertEqual(source.count, 2); XCTAssertEqual(source.totalCount, 9)
  }

  func testMissingAndTypedIDsVersionsAndFacetTransferKeepTheirMeaning() throws {
    let fixture = try vectors(), source = SmartList(fixture.identity.rows)
    let identifiers: [TeaQLValue?] = source.ids { $0.id == .null ? nil : $0.id }
    XCTAssertEqual(identifiers, fixture.identity.ids.map { $0 == .null ? nil : $0 })
    XCTAssertEqual(source.versions { $0.version }, fixture.identity.versions)
    let indexed = source.mapById { $0.id == .null ? nil : $0.id }
    XCTAssertEqual(indexed.count, 4); XCTAssertNil(indexed[.null])
    for (key, position) in zip([TeaQLValue.int(0), .int(1), .string("1"), .string("")], fixture.identity.indexedPositions) {
      XCTAssertEqual(indexed[key], source[position])
    }
    var list = sourceList(fixture)
    XCTAssertNil(list.facet("absent")); XCTAssertNotNil(list.facet("empty")); XCTAssertEqual(list.facet("empty")?.count, 0)
    XCTAssertNil(list.removeFacet("absent")); XCTAssertEqual(list.takeFacets().count, 2); XCTAssertTrue(list.facets.isEmpty)
  }
}
