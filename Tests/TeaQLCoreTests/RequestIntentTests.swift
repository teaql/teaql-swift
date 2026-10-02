import Foundation
import XCTest
@testable import TeaQLCore

final class RequestIntentTests: XCTestCase {
  private let entity = EntityDescriptor(name: "School", table: "school_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])

  func testSharedRequestConstructionVectors() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("test-vectors/request-intent-v1.json"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(fixture["contract"] as? String, "teaql.request-intent.v1")
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
    XCTAssertEqual(cases.count, 20)
    for test in cases {
      let id = try XCTUnwrap(test["id"] as? String)
      let kind = try XCTUnwrap(test["kind"] as? String)
      let input = try XCTUnwrap(test["input"] as? [String: Any])
      do {
        let comment: String
        if kind == "query" {
          var query = SelectQuery(entity: entity)
          query.comment = input["comment"] as? String
          query.purpose = input["purpose"] as? String
          query.tracePath = (input["trace"] as? [[String: Any]] ?? []).map {
            TraceNode(entity: "School", comment: $0["detail"] as? String ?? "",
              purpose: "", kind: $0["kind"] as? String ?? "request")
          }
          let request = try QueryRequest(query: query)
          comment = request.intent.comment
          let expected = test["expected"] as? [String: String]
          XCTAssertEqual(request.intent.purpose, expected?["purpose"], id)
        } else {
          // No trace/child reason can supply the mandatory root property.
          let request = try MutationRequest(mutation: Mutation(kind: .create, entity: entity),
            comment: input["comment"] as? String)
          comment = request.intent.comment
        }
        XCTAssertNil(test["error"], id)
        XCTAssertEqual(comment, (test["expected"] as? [String: String])?["comment"], id)
      } catch let error as RequestIntentError {
        let expected = try XCTUnwrap(test["error"] as? [String: String], id)
        XCTAssertEqual(error.code, expected["code"], id)
        XCTAssertEqual(error.field, expected["field"], id)
        XCTAssertEqual(error.requestKind, kind, id)
      }
    }
  }

  func testUnicodeBlankSemanticsAndSafeFormatting() throws {
    let whitespace: [UInt32] = Array(0x09...0x0D) + [0x20, 0x85, 0xA0, 0x1680]
      + Array(0x2000...0x200A) + [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
    for value in whitespace {
      let text = String(UnicodeScalar(value)!)
      XCTAssertThrowsError(try QueryIntent(comment: text, purpose: "verify")) {
        XCTAssertEqual(($0 as? RequestIntentError)?.field, "comment")
      }
      XCTAssertThrowsError(try MutationIntent(comment: text))
    }
    for text in ["\u{FEFF}", "\u{200B}"] {
      XCTAssertEqual(try MutationIntent(comment: text).comment, text)
    }
    let query = try QueryIntent(comment: "INTENT-CANARY", purpose: "PURPOSE-CANARY")
    let mutation = try MutationIntent(comment: "MUTATION-CANARY")
    XCTAssertFalse(String(describing: query).contains("INTENT-CANARY"))
    XCTAssertFalse(String(reflecting: query).contains("PURPOSE-CANARY"))
    XCTAssertFalse(String(reflecting: mutation).contains("MUTATION-CANARY"))
    XCTAssertEqual(try mutation.readbackIntent().comment, "MUTATION-CANARY")
  }

  func testCapturedIntentCannotBeReplacedByBuilderOrPayloadChanges() throws {
    var query = SelectQuery(entity: entity)
    query.comment = " original root "; query.purpose = "verify ownership"
    let request = try QueryRequest(query: query)
    query.comment = "changed builder"; query.purpose = nil
    XCTAssertEqual(request.query.comment, " original root ")
    XCTAssertEqual(request.withQuery(query).query.comment, " original root ")
    XCTAssertEqual(request.withQuery(query).query.purpose, "verify ownership")
    var mutation = Mutation(kind: .create, entity: entity, auditReason: "original root")
    let write = try MutationRequest(mutation: mutation)
    mutation.auditReason = "changed payload"
    XCTAssertEqual(write.withMutation(mutation).mutation.auditReason, "original root")
  }

  func testDecoderReturnsStructuredErrorsWithoutEchoingValues() throws {
    for json in ["{}", "{\"comment\":null}", "{\"comment\":17}", "{\"comment\":{\"secret\":\"CANARY\"}}"] {
      XCTAssertThrowsError(try JSONDecoder().decode(MutationIntent.self, from: Data(json.utf8))) {
        XCTAssertEqual(($0 as? RequestIntentError)?.code, "REQUEST_COMMENT_REQUIRED")
        XCTAssertFalse(String(describing: $0).contains("CANARY"))
      }
    }
  }

  func testBatchOwnsRootIntentAndRetainsPerItemReasons() throws {
    let input = [
      Mutation(kind: .create, entity: entity, values: ["id": .int(1)], auditReason: "batch root"),
      Mutation(kind: .create, entity: entity, values: ["id": .int(2)], auditReason: "second child"),
      Mutation(kind: .create, entity: entity, values: ["id": .int(3)]),
      Mutation(kind: .create, entity: entity, values: ["id": .int(4)], auditReason: "\u{85}"),
    ]
    let batch = try MutationBatchRequest(mutations: input, comment: "batch root")
    let items = batch.mutations
    XCTAssertEqual(items.map(\.auditReason), Array(repeating: "batch root", count: 4))
    XCTAssertEqual(items[0].mutationLineage?.map(\.comment), ["batch root"])
    XCTAssertEqual(items[0].mutationLineage?.map(\.entityID), [.int(1)])
    XCTAssertEqual(items[1].mutationLineage?.map(\.comment), ["batch root", "second child"])
    XCTAssertEqual(items[1].mutationLineage?.map(\.entityID), [nil, .int(2)])
    XCTAssertEqual(items[2].mutationLineage?.map(\.comment), ["batch root"])
    XCTAssertEqual(items[3].mutationLineage?.map(\.comment), ["batch root"])
    XCTAssertEqual(input[1].auditReason, "second child")
    XCTAssertNil(input[2].auditReason)
    XCTAssertEqual(input[3].auditReason, "\u{85}")
    XCTAssertFalse(String(reflecting: batch).contains("second child"))
  }

  func testBatchDecoderValidatesRootBeforeChildrenAndRoundTripsSnapshot() throws {
    for json in ["{}", "{\"comment\":null}", "{\"comment\":17}",
        "{\"comment\":\"\\u0085\",\"mutations\":\"PAYLOAD-CANARY\"}"] {
      XCTAssertThrowsError(try JSONDecoder().decode(MutationBatchRequest.self, from: Data(json.utf8))) {
        let error = $0 as? RequestIntentError
        XCTAssertEqual(error?.code, "REQUEST_COMMENT_REQUIRED")
        XCTAssertEqual(error?.field, "comment")
        XCTAssertFalse(String(describing: $0).contains("PAYLOAD-CANARY"))
      }
    }
    var source = [Mutation(kind: .create, entity: entity, values: ["id": .int(10)], auditReason: "local child")]
    let batch = try MutationBatchRequest(mutations: source, comment: " preserved root ")
    source[0].auditReason = "changed source"; source[0].values["id"] = .int(99)
    let roundTrip = try JSONDecoder().decode(MutationBatchRequest.self, from: JSONEncoder().encode(batch))
    XCTAssertEqual(roundTrip.intent.comment, " preserved root ")
    XCTAssertEqual(roundTrip.mutations[0].values["id"], .int(10))
    XCTAssertEqual(roundTrip.mutations[0].mutationLineage?.map(\.comment), [" preserved root ", "local child"])
  }
}
