import Foundation

public enum ObjectLocationSegment: Sendable, Hashable {
  case property(String)
  case index(Int)
}

/// A casing-neutral location expressed with canonical KSML property names.
public struct ObjectLocation: Sendable, Hashable, CustomStringConvertible {
  public let segments: [ObjectLocationSegment]

  public init(segments: [ObjectLocationSegment] = []) { self.segments = segments }
  public static func property(_ name: String) -> Self { Self().property(name) }
  public func property(_ name: String) -> Self { Self(segments: segments + [.property(name)]) }
  public func index(_ index: Int) -> Self { Self(segments: segments + [.index(index)]) }
  public func prefixed(by prefix: Self) -> Self { Self(segments: prefix.segments + segments) }

  public var modelPath: String { render { $0 } }
  public var nativePath: String { render(Self.lowerCamel) }
  public var instancePath: String {
    segments.map { segment in
      switch segment {
      case .property(let name): return "/\(Self.escapePointer(Self.lowerCamel(name)))"
      case .index(let index): return "/\(index)"
      }
    }.joined()
  }
  public var description: String { nativePath }

  private func render(_ propertyName: (String) -> String) -> String {
    var result = ""
    for segment in segments {
      switch segment {
      case .property(let name): result += (result.isEmpty ? "" : ".") + propertyName(name)
      case .index(let index): result += "[\(index)]"
      }
    }
    return result
  }

  private static func lowerCamel(_ name: String) -> String {
    let parts = name.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
    return (parts.first ?? "") + parts.dropFirst().map {
      guard let first = $0.first else { return "" }
      return first.uppercased() + $0.dropFirst()
    }.joined()
  }

  private static func escapePointer(_ value: String) -> String {
    value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }
}
