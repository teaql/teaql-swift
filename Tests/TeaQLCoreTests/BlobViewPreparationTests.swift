import Foundation
import XCTest
@testable import TeaQLCore

private final class ViewStages: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  func append(_ value: String) { lock.withLock { recorded.append(value) } }
  var values: [String] { lock.withLock { recorded } }
}

private struct BlobViewAuthorizer: ResponseGraphAuthorizer {
  let source: ViewValue
  let reference: BlobRef
  let listed: Bool
  let stages: ViewStages
  func authorize(context: UserContext, result: any Sendable, options: ViewOptions)
    async throws -> AuthorizedResponseGraph {
    stages.append("authorize")
    let slots = listed ? [AuthorizedBlobSlot(path: [.field("document")], entity: "Asset",
      entityID: "1", field: "document", scope: "tenant-a", bindingVersion: 4,
      reference: reference)] : []
    return AuthorizedResponseGraph(presentation: source, blobSlots: slots)
  }
}

private struct BlobViewSecure: SecureDocumentContributor {
  let stages: ViewStages
  let ceiling: Date
  func prepare(context: UserContext, graph: AuthorizedResponseGraph, options: ViewOptions)
    async throws -> PreparedSecureDocument {
    stages.append("secure")
    guard case .object(var object) = graph.presentation else {
      throw ViewPreparationError("VIEW_GRAPH_INVALID")
    }
    object["governed"] = .bool(true)
    return PreparedSecureDocument(graph: AuthorizedResponseGraph(presentation: .object(object),
      blobSlots: graph.blobSlots), envelope: .string("sealed-document"), expiresAt: ceiling)
  }
}

private struct BlobViewSigner: BlobResponseContributor {
  let stages: ViewStages
  let ceiling: Date
  let fail: Bool
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph, expiresAt: Date?)
    async throws -> [ProjectedBlobURL] {
    stages.append("blob")
    if fail { throw TeaQLError.execution("PRIVATE-URL-CANARY") }
    guard expiresAt == ceiling, graph.blobSlots.count == 1 else {
      throw ViewPreparationError("VIEW_GRAPH_INVALID")
    }
    return [ProjectedBlobURL(url: "https://files.example.invalid/read/asset",
      expiresAt: ceiling.addingTimeInterval(-60))]
  }
}

private struct TwoBlobAuthorizer: ResponseGraphAuthorizer {
  let first: BlobRef
  let second: BlobRef
  func authorize(context: UserContext, result: any Sendable, options: ViewOptions)
    async throws -> AuthorizedResponseGraph {
    AuthorizedResponseGraph(presentation: .object(["first": .blob(first), "second": .blob(second)]),
      blobSlots: [
        AuthorizedBlobSlot(path: [.field("first")], entity: "Asset", entityID: "1",
          field: "first", scope: "tenant-a", bindingVersion: 4, reference: first),
        AuthorizedBlobSlot(path: [.field("second")], entity: "Asset", entityID: "1",
          field: "second", scope: "tenant-a", bindingVersion: 5, reference: second),
      ])
  }
}

private struct TwoBlobSigner: BlobResponseContributor {
  let firstExpiry: Date
  let secondExpiry: Date
  func projectBatch(context: UserContext, graph: AuthorizedResponseGraph, expiresAt: Date?)
    async throws -> [ProjectedBlobURL] {
    [ProjectedBlobURL(url: "https://files.example.invalid/first", expiresAt: firstExpiry),
     ProjectedBlobURL(url: "https://files.example.invalid/second", expiresAt: secondExpiry)]
  }
}

final class BlobViewPreparationTests: XCTestCase {
  func testIndependentURLLifetimesUseOriginalCeilingAndReturnMinimum() async throws {
    let first = try BlobRef("blob_asset_1")
    let second = try BlobRef("blob_asset_2")
    let ceiling = Date().addingTimeInterval(90)
    let firstExpiry = Date().addingTimeInterval(20)
    let secondExpiry = Date().addingTimeInterval(40)
    let context = storageViewContext()
      .withResponseGraphAuthorizer(TwoBlobAuthorizer(first: first, second: second))
      .withBlobResponseContributor(TwoBlobSigner(firstExpiry: firstExpiry,
        secondExpiry: secondExpiry))
    let prepared = try await ViewPreparationService().prepare(context: context, result: "unused",
      options: ViewOptions(mode: .ordinary, businessOutcome: .readOnly, expiresAt: ceiling))
    XCTAssertEqual(prepared.expiresAt, firstExpiry)
    XCTAssertEqual(prepared.presentation, .object([
      "first": .string("https://files.example.invalid/first"),
      "second": .string("https://files.example.invalid/second"),
    ]))
  }

  func testAuthorizedViewDetachesBeforeDocumentAndBlobStages() async throws {
    let reference = try BlobRef("blob_asset_1")
    let source: ViewValue = .object(["document": .blob(reference),
      "nested": .array([.object(["name": .string("untouched")])])])
    let stages = ViewStages()
    let ceiling = Date().addingTimeInterval(300)
    let context = storageViewContext()
      .withResponseGraphAuthorizer(BlobViewAuthorizer(source: source,
        reference: reference, listed: true, stages: stages))
      .withSecureDocumentContributor(BlobViewSecure(stages: stages, ceiling: ceiling))
      .withBlobResponseContributor(BlobViewSigner(stages: stages, ceiling: ceiling, fail: false))
    let prepared = try await ViewPreparationService().prepare(context: context, result: source,
      options: ViewOptions(mode: .governed, businessOutcome: .committed))
    XCTAssertEqual(stages.values, ["authorize", "secure", "blob"])
    XCTAssertEqual(source, .object(["document": .blob(reference),
      "nested": .array([.object(["name": .string("untouched")])])]))
    XCTAssertEqual(prepared.presentation, .object([
      "document": .string("https://files.example.invalid/read/asset"),
      "nested": .array([.object(["name": .string("untouched")])]),
      "governed": .bool(true),
    ]))
    XCTAssertEqual(prepared.document, .string("sealed-document"))
    XCTAssertEqual(prepared.expiresAt, ceiling.addingTimeInterval(-60))
    XCTAssertEqual(prepared.cacheControl, "private, no-store")
    XCTAssertNoThrow(try JSONEncoder().encode(prepared.presentation))
    XCTAssertThrowsError(try JSONEncoder().encode(source))
  }

  func testUnlistedBlobAndProviderFailureAreSafeAfterCommit() async throws {
    let reference = try BlobRef("blob_private_canary")
    let stages = ViewStages()
    let source: ViewValue = .object(["document": .blob(reference)])
    let options = ViewOptions(mode: .ordinary, businessOutcome: .committed)
    let missing = storageViewContext().withResponseGraphAuthorizer(
      BlobViewAuthorizer(source: source, reference: reference, listed: false, stages: stages))
    do {
      _ = try await ViewPreparationService().prepare(context: missing, result: source, options: options)
      XCTFail("unlisted BlobRef must fail")
    } catch let error as ViewPreparationError {
      XCTAssertEqual(error.code, "BLOB_CAPABILITY_MISSING")
      XCTAssertEqual(error.businessState, "committed")
      XCTAssertEqual(error.retry, "read")
      XCTAssertFalse(error.description.contains(reference.key))
    }
    let ceiling = Date().addingTimeInterval(300)
    let failing = storageViewContext()
      .withResponseGraphAuthorizer(BlobViewAuthorizer(source: source,
        reference: reference, listed: true, stages: stages))
      .withBlobResponseContributor(BlobViewSigner(stages: stages, ceiling: ceiling, fail: true))
    do {
      _ = try await ViewPreparationService().prepare(context: failing, result: source, options: options)
      XCTFail("provider failure must fail")
    } catch let error as ViewPreparationError {
      XCTAssertEqual(error.code, "VIEW_PREPARATION_FAILED")
      XCTAssertFalse(error.description.contains("PRIVATE-URL-CANARY"))
    }
  }
}

private struct ViewUnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    throw TeaQLError.execution("UNEXPECTED_QUERY")
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    throw TeaQLError.execution("UNEXPECTED_MUTATION")
  }
}

private func storageViewContext() -> UserContext {
  let executor = ViewUnusedExecutor()
  return UserContext(queryExecutor: executor, mutationExecutor: executor,
    requestPolicy: RequestPolicy { $0 })
}
