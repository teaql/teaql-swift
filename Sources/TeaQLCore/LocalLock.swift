import Foundation

/// Process-local keyed locks with timeout, lease expiry, and owner-safe release.
public final class LocalLock: @unchecked Sendable {
  public static let shared = LocalLock()

  private struct Entry {
    let owner: UUID
    let expiresAt: Date?
  }

  private let condition = NSCondition()
  private var entries: [String: Entry] = [:]

  public init() {}

  public func tryLock(
    _ key: String, owner: UUID, timeoutMillis: Int64, expireMillis: Int64
  ) -> Bool {
    let deadline = Date().addingTimeInterval(Double(max(timeoutMillis, 0)) / 1_000)
    condition.lock()
    defer { condition.unlock() }
    while true {
      let now = Date()
      if let current = entries[key] {
        if current.owner == owner || current.expiresAt.map({ now >= $0 }) == true {
          entries[key] = Entry(
            owner: owner,
            expiresAt: expireMillis > 0
              ? now.addingTimeInterval(Double(expireMillis) / 1_000) : nil)
          return true
        }
        guard timeoutMillis > 0, now < deadline else { return false }
        let wakeAt = min(deadline, current.expiresAt ?? deadline)
        _ = condition.wait(until: wakeAt)
      } else {
        entries[key] = Entry(
          owner: owner,
          expiresAt: expireMillis > 0
            ? now.addingTimeInterval(Double(expireMillis) / 1_000) : nil)
        return true
      }
    }
  }

  public func unlock(_ key: String, owner: UUID) {
    condition.lock()
    if entries[key]?.owner == owner {
      entries.removeValue(forKey: key)
      condition.broadcast()
    }
    condition.unlock()
  }
}
