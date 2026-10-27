import Foundation

/// A trusted host supplies readiness for an installed optional runtime module.
public protocol RuntimeCapabilityProvider: Sendable {
  func checkReady(context: UserContext) async throws
}

public extension UserContext {
  func hasRuntimeCapability(_ name: String) -> Bool { runtimeCapabilities[name] != nil }

  func hasSecureDocumentContributor(_ candidate: any SecureDocumentContributor) -> Bool {
    guard let installed = secureDocumentContributor else { return false }
    return ObjectIdentifier(installed as AnyObject) == ObjectIdentifier(candidate as AnyObject)
  }

  func hasBlobResponseContributor(_ candidate: any BlobResponseContributor) -> Bool {
    guard let installed = blobResponseContributor else { return false }
    return ObjectIdentifier(installed as AnyObject) == ObjectIdentifier(candidate as AnyObject)
  }

  var hasObjectStorageProvider: Bool { objectStorageProvider != nil }

  var hasSecureDocumentContributorInstalled: Bool { secureDocumentContributor != nil }
  var hasBlobResponseContributorInstalled: Bool { blobResponseContributor != nil }

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
