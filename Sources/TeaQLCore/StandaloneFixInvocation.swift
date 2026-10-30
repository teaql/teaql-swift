import Foundation

/// A standalone call owns its snapshot and evidence. This capability is passed
/// only in the invocation's Context copy; independent roots never inherit it
/// from shared Context state or a task/thread-global current invocation.
package final class StandaloneFixInvocation: @unchecked Sendable {
  package let time: Date
  private let lock = NSLock()
  private var active = true
  private var evidence: [FixEvidence] = []

  package init(time: Date) { self.time = time }

  package func ensureActive() throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("Standalone Fix invocation is already closed") }
    }
  }

  package func record(_ value: FixEvidence) {
    lock.withLock { if active { evidence.append(value) } }
  }

  package func finish() -> [FixEvidence] {
    lock.withLock {
      precondition(active)
      active = false
      let result = evidence
      evidence = []
      return result
    }
  }
}
