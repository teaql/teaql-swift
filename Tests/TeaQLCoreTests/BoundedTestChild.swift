import Foundation
#if os(Linux)
import Glibc
#endif

/// Test-only subprocess execution. The Linux path does not require Foundation's
/// CFSocket-based process monitor, which may be unavailable in a restricted runner.
/// A timeout is a failure, not an implicit pass; only this invocation's child is reaped.
func runBoundedTestChild(_ process: Process, output: FileHandle,
                         timeout: TimeInterval = 30,
                         onSpawn: ((Int32) -> Void)? = nil) throws -> Int32 {
  precondition(timeout > 0 && timeout.isFinite)
  #if os(Linux)
  guard let executable = process.executableURL else { throw POSIXError(.EINVAL) }
  let arguments = [executable.path] + (process.arguments ?? [])
  let environment = (process.environment ?? ProcessInfo.processInfo.environment)
    .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
  guard !arguments.contains(where: { $0.utf8.contains(0) }),
        !environment.contains(where: { $0.utf8.contains(0) }) else { throw POSIXError(.EINVAL) }
  let allocated = (arguments + environment).map { strdup($0) }
  defer { allocated.forEach { free($0) } }
  guard allocated.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
  var argv = Array(allocated.prefix(arguments.count)) + [nil]
  var envp = Array(allocated.dropFirst(arguments.count)) + [nil]
  var actions = posix_spawn_file_actions_t()
  func check(_ code: Int32) throws {
    if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
  }
  try check(posix_spawn_file_actions_init(&actions))
  defer { posix_spawn_file_actions_destroy(&actions) }
  let descriptor = output.fileDescriptor
  try check(posix_spawn_file_actions_adddup2(&actions, descriptor, STDOUT_FILENO))
  try check(posix_spawn_file_actions_adddup2(&actions, descriptor, STDERR_FILENO))
  if descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
    try check(posix_spawn_file_actions_addclose(&actions, descriptor))
  }
  var pid: pid_t = 0
  let spawned = argv.withUnsafeMutableBufferPointer { argv in
    envp.withUnsafeMutableBufferPointer { envp in
      posix_spawn(&pid, executable.path, &actions, nil, argv.baseAddress!, envp.baseAddress!)
    }
  }
  try check(spawned)
  onSpawn?(pid)
  let started = DispatchTime.now().uptimeNanoseconds
  let limit = UInt64(timeout * 1_000_000_000)
  var status: Int32 = 0
  while true {
    let waited = waitpid(pid, &status, WNOHANG)
    if waited == pid {
      let signal = status & 0x7f
      return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
    if waited < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    if DispatchTime.now().uptimeNanoseconds - started >= limit {
      // No shell/descendant commands are used by the callers. Never leave the direct child running.
      _ = kill(pid, SIGKILL)
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      throw NSError(domain: "TeaQLTestChild", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Test child exceeded bounded timeout"])
    }
    Thread.sleep(forTimeInterval: 0.01)
  }
  #else
  try process.run()
  let started = DispatchTime.now().uptimeNanoseconds
  while process.isRunning && DispatchTime.now().uptimeNanoseconds - started < UInt64(timeout * 1_000_000_000) {
    Thread.sleep(forTimeInterval: 0.01)
  }
  guard !process.isRunning else {
    process.terminate()
    throw NSError(domain: "TeaQLTestChild", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Test child exceeded bounded timeout"])
  }
  return process.terminationStatus
  #endif
}
