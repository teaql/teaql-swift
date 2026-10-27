import Foundation

/// A trusted host supplies readiness for an installed optional runtime module.
public protocol RuntimeCapabilityProvider: Sendable {
  func checkReady(context: UserContext) async throws
}

public extension UserContext {
  func withRuntimeCapability(_ name: String, provider: any RuntimeCapabilityProvider) -> UserContext {
    precondition(!name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines))
    var copy = self
    copy.runtimeCapabilities[name] = provider
    return copy
  }

  func requireRuntimeCapabilities(_ names: [String]) async throws {
    for name in names {
      guard let provider = runtimeCapabilities[name] else {
        throw TeaQLError.execution("RUNTIME_CAPABILITY_MISSING")
      }
      try await provider.checkReady(context: self)
    }
  }
}
