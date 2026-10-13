import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import TeaQLCore
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import TeaQLStandardTelemetry

final class HTTPTransportTests: XCTestCase {
  private func module(_ host: String, losses: ExportLosses) throws -> StandardTelemetry {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledHTTP.self]
    let session = URLSession(configuration: configuration)
    let traces = OwnedOTLPExporter(endpoint: "http://\(host)", losses: losses, session: session)
    let metrics = OwnedOTLPExporter(endpoint: "http://\(host)", losses: losses, session: session)
    let logs = OwnedOTLPExporter(endpoint: "http://\(host)", losses: losses, session: session)
    return try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-http-test",
      TelemetryStartupConfiguration.endpointVariable: "http://\(host)",
    ]), traceExporter: traces, metricExporter: metrics, logExporter: logs, losses: losses)
  }

  func testOfficialProtobufThreeSignalTransportHasExplicitResourceAndNoAuthHeaders() async throws {
    ControlledHTTP.capture.reset()
    let telemetry = try module("accepted.invalid", losses: ExportLosses())
    await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {}
    await telemetry.flush()
    let requests = ControlledHTTP.capture.requests
    let traces = try XCTUnwrap(requests.first { $0.url?.path == "/v1/traces" })
    let logs = try XCTUnwrap(requests.first { $0.url?.path == "/v1/logs" })
    let metrics = try XCTUnwrap(requests.first { $0.url?.path == "/v1/metrics" })
    let traceMessage = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: XCTUnwrap(traces.httpBody))
    let logMessage = try Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest(serializedBytes: XCTUnwrap(logs.httpBody))
    let metricMessage = try Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest(serializedBytes: XCTUnwrap(metrics.httpBody))
    XCTAssertEqual(traceMessage.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans).count, 1)
    XCTAssertEqual(logMessage.resourceLogs.flatMap(\.scopeLogs).flatMap(\.logRecords).count, 1)
    XCTAssertFalse(metricMessage.resourceMetrics.isEmpty)
    for request in requests {
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
    }
    XCTAssertTrue(telemetry.exportLosses.isEmpty)
    await telemetry.shutdown()
  }

  func testFailedTransportHasVisibleCountsNoRetryQueueAndBusinessContinues() async throws {
    ControlledHTTP.capture.reset()
    let telemetry = try module("rejected.invalid", losses: ExportLosses())
    for _ in 0..<3 {
      let result = await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) { 42 }
      XCTAssertEqual(result, 42)
    }
    await telemetry.flush()
    XCTAssertEqual(telemetry.exportLosses["traces"], 3)
    XCTAssertEqual(telemetry.exportLosses["logs"], 3)
    XCTAssertGreaterThan(telemetry.exportLosses["metrics"] ?? 0, 0)
    let before = ControlledHTTP.capture.requests.filter { $0.url?.path == "/v1/traces" }.count
    await telemetry.flush()
    XCTAssertEqual(ControlledHTTP.capture.requests.filter { $0.url?.path == "/v1/traces" }.count, before,
      "failed spans must not accumulate in an unbounded retry queue")
    await telemetry.shutdown()
  }

  func testMalformedSuccessfulHTTPResponseIsNotAcceptedAsDelivered() async throws {
    ControlledHTTP.capture.reset()
    let losses = ExportLosses(), telemetry = try module("malformed.invalid", losses: losses)
    let result = await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) { 42 }
    XCTAssertEqual(result, 42)
    await telemetry.flush()
    XCTAssertEqual(telemetry.exportLosses["traces"], 1)
    XCTAssertEqual(telemetry.exportLosses["logs"], 1)
    XCTAssertGreaterThan(telemetry.exportLosses["metrics"] ?? 0, 0)
    await telemetry.shutdown()
  }

  func testOversizedAndWrongContentTypeAcknowledgementsAreRejected() async throws {
    for host in ["oversized.invalid", "wrong-type.invalid"] {
      ControlledHTTP.capture.reset()
      let telemetry = try module(host, losses: ExportLosses())
      await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {}
      await telemetry.flush()
      XCTAssertEqual(telemetry.exportLosses["traces"], 1, host)
      XCTAssertEqual(telemetry.exportLosses["logs"], 1, host)
      await telemetry.shutdown()
    }
  }

  func testPartialSuccessCountsReceiverRejectionWithoutWholeBatchFailure() async throws {
    ControlledHTTP.capture.reset()
    let telemetry = try module("partial.invalid", losses: ExportLosses())
    await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {}
    await telemetry.flush()
    XCTAssertTrue(telemetry.exportLosses.isEmpty)
    XCTAssertEqual(telemetry.rejectedRecords["traces"], 1)
    XCTAssertEqual(telemetry.rejectedRecords["logs"], 1)
    XCTAssertEqual(telemetry.rejectedRecords["metrics"], 7)
    for signal in ["traces", "logs", "metrics"] { XCTAssertEqual(telemetry.exportResponses[signal + ":partial_success"], 1) }
    let metrics = try XCTUnwrap(ControlledHTTP.capture.requests.first { $0.url?.path == "/v1/metrics" })
    let payload = try Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest(serializedBytes: XCTUnwrap(metrics.httpBody))
    XCTAssertLessThan(payload.resourceMetrics.flatMap(\.scopeMetrics).flatMap(\.metrics).count, 7,
      "Receiver rejects points, not MetricData objects")
    XCTAssertFalse(String(describing: telemetry.exportResponses).contains("PRIVATE-COLLECTOR-CANARY"))
    await telemetry.shutdown()
  }

  func testWarningCountsResponseButNotRejectedOrFailedRecords() async throws {
    ControlledHTTP.capture.reset()
    let telemetry = try module("warning.invalid", losses: ExportLosses())
    await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {}
    await telemetry.flush()
    XCTAssertTrue(telemetry.exportLosses.isEmpty); XCTAssertTrue(telemetry.rejectedRecords.isEmpty)
    for signal in ["traces", "logs", "metrics"] { XCTAssertEqual(telemetry.exportResponses[signal + ":warning"], 1) }
    await telemetry.shutdown()
  }

  func testTimedOutPrivateTransportClosesItsPendingRequest() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControlledHTTP.self]
    let transport = BoundedOTLPHTTP(configuration: configuration)
    let started = ContinuousClock.now
    let result = transport.send(URLRequest(url: URL(string: "http://never.invalid/v1/traces")!), timeout: 0.05)
    guard case .failed = result else { return XCTFail("deadline must fail") }
    XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    XCTAssertEqual(transport.activeRequests, 0)
    transport.shutdown()
    guard case .failed = transport.send(URLRequest(url: URL(string: "http://accepted.invalid/v1/traces")!), timeout: 0.05)
    else { return XCTFail("closed session must not reopen") }
    XCTAssertEqual(transport.activeRequests, 0)
  }

  func testMissingContentTypeOnlyAllowedForAnEmptyAcknowledgement() async throws {
    for host in ["empty-no-type.invalid", "body-no-type.invalid"] {
      let telemetry = try module(host, losses: ExportLosses())
      await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {}
      await telemetry.flush()
      if host == "empty-no-type.invalid" { XCTAssertTrue(telemetry.exportLosses.isEmpty) }
      else { XCTAssertEqual(telemetry.exportLosses["traces"], 1); XCTAssertEqual(telemetry.exportResponses["traces:invalid_response"], 1) }
      await telemetry.shutdown()
    }
  }
  func testShutdownCollectsFinalMetricsEvenWhenCallerDidNotFlush() async throws {
    ControlledHTTP.capture.reset()
    let telemetry = try module("accepted.invalid", losses: ExportLosses())
    await telemetry.withOperation(RuntimeOperation(family: "query", name: "School.list")) {}
    await telemetry.shutdown()
    XCTAssertEqual(ControlledHTTP.capture.requests.filter { $0.url?.path == "/v1/metrics" }.count, 1)
    XCTAssertTrue(telemetry.exportLosses.isEmpty)
    XCTAssertEqual(telemetry.exportResources, ["active_http_requests": 0, "owned_http_transports": 3,
      "closed_http_transports": 3, "lifecycle_workers": 0])
    await telemetry.shutdown()
    XCTAssertEqual(ControlledHTTP.capture.requests.filter { $0.url?.path == "/v1/metrics" }.count, 1)
  }
  func testNeverAcknowledgedFinalMetricsCannotExtendBackloggedShutdownBudget() async throws {
    ControlledHTTP.capture.reset()
    let telemetry = try module("never.invalid", losses: ExportLosses())
    for _ in 0..<3000 { await telemetry.withOperation(RuntimeOperation(family: "query", name: "backlog")) {} }
    let started = ContinuousClock.now
    await telemetry.shutdown()
    XCTAssertLessThan(started.duration(to: .now), .seconds(6))
    XCTAssertEqual(telemetry.exportResources, ["active_http_requests": 0, "owned_http_transports": 3,
      "closed_http_transports": 3, "lifecycle_workers": 0])
    XCTAssertEqual(telemetry.queueOutstanding, ["traces": 0, "logs": 0])
    XCTAssertGreaterThan(telemetry.exportLossReasons["metrics:export_failure"] ?? 0, 0)
    XCTAssertGreaterThan(telemetry.exportQueues["traces"]?["retired"] ?? 0, 0)
    XCTAssertGreaterThan(telemetry.exportQueues["logs"]?["retired"] ?? 0, 0)
  }
}

private final class HTTPRequests: @unchecked Sendable {
  private let lock = NSLock()
  private var saved: [URLRequest] = []
  var requests: [URLRequest] { lock.withLock { saved } }
  func append(_ request: URLRequest) { lock.withLock { saved.append(request) } }
  func reset() { lock.withLock { saved.removeAll() } }
}
private final class ControlledHTTP: URLProtocol {
  static let capture = HTTPRequests()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    // Darwin URLSession exposes upload bodies to URLProtocol as a stream.
    // Capture the actual bytes in both representations, rather than treating a
    // nil httpBody as an empty protobuf upload or weakening payload assertions.
    var captured = request
    if captured.httpBody == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
          client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeRawData))
          return
        }
        if count == 0 { break }
        bytes.append(contentsOf: buffer.prefix(count))
      }
      captured.httpBody = bytes
    }
    Self.capture.append(captured)
    if request.url?.host == "never.invalid" { return }
    if request.url?.host == "rejected.invalid" {
      client?.urlProtocol(self, didFailWithError: NSError(domain: "SecretTransport", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Authorization=SECRET-ERROR-CANARY"]))
    } else {
      let missingType = ["empty-no-type.invalid", "body-no-type.invalid"].contains(request.url?.host ?? "")
      let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: missingType ? [:] : ["Content-Type": request.url?.host == "wrong-type.invalid" ? "text/plain" : "application/x-protobuf"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      let body: Data
      switch request.url?.host {
      case "malformed.invalid": body = Data(repeating: 0xff, count: 8)
      case "oversized.invalid": body = Data(repeating: 0x58, count: 4 * 1024 * 1024 + 1)
      case "body-no-type.invalid": body = Data([0x0a, 0x00])
      case "partial.invalid", "warning.invalid":
        let partial = request.url?.host == "partial.invalid", message = "PRIVATE-COLLECTOR-CANARY"
        switch request.url?.path {
        case "/v1/traces":
          var response = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse()
          response.partialSuccess.rejectedSpans = partial ? 1 : 0; response.partialSuccess.errorMessage = message
          body = (try? response.serializedData()) ?? Data([0xff])
        case "/v1/logs":
          var response = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse()
          response.partialSuccess.rejectedLogRecords = partial ? 1 : 0; response.partialSuccess.errorMessage = message
          body = (try? response.serializedData()) ?? Data([0xff])
        default:
          var response = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse()
          response.partialSuccess.rejectedDataPoints = partial ? 7 : 0; response.partialSuccess.errorMessage = message
          body = (try? response.serializedData()) ?? Data([0xff])
        }
      default: body = Data()
      }
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}
