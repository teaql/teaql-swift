import Foundation
import XCTest
@testable import TeaQLCore

private struct ReadyBlobCapability: RuntimeCapabilityProvider {
  func checkReady(context: UserContext) async throws {}
}

final class BlobReferenceValueTests: XCTestCase {
  func testSharedValueVectorsAndSQLText() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("test-vectors/blob-value-cases.json")
    let data = try Data(contentsOf: fixtureURL)
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(fixture["schema"] as? String, "teaql.blob-value-cases/v1")
    for key in try XCTUnwrap(fixture["valid"] as? [String]) {
      let reference = try BlobRef(key)
      XCTAssertEqual(reference.key, key)
      XCTAssertEqual(reference.sqlText, key)
      XCTAssertEqual(try BlobRef(sqlText: key), reference)
      XCTAssertEqual(try JSONDecoder().decode(BlobRef.self, from: JSONEncoder().encode(key)), reference)
      XCTAssertThrowsError(try JSONEncoder().encode(reference))
      XCTAssertEqual(String(describing: reference), "BlobRef[masked]")
    }
    for key in try XCTUnwrap(fixture["invalid"] as? [String]) {
      XCTAssertThrowsError(try BlobRef(key), key)
    }
    for value in try XCTUnwrap(fixture["invalidJson"] as? [Any]) {
      XCTAssertThrowsError(try JSONDecoder().decode(BlobRef.self,
        from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])))
    }
    let formats = try XCTUnwrap(fixture["formats"] as? [String: String])
    let spec = try BlobFieldSpec(entity: "Document", field: "file",
      extensions: Array(formats.keys) + ["jpg"], nullable: false, policyProfile: "default")
    XCTAssertEqual(spec.allowedExtensions, formats.keys.sorted())
    XCTAssertEqual(spec.allowedContentTypes, Array(Set(formats.values)).sorted())
    XCTAssertEqual(spec.maxFiles, 1)
    XCTAssertThrowsError(try BlobFieldSpec(entity: "Document", field: "file",
      extensions: ["exe"], nullable: false, policyProfile: "default"))
  }

  func testModuleCapabilityPrecedesSchemaProvider() async throws {
    let module = RuntimeModule(name: "blob", entities: [], requiredCapabilities: ["blob.v1", "blob.v1"])
    var runtime = TeaQLRuntime()
    try runtime.install(module)
    XCTAssertEqual(runtime.requiredCapabilities, ["blob.v1"])
    let executor = MissingBlobExecutor()
    let context = UserContext(runtime: runtime, queryExecutor: executor,
      mutationExecutor: executor, requestPolicy: RequestPolicy { $0 })
    do {
      try await context.ensureSchema(module)
      XCTFail("missing capability must fail before provider")
    } catch let error as TeaQLError {
      XCTAssertEqual(error, .execution("RUNTIME_CAPABILITY_MISSING"))
    }
    let ready = context.withRuntimeCapability("blob.v1", provider: ReadyBlobCapability())
    do {
      try await ready.ensureSchema(module)
      XCTFail("provider lacks schema support")
    } catch let error as TeaQLError {
      XCTAssertNotEqual(error, .execution("RUNTIME_CAPABILITY_MISSING"))
    }

    let graphProvider = BlobGraphCounter()
    let graphContext = UserContext(runtime: runtime, queryExecutor: graphProvider,
      mutationExecutor: graphProvider, requestPolicy: RequestPolicy { $0 })
    do {
      _ = try await graphContext.executeGraphSave(comment: "save with blob module") { _, _ in 1 }
      XCTFail("missing capability must precede BEGIN")
    } catch let error as TeaQLError {
      XCTAssertEqual(error, .execution("RUNTIME_CAPABILITY_MISSING"))
    }
    let before = await graphProvider.beginCount
    XCTAssertEqual(before, 0)
    let graphReady = graphContext.withRuntimeCapability("blob.v1", provider: ReadyBlobCapability())
    let value = try await graphReady.executeGraphSave(comment: "save with ready module") { _, _ in 7 }
    XCTAssertEqual(value, 7)
    let after = await graphProvider.beginCount
    XCTAssertEqual(after, 1)
  }
}

private actor BlobGraphCounter: QueryExecutor, GraphTransactionExecutor {
  private(set) var beginCount = 0
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    throw TeaQLError.execution("UNEXPECTED_QUERY")
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    throw TeaQLError.execution("UNEXPECTED_MUTATION")
  }
  func beginGraphTransaction() { beginCount += 1 }
  func commitGraphTransaction() {}
  func rollbackGraphTransaction() {}
}

private struct MissingBlobExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    throw TeaQLError.execution("UNEXPECTED_QUERY")
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    throw TeaQLError.execution("UNEXPECTED_MUTATION")
  }
}
