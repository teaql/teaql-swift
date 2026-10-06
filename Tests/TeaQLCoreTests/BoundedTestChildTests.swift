import Foundation
import XCTest
#if os(Linux)
import Glibc

final class BoundedTestChildTests: XCTestCase {
  private func capture(arguments: [String], timeout: TimeInterval = 2,
                       onSpawn: ((Int32) -> Void)? = nil) throws -> (Int32, String) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-child-control-\(UUID()).log")
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    process.environment = ["TEST_CHILD_VALUE": "safe fixture"]
    let status = try runBoundedTestChild(process, output: handle, timeout: timeout, onSpawn: onSpawn)
    return (status, try String(contentsOf: file, encoding: .utf8))
  }

  func testSuccessRetainsEnvironmentAndBothOutputStreams() throws {
    let (status, output) = try capture(arguments: ["-c", "printf '%s' \"$TEST_CHILD_VALUE\"; printf ':stderr' >&2"])
    XCTAssertEqual(status, 0)
    XCTAssertEqual(output, "safe fixture:stderr")
  }

  func testNonzeroExitDoesNotBecomeSuccess() throws {
    XCTAssertEqual(try capture(arguments: ["-c", "exit 7"]).0, 7)
  }

  func testTerminatingSignalDoesNotBecomeSuccess() throws {
    XCTAssertEqual(try capture(arguments: ["-c", "kill -TERM $$"]).0, 128 + SIGTERM)
  }

  func testTimeoutFailsWithinBoundAndReapsDirectChild() throws {
    // exec replaces the shell, so there is no descendant to leak on timeout.
    let started = DispatchTime.now().uptimeNanoseconds
    var pid: Int32 = 0
    XCTAssertThrowsError(try capture(arguments: ["-c", "exec /bin/sleep 10"], timeout: 0.1, onSpawn: { pid = $0 })) {
      XCTAssertEqual(($0 as NSError).domain, "TeaQLTestChild")
    }
    XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000, 2)
    var status: Int32 = 0
    XCTAssertGreaterThan(pid, 0)
    XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
    XCTAssertEqual(errno, ECHILD)
  }

  func testSpawnFailureIsNotAccepted() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-child-missing-\(UUID()).log")
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/__teaql_missing_test_child__")
    XCTAssertThrowsError(try runBoundedTestChild(process, output: handle))
  }
}
#endif
