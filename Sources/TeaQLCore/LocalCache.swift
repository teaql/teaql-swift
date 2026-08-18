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
  private let runtimeTelemetry: any RuntimeTelemetry

  public init(runtimeTelemetry: any RuntimeTelemetry = NoopRuntimeTelemetry()) {
    self.runtimeTelemetry = runtimeTelemetry
  }

  public func put(_ key: String, value: Any, timeToLiveInSeconds: Int? = nil) {
    runtimeTelemetry.withSynchronousOperation(
      cacheOperation("local.put", "put"),
      completion: { _ in ["teaql.cache.result": .string("stored")] }
    ) {
      let expiresAt = timeToLiveInSeconds.flatMap { ttl in
        ttl > 0 ? Date().addingTimeInterval(TimeInterval(ttl)) : nil
      }
      lock.lock()
      entries[key] = Entry(value: value, expiresAt: expiresAt)
      lock.unlock()
    }
  }

  public func get<T>(_ key: String, as type: T.Type = T.self) -> T? {
    runtimeTelemetry.withSynchronousOperation(
      cacheOperation("local.get", "get"),
      completion: { value in
        ["teaql.cache.result": .string(value == nil ? "miss" : "hit")]
      }
    ) {
      lock.lock()
      defer { lock.unlock() }
      guard let entry = entries[key] else { return nil }
      if let expiresAt = entry.expiresAt, Date() >= expiresAt {
        entries.removeValue(forKey: key)
        return nil
      }
      return entry.value as? T
    }
  }

  public func remove(_ key: String) {
    runtimeTelemetry.withSynchronousOperation(
      cacheOperation("local.remove", "remove"),
      completion: { _ in ["teaql.cache.result": .string("removed")] }
    ) {
      lock.lock()
      entries.removeValue(forKey: key)
      lock.unlock()
    }
  }

  public func removeAll() {
    lock.lock()
    entries.removeAll()
    lock.unlock()
  }

  private func cacheOperation(_ name: String, _ operation: String) -> RuntimeOperation {
    RuntimeOperation(
      family: "cache", name: name,
      attributes: ["teaql.cache.operation": .string(operation)])
  }
}
