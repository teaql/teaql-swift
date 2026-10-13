import Foundation
import OpenTelemetryProtocolExporterCommon
import XCTest
@testable import TeaQLStandardTelemetry

final class OTLPAcknowledgementTests: XCTestCase {
  private func body(_ signal: String, count: Int64, message: String = "") throws -> Data {
    switch signal {
    case "traces":
      var response = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse()
      response.partialSuccess.rejectedSpans = count; response.partialSuccess.errorMessage = message
      return try response.serializedData()
    case "logs":
      var response = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse()
      response.partialSuccess.rejectedLogRecords = count; response.partialSuccess.errorMessage = message
      return try response.serializedData()
    default:
      var response = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse()
      response.partialSuccess.rejectedDataPoints = count; response.partialSuccess.errorMessage = message
      return try response.serializedData()
    }
  }
  func testEmptyAndExplicitDefaultSuccessForAllSignals() throws {
    for signal in ["traces", "logs", "metrics"] {
      for data in [Data(), Data([0x0a, 0x00])] {
        XCTAssertEqual(try OTLPAcknowledgement.decode(data, signal: signal, submitted: 3),
          OTLPAcknowledgement(rejected: 0, warning: false))
      }
    }
  }
  func testPartialRejectionDoesNotRetainPrivateCollectorText() throws {
    for signal in ["traces", "logs", "metrics"] {
      let value = try OTLPAcknowledgement.decode(body(signal, count: 2, message: "PRIVATE-COLLECTOR-CANARY"), signal: signal, submitted: 3)
      XCTAssertEqual(value.rejected, 2); XCTAssertTrue(value.warning)
      XCTAssertFalse(String(describing: value).contains("PRIVATE-COLLECTOR-CANARY"))
    }
  }
  func testZeroRejectionWarningIsDistinctFromLoss() throws {
    let value = try OTLPAcknowledgement.decode(body("traces", count: 0, message: "PRIVATE"), signal: "traces", submitted: 1)
    XCTAssertEqual(value.rejected, 0); XCTAssertTrue(value.warning)
  }
  func testNegativeAndOverSubmittedCountsAreInvalid() throws {
    for signal in ["traces", "logs", "metrics"] {
      for count: Int64 in [-1, 4] {
        XCTAssertThrowsError(try OTLPAcknowledgement.decode(body(signal, count: count), signal: signal, submitted: 3))
      }
    }
  }
  func testWrongKnownWireTypesTruncationAndInvalidUTF8AreRejected() {
    for bytes: [UInt8] in [[0x08, 0], [0x0a, 2, 0x0a, 0], [0x0a, 0x7f], [0x0a, 3, 0x12, 1, 0xff], [0], Array(repeating: 0xff, count: 12)] {
      XCTAssertThrowsError(try OTLPAcknowledgement.decode(Data(bytes), signal: "traces", submitted: 1), "\(bytes)")
    }
  }
  func testUnknownScalarFieldsAllowedButGroupsNeverRecursed() throws {
    XCTAssertEqual(try OTLPAcknowledgement.decode(Data([0x10, 0x7b]), signal: "traces", submitted: 1).rejected, 0)
    let deep = Data(Array(repeating: [UInt8(0x13)], count: 200).flatMap { $0 }
      + Array(repeating: [UInt8(0x14)], count: 200).flatMap { $0 })
    XCTAssertThrowsError(try OTLPAcknowledgement.decode(deep, signal: "traces", submitted: 1))
  }
  func testResponseByteBoundary() throws {
    // A valid opaque unknown field reaches exactly the four-MiB boundary.
    var value = UInt64(OTLPAcknowledgement.maximumBytes - 5), length: [UInt8] = []
    repeat { let byte = UInt8(value & 0x7f); value >>= 7; length.append(value == 0 ? byte : byte | 0x80) } while value > 0
    let body = Data([0x12] + length) + Data(repeating: 0, count: OTLPAcknowledgement.maximumBytes - 5)
    XCTAssertEqual(body.count, OTLPAcknowledgement.maximumBytes)
    XCTAssertEqual(try OTLPAcknowledgement.decode(body, signal: "traces", submitted: 1).rejected, 0)
    XCTAssertThrowsError(try OTLPAcknowledgement.decode(body + Data([0]), signal: "traces", submitted: 1))
  }
}
