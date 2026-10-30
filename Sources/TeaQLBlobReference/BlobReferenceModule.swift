import Foundation
import TeaQLCore

private final class BlobModuleIdentity: Sendable {}

private final class ModuleBlobMutationParticipant: BlobMutationParticipant {
  let delegate: SQLiteBlobMutationParticipant
  init(catalog: SQLiteBlobCatalog, authorization: any BlobBindingAuthorization) {
    delegate = SQLiteBlobMutationParticipant(catalog: catalog, authorization: authorization)
  }
  func apply(context: UserContext, session: GraphMutationSession, mutation: Mutation,
             previous: TeaQLRecord?, persisted: TeaQLRecord) async throws {
    try await delegate.apply(context: context, session: session, mutation: mutation,
      previous: previous, persisted: persisted)
  }
}

private final class ModuleBlobContributor: BlobResponseContributor {
  let read: SQLiteBlobResponseContributor
  init(_ read: SQLiteBlobResponseContributor) { self.read = read }
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph,
                    expiresAt: Date?) async throws -> [ProjectedBlobURL] {
    try await read.projectBatch(context: context, graph: graph, expiresAt: expiresAt)
  }
}

private struct BlobCapability: RuntimeCapabilityProvider {
  let identity: BlobModuleIdentity
  let catalog: SQLiteBlobCatalog
  let contributor: ModuleBlobContributor
  let upload: SQLiteBlobUploadService
  let participant: ModuleBlobMutationParticipant
  func checkReady(context: UserContext) async throws {
    guard context.hasBlobResponseContributor(contributor), context.hasObjectStorageProvider,
          context.hasBlobMutationParticipant(participant),
          context.mutationExecutor is any BlobMutationExecutor else {
      throw ViewPreparationError("BLOB_CAPABILITY_MISSING")
    }
    try await upload.validateVerifierReady()
    do {
      try await context.executeGraphSave(comment: "validate BlobReferenceModule schema") { graph, session in
        try await catalog.validateSchema(graph, session: session)
      }
    } catch { throw ViewPreparationError("BLOB_SCHEMA_MISSING") }
  }
}

/// Passive optional assembly of SQLite catalog, trusted upload and authorized URL projection.
public struct BlobReferenceModule: Sendable {
  private let identity = BlobModuleIdentity()
  private let participant: ModuleBlobMutationParticipant
  public let catalog: SQLiteBlobCatalog
  public let upload: SQLiteBlobUploadService
  public let read: SQLiteBlobResponseContributor
  public let bindingAuthorization: any BlobBindingAuthorization
  public let maintenance: SQLiteBlobMaintenanceService?

  public init(catalog: SQLiteBlobCatalog = SQLiteBlobCatalog(), upload: SQLiteBlobUploadService,
              readAuthorization: any BlobReadAuthorization,
              bindingAuthorization: any BlobBindingAuthorization,
              maximumURLSeconds: Int = 600,
              maintenance: SQLiteBlobMaintenanceService? = nil) throws {
    self.catalog = catalog; self.upload = upload
    self.bindingAuthorization = bindingAuthorization
    self.maintenance = maintenance
    self.read = try SQLiteBlobResponseContributor(catalog: catalog,
      authorization: readAuthorization, maximumURLSeconds: maximumURLSeconds)
    self.participant = ModuleBlobMutationParticipant(catalog: catalog, authorization: bindingAuthorization)
  }

  public func install(on context: UserContext) throws -> UserContext {
    guard !context.hasRuntimeCapability("blob.v1"), !context.hasBlobResponseContributorInstalled,
          !context.hasBlobMutationParticipant else {
      throw ViewPreparationError("BLOB_CAPABILITY_MISSING")
    }
    let contributor = ModuleBlobContributor(read)
    return context.withRuntimeCapability("blob.v1", provider: BlobCapability(
      identity: identity, catalog: catalog, contributor: contributor, upload: upload, participant: participant))
      .withBlobResponseContributor(contributor)
      .withBlobMutationParticipant(participant)
  }

  public func ready(context: UserContext) async throws {
    guard let installed = context.runtimeCapabilityProvider(named: "blob.v1") as? BlobCapability,
          installed.identity === identity else {
      throw ViewPreparationError("BLOB_CAPABILITY_MISSING")
    }
    do { try await context.requireRuntimeCapabilities(["blob.v1"]) }
    catch let error as ViewPreparationError { throw error }
    catch { throw ViewPreparationError("BLOB_CAPABILITY_MISSING") }
  }
}
