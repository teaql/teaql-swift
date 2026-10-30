import Foundation

/// A trusted host supplies readiness for an installed optional runtime module.
public protocol RuntimeCapabilityProvider: Sendable {
  func checkReady(context: UserContext) async throws
}

private enum CapabilityReadiness {
  @TaskLocal static var checking: Set<String> = []
}

public extension UserContext {
  package var hasBlobMutationParticipant: Bool { blobMutationParticipant != nil }

  package func hasBlobMutationParticipant<Participant>(_ candidate: Participant) -> Bool
    where Participant: BlobMutationParticipant, Participant: AnyObject {
    guard let installed = blobMutationParticipant else { return false }
    return ObjectIdentifier(installed as AnyObject) == ObjectIdentifier(candidate)
  }

  package func withBlobMutationParticipant(_ participant: any BlobMutationParticipant) -> UserContext {
    var copy = self
    copy.blobMutationParticipant = participant
    return copy
  }

  func hasRuntimeCapability(_ name: String) -> Bool { runtimeCapabilities[name] != nil }

  /// Optional modules inspect their own concrete installation without exposing it to payloads.
  package func runtimeCapabilityProvider(named name: String) -> (any RuntimeCapabilityProvider)? {
    runtimeCapabilities[name]
  }

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
      // A provider may use a read-only graph transaction to validate its own
      // schema. The nested graph must not recursively start the same check.
      if CapabilityReadiness.checking.contains(name) { continue }
      try await CapabilityReadiness.$checking.withValue(
        CapabilityReadiness.checking.union([name])) {
          try await provider.checkReady(context: self)
      }
    }
  }
}
