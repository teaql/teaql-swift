import Foundation
import TeaQLCore

private final class ModuleBlobContributor: BlobResponseContributor {
  let read: SQLiteBlobResponseContributor
  init(_ read: SQLiteBlobResponseContributor) { self.read = read }
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph,
                    expiresAt: Date?) async throws -> [ProjectedBlobURL] {
    try await read.projectBatch(context: context, graph: graph, expiresAt: expiresAt)
  }
}

private struct BlobCapability: RuntimeCapabilityProvider {
  let catalog: SQLiteBlobCatalog
  let contributor: ModuleBlobContributor
  let upload: SQLiteBlobUploadService
  func checkReady(context: UserContext) async throws {
    guard context.hasBlobResponseContributor(contributor), context.hasObjectStorageProvider,
          context.hasBlobMutationParticipant,
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
  }

  public func install(on context: UserContext) throws -> UserContext {
    guard !context.hasRuntimeCapability("blob.v1"), !context.hasBlobResponseContributorInstalled,
          !context.hasBlobMutationParticipant else {
      throw ViewPreparationError("BLOB_CAPABILITY_MISSING")
    }
    let contributor = ModuleBlobContributor(read)
    return context.withRuntimeCapability("blob.v1", provider: BlobCapability(
      catalog: catalog, contributor: contributor, upload: upload))
      .withBlobResponseContributor(contributor)
      .withBlobMutationParticipant(SQLiteBlobMutationParticipant(
        catalog: catalog, authorization: bindingAuthorization))
  }

  public func ready(context: UserContext) async throws {
    do { try await context.requireRuntimeCapabilities(["blob.v1"]) }
    catch let error as ViewPreparationError { throw error }
    catch { throw ViewPreparationError("BLOB_CAPABILITY_MISSING") }
  }
}
