import Foundation

/// TeaQL's typed list boundary. It keeps collection ergonomics while reserving
/// query metadata needed by totals, aggregates, summaries, and facets.
public struct SmartList<Element: Sendable>: Sendable, RandomAccessCollection {
  public typealias Index = Int

  public private(set) var data: [Element]
  public var totalCount: Int?
  public var aggregations: TeaQLRecord
  public var summary: TeaQLRecord
  public var facets: [String: SmartList<TeaQLRecord>]
  public var isLoaded: Bool

  public init(
    _ data: [Element] = [],
    totalCount: Int? = nil,
    aggregations: TeaQLRecord = [:],
    summary: TeaQLRecord = [:],
    facets: [String: SmartList<TeaQLRecord>] = [:],
    isLoaded: Bool = true
  ) {
    self.data = data
    self.totalCount = totalCount
    self.aggregations = aggregations
    self.summary = summary
    self.facets = facets
    self.isLoaded = isLoaded
  }

  public static var empty: Self { Self(isLoaded: false) }

  public var startIndex: Int { data.startIndex }
  public var endIndex: Int { data.endIndex }
  public subscript(position: Int) -> Element { data[position] }

  public var totalCountOrCount: Int { totalCount ?? count }

  public func facet(_ name: String) -> SmartList<TeaQLRecord>? { facets[name] }

  public func withTotalCount(_ totalCount: Int) -> Self {
    var copy = self
    copy.totalCount = totalCount
    return copy
  }

  public func withFacet(_ name: String, _ facet: SmartList<TeaQLRecord>) -> Self {
    var copy = self
    copy.facets[name] = facet
    return copy
  }
}
