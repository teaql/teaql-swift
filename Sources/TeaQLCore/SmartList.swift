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
    precondition(totalCount == nil || totalCount! >= 0, "totalCount must be non-negative")
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
    precondition(totalCount >= 0, "totalCount must be non-negative")
    var copy = self
    copy.totalCount = totalCount
    return copy
  }

  public func withFacet(_ name: String, _ facet: SmartList<TeaQLRecord>) -> Self {
    var copy = self
    copy.facets[name] = facet
    return copy
  }

  /// Dedicated transforms preserve the typed boundary; standard Sequence transforms return Array.
  /// TeaQLValue and facet records use value semantics, including nested records and arrays.
  public func mapSmart<Mapped: Sendable>(_ transform: (Element) throws -> Mapped) rethrows -> SmartList<Mapped> {
    SmartList<Mapped>(try data.map(transform), totalCount: totalCount, aggregations: aggregations,
      summary: summary, facets: facets, isLoaded: isLoaded)
  }

  public func filterSmart(_ predicate: (Element) throws -> Bool) rethrows -> Self {
    Self(try data.filter(predicate), isLoaded: isLoaded)
  }

  public func flatMapSmart<Mapped: Sendable>(_ transform: (Element) throws -> [Mapped]) rethrows -> SmartList<Mapped> {
    SmartList<Mapped>(try data.flatMap(transform), isLoaded: isLoaded)
  }

  public func get(_ index: Int) -> Element? { data.indices.contains(index) ? data[index] : nil }

  @discardableResult
  public mutating func set(_ index: Int, _ value: Element) -> Bool {
    guard data.indices.contains(index) else { return false }
    data[index] = value
    return true
  }

  public mutating func append(_ value: Element) { data.append(value) }
  public mutating func extend<Items: Sequence>(_ values: Items) where Items.Element == Element {
    data.append(contentsOf: values)
  }

  public mutating func retain(_ predicate: (Element) -> Bool) { data.removeAll { !predicate($0) } }

  public mutating func mergeBy<Items: Sequence, Key: Hashable>(_ incoming: Items, key: (Element) -> Key)
    where Items.Element == Element {
    var positions: [Key: Int] = [:]
    for (index, item) in data.enumerated() { positions[key(item)] = index }
    for item in incoming {
      let itemKey = key(item)
      if let position = positions[itemKey] { data[position] = item }
      else { positions[itemKey] = data.count; data.append(item) }
    }
  }

  public func identityMap<Key: Hashable>(_ key: (Element) -> Key) -> [Key: Element] {
    var result: [Key: Element] = [:]
    for item in data { result[key(item)] = item }
    return result
  }

  public func groupedBy<Key: Hashable>(_ key: (Element) -> Key) -> [Key: [Element]] {
    Dictionary(grouping: data, by: key)
  }

  public func ids<ID>(_ id: (Element) -> ID?) -> [ID?] { data.map(id) }
  public func versions<Version>(_ version: (Element) -> Version) -> [Version] { data.map(version) }

  public func mapById<ID: Hashable>(_ id: (Element) -> ID?) -> [ID: Element] {
    var result: [ID: Element] = [:]
    for item in data { if let value = id(item) { result[value] = item } }
    return result
  }

  @discardableResult
  public mutating func removeFacet(_ name: String) -> SmartList<TeaQLRecord>? { facets.removeValue(forKey: name) }

  public mutating func takeFacets() -> [String: SmartList<TeaQLRecord>] {
    let result = facets
    facets = [:]
    return result
  }
}
