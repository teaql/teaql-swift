import Foundation
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf

/// Collector text is reduced to a boolean; it never becomes a diagnostic.
struct OTLPAcknowledgement: Sendable, Equatable {
  static let maximumBytes = 4 * 1024 * 1024
  let rejected: Int64
  let warning: Bool
  enum Invalid: Error { case response }

  static func decode(_ body: Data, signal: String, submitted: Int) throws -> Self {
    guard body.count <= maximumBytes, submitted >= 0 else { throw Invalid.response }
    try validate(body, partial: false)
    var options = BinaryDecodingOptions(); options.messageDepthLimit = 16
    let rejected: Int64, warning: Bool
    switch signal {
    case "traces":
      let response = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse(serializedBytes: body, options: options)
      rejected = response.partialSuccess.rejectedSpans; warning = !response.partialSuccess.errorMessage.isEmpty
    case "logs":
      let response = try Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse(serializedBytes: body, options: options)
      rejected = response.partialSuccess.rejectedLogRecords; warning = !response.partialSuccess.errorMessage.isEmpty
    case "metrics":
      let response = try Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse(serializedBytes: body, options: options)
      rejected = response.partialSuccess.rejectedDataPoints; warning = !response.partialSuccess.errorMessage.isEmpty
    default: throw Invalid.response
    }
    guard rejected >= 0, rejected <= Int64(submitted) else { throw Invalid.response }
    return Self(rejected: rejected, warning: warning)
  }

  // Validate known field wire types before the official decoder can preserve
  // them as unknown fields. Groups are unsupported, including unknown groups.
  private static func validate(_ body: Data, partial: Bool) throws {
    var offset = 0
    func varint() throws -> UInt64 {
      var value: UInt64 = 0
      for index in 0..<10 {
        guard offset < body.count else { throw Invalid.response }
        let byte = body[offset]; offset += 1
        if index == 9 && byte > 1 { throw Invalid.response }
        value |= UInt64(byte & 0x7f) << (index * 7)
        if byte & 0x80 == 0 { return value }
      }
      throw Invalid.response
    }
    while offset < body.count {
      let tag = try varint(), field = tag >> 3, wire = tag & 7
      guard field > 0, field <= 0x1fffffff else { throw Invalid.response }
      if field == 1 && wire != (partial ? 0 : 2) { throw Invalid.response }
      if partial && field == 2 && wire != 2 { throw Invalid.response }
      switch wire {
      case 0: _ = try varint()
      case 1:
        guard body.count - offset >= 8 else { throw Invalid.response }; offset += 8
      case 2:
        let size = try varint()
        guard size <= UInt64(body.count - offset) else { throw Invalid.response }
        let end = offset + Int(size)
        if !partial && field == 1 { try validate(body.subdata(in: offset..<end), partial: true) }
        offset = end
      case 5:
        guard body.count - offset >= 4 else { throw Invalid.response }; offset += 4
      default: throw Invalid.response
      }
    }
  }
}
