import Foundation

/// Value-free generated calls. Canonical identity is never parsed from display text.
public struct ExpressionPath: Sendable, Equatable {
  private struct Step: Sendable, Equatable { let call: String; let location: ObjectLocation }
  private let rootExpression: String
  private let profile: JsonFieldNamingProfile
  public let location: ObjectLocation
  private let steps: [Step]
  private let missing: Int?

  public init(_ expression: String, profile: JsonFieldNamingProfile = .camelCase) {
    rootExpression = expression; self.profile = profile; location = ObjectLocation(); steps = []; missing = nil
  }
  private init(root: String, profile: JsonFieldNamingProfile, location: ObjectLocation,
               steps: [Step], missing: Int?) {
    rootExpression = root; self.profile = profile; self.location = location; self.steps = steps; self.missing = missing
  }
  public func member(_ name: String, method: String) -> Self {
    append(method + "()", location: location.property(name))
  }
  public func index(_ index: Int, first: Bool = false) -> Self {
    append(first ? "first()" : "get(\(index))", location: location.index(index))
  }
  public func operation(_ call: String) -> Self { append(call, location: location) }
  private func append(_ call: String, location: ObjectLocation) -> Self {
    Self(root: rootExpression, profile: profile, location: location,
      steps: steps + [Step(call: call, location: location)], missing: missing)
  }
  public func markMissing() -> Self {
    Self(root: rootExpression, profile: profile, location: location, steps: steps,
      missing: missing ?? (steps.isEmpty ? nil : steps.count - 1))
  }
  public func withFailure(from failed: Self) -> Self {
    Self(root: rootExpression, profile: profile, location: location, steps: steps, missing: failed.missing)
  }
  public func render(broken: Bool = false) -> String {
    rootExpression + steps.enumerated().map { index, step in
      "." + step.call + (broken && index == missing ? "<broken>" : "")
    }.joined()
  }
  public func diagnostic(fallback: String) -> NotLoadedDiagnostic {
    let failure = missing.map { steps[$0].location } ?? location
    let breakPoint: String
    if let last = failure.segments.last, case .property(let name) = last { breakPoint = name } else { breakPoint = fallback }
    let wire = Self.wireLocation(failure)
    return NotLoadedDiagnostic(code: "NOT_LOADED", location: wire,
      instancePath: failure.instancePath(profile: profile), breakPoint: breakPoint,
      attemptedLocation: Self.wireLocation(location), attemptedInstancePath: location.instancePath(profile: profile),
      breakPointIndex: max(0, wire.count - 1), originalExpression: render(),
      expressionWithBrokenPoint: render(broken: true), suggestedFix: ExpressionPreloadGuidance(action: "preload", location: wire))
  }
  private static func wireLocation(_ location: ObjectLocation) -> [WireLocationSegment] {
    location.segments.map {
      switch $0 {
      case .property(let name): WireLocationSegment(kind: "property", name: name)
      case .index(let index): WireLocationSegment(kind: "index", index: index)
      }
    }
  }
}

public struct ExpressionPreloadGuidance: Sendable, Codable, Equatable {
  public let action: String
  public let location: [WireLocationSegment]
}
public struct NotLoadedDiagnostic: Sendable, Codable, Equatable {
  public let code: String
  public let location: [WireLocationSegment]
  public let instancePath: String
  public let breakPoint: String
  public let attemptedLocation: [WireLocationSegment]
  public let attemptedInstancePath: String
  public let breakPointIndex: Int
  public let originalExpression: String
  public let expressionWithBrokenPoint: String
  public let suggestedFix: ExpressionPreloadGuidance
}

public struct TeaQLNotLoadedError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: ExpressionPath
  public let breakPoint: String
  public init(path: ExpressionPath, breakPoint: String) { self.path = path; self.breakPoint = breakPoint }
  public func withPath(_ path: ExpressionPath) -> Self {
    Self(path: path.withFailure(from: self.path), breakPoint: breakPoint)
  }
  public func terminal(_ call: String) -> Self { Self(path: path.operation(call), breakPoint: breakPoint) }
  public func toWire() -> NotLoadedDiagnostic { path.diagnostic(fallback: breakPoint) }
  public var description: String {
    // The closed DTO contains only strings, integers and location segments.
    guard let data = try? JSONEncoder().encode(toWire()) else { return "NOT_LOADED" }
    return String(decoding: data, as: UTF8.self)
  }
}
