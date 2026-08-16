import Foundation

/// Process-local cache with optional TTL in seconds.
public final class LocalCache: @unchecked Sendable {
  public static let shared = LocalCache()

  private struct Entry {
    let value: Any
    let expiresAt: Date?
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  public init() {}

  public func put(_ key: String, value: Any, timeToLiveInSeconds: Int? = nil) {
    let expiresAt = timeToLiveInSeconds.flatMap { ttl in
      ttl > 0 ? Date().addingTimeInterval(TimeInterval(ttl)) : nil
    }
    lock.lock()
    entries[key] = Entry(value: value, expiresAt: expiresAt)
    lock.unlock()
  }

  public func get<T>(_ key: String, as type: T.Type = T.self) -> T? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[key] else { return nil }
    if let expiresAt = entry.expiresAt, Date() >= expiresAt {
      entries.removeValue(forKey: key)
      return nil
    }
    return entry.value as? T
  }

  public func remove(_ key: String) {
    lock.lock()
    entries.removeValue(forKey: key)
    lock.unlock()
  }

  public func removeAll() {
    lock.lock()
    entries.removeAll()
    lock.unlock()
  }
}
