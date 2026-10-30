import Foundation
import TeaQLCore

private final class SecureModuleIdentity: Sendable {}

public struct PreparedBoundDocument: Sendable {
  public let document: BoundDocumentSnapshot
  public let lifetimeSeconds: Int64
  public init(document: BoundDocumentSnapshot, lifetimeSeconds: Int64) {
    self.document = document; self.lifetimeSeconds = lifetimeSeconds
  }
}

/// Trusted current host state; request JSON cannot supply this implementation.
public protocol SecureDocumentAssembly: Sendable {
  func principal(context: UserContext) throws -> TrustedReferencePrincipal
  func snapshot(context: UserContext, graph: AuthorizedResponseGraph) async throws -> PreparedBoundDocument
}

private struct SecureCapability: RuntimeCapabilityProvider {
  let identity: SecureModuleIdentity
  let contributor: SecureContributor
  func checkReady(context: UserContext) async throws {
    guard context.hasSecureDocumentContributor(contributor) else {
      throw ViewPreparationError("DOCUMENT_CONFIGURATION")
    }
  }
}

private final class SecureContributor: SecureDocumentContributor {
  let runtime: ContextBoundReferenceRuntime
  let assembly: any SecureDocumentAssembly
  init(runtime: ContextBoundReferenceRuntime, assembly: any SecureDocumentAssembly) {
    self.runtime = runtime; self.assembly = assembly
  }

  func prepare(context: UserContext, graph: AuthorizedResponseGraph,
               options: ViewOptions) async throws -> PreparedSecureDocument {
    guard options.mode == .governed else { throw ViewPreparationError("DOCUMENT_CONFIGURATION") }
    do { try await context.requireRuntimeCapabilities(["secure_document.v1"]) }
    catch { throw ViewPreparationError("DOCUMENT_CONFIGURATION") }
    let principal: TrustedReferencePrincipal
    let prepared: PreparedBoundDocument
    do {
      principal = try assembly.principal(context: context)
      prepared = try await assembly.snapshot(context: context, graph: graph)
    } catch let error as ReferenceError { throw ViewPreparationError(error.code) }
    catch { throw ViewPreparationError("DOCUMENT_CONFIGURATION") }
    let document = prepared.document
    for slot in graph.blobSlots {
      guard let id = UInt64(slot.entityID), id > 0, String(id) == slot.entityID,
        slot.bindingVersion >= 0,
        let row = document.snapshot.entities.first(where: {
          $0.identity.entityType == slot.entity && $0.identity.id == id
        }),
        let binding = document.bindings.first(where: {
          $0.rowKey == row.rowKey && $0.canonicalField == slot.field
        }),
        binding.entityType == slot.entity,
        binding.reference == slot.reference,
        binding.bindingVersion == UInt64(slot.bindingVersion) else {
        throw ViewPreparationError("DOCUMENT_PROJECTION_VIOLATION")
      }
    }
    do {
      let token = try runtime.issueBoundDocumentSnapshot(principal, document: document,
        lifetimeSeconds: prepared.lifetimeSeconds)
      let verified = try runtime.consumeBoundDocumentSnapshot(principal, token: token,
        aggregateType: document.snapshot.scope.aggregateType, purpose: document.snapshot.scope.purpose)
      return PreparedSecureDocument(graph: graph, envelope: .object([
        "businessId": .string(document.snapshot.businessID), "documentToken": .string(token),
      ]), expiresAt: verified.expiresAt)
    } catch let error as ReferenceError { throw ViewPreparationError(error.code) }
  }
}

/// Optional protocol and governed-view assembly. Host startup invokes readiness separately.
public struct SecureDocumentReferenceModule: Sendable {
  private let identity = SecureModuleIdentity()
  public let runtime: ContextBoundReferenceRuntime
  public init(runtime: ContextBoundReferenceRuntime) { self.runtime = runtime }

  public func install(on context: UserContext, assembly: any SecureDocumentAssembly) throws -> UserContext {
    guard !context.hasRuntimeCapability("secure_document.v1"),
      !context.hasSecureDocumentContributorInstalled else {
      throw ViewPreparationError("DOCUMENT_CONFIGURATION")
    }
    let contributor = SecureContributor(runtime: runtime, assembly: assembly)
    return context.withRuntimeCapability("secure_document.v1", provider: SecureCapability(
      identity: identity, contributor: contributor))
      .withSecureDocumentContributor(contributor)
  }

  public func ready(context: UserContext) async throws {
    guard let installed = context.runtimeCapabilityProvider(named: "secure_document.v1") as? SecureCapability,
          installed.identity === identity else {
      throw ViewPreparationError("DOCUMENT_CONFIGURATION")
    }
    do { try await context.requireRuntimeCapabilities(["secure_document.v1"]) }
    catch { throw ViewPreparationError("DOCUMENT_CONFIGURATION") }
  }
}
