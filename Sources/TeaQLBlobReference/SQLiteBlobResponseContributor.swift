import Foundation
import TeaQLCore

public protocol BlobReadAuthorization: Sendable {
  func authorize(actor: UserContext, slot: AuthorizedBlobSlot) async throws -> Bool
}

/// Reauthorizes each slot and rereads its current catalog row before signing a full URL.
public struct SQLiteBlobResponseContributor: BlobResponseContributor {
  public let catalog: SQLiteBlobCatalog
  public let authorization: any BlobReadAuthorization
  public let maximumURLSeconds: Int

  public init(catalog: SQLiteBlobCatalog, authorization: any BlobReadAuthorization,
              maximumURLSeconds: Int = 600) throws {
    guard (1...3600).contains(maximumURLSeconds) else {
      throw TeaQLError.execution("BLOB_POLICY_INVALID")
    }
    self.catalog = catalog
    self.authorization = authorization
    self.maximumURLSeconds = maximumURLSeconds
  }

  public func projectBatch(context: UserContext, graph: AuthorizedResponseGraph, expiresAt: Date?)
    async throws -> [ProjectedBlobURL] {
    var urls: [ProjectedBlobURL] = []
    for slot in graph.blobSlots {
      let allowed: Bool
      do { allowed = try await authorization.authorize(actor: context, slot: slot) }
      catch { throw ViewPreparationError("BLOB_READ_DENIED") }
      guard allowed else { throw ViewPreparationError("BLOB_READ_DENIED") }
      let record: BlobCatalogRead
      do { record = try await catalog.currentRead(context, slot: slot) }
      catch let error as ViewPreparationError { throw error }
      catch { throw ViewPreparationError("BLOB_CATALOG_FAILED") }
      let seconds = expiresAt.map {
        min(maximumURLSeconds, Int(floor($0.timeIntervalSinceNow)) - 1)
      } ?? maximumURLSeconds
      guard seconds >= 1 else { throw ViewPreparationError("BLOB_REFERENCE_EXPIRED") }
      let disposition = record.contentType.hasPrefix("image/") ||
        record.contentType.hasPrefix("audio/") || record.contentType.hasPrefix("video/") ||
        record.contentType == "application/pdf" ? "inline" : "attachment"
      do {
        let store = try context.objectStorage("prepare authorized Blob view")
        let signed = try await store.getReadUrl(try ObjectKey(record.objectKey),
          options: ObjectReadUrlOptions(seconds: seconds, disposition: disposition,
            filename: record.fileName))
        urls.append(ProjectedBlobURL(url: signed.url.absoluteString, expiresAt: signed.expiresAt))
      } catch { throw ViewPreparationError("BLOB_SIGN_FAILED") }
    }
    return urls
  }
}
