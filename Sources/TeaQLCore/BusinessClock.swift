import Foundation

/// Business time is injectable per context. Operational deadlines keep their own clocks.
public protocol BusinessClock: Sendable { func now() -> Date }

public struct SystemBusinessClock: BusinessClock {
  public init() {}
  public func now() -> Date { Date() }
}

public struct FixedBusinessClock: BusinessClock {
  private let value: Date
  public init(_ value: Date) {
    precondition(value.timeIntervalSince1970.isFinite, "Business clock requires a finite Date")
    self.value = value
  }
  public func now() -> Date { value }
}
