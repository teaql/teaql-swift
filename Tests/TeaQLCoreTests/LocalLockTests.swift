import Foundation
import Testing
@testable import TeaQLCore

@Test func localLockEnforcesOwnershipTimeoutAndLeaseExpiry() async throws {
  let lock = LocalLock()
  let first = UUID()
  let second = UUID()
  let key = "local-lock"

  #expect(lock.tryLock(key, owner: first, timeoutMillis: 0, expireMillis: 50))
  #expect(!lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 50))
  lock.unlock(key, owner: second)
  #expect(!lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 50))
  try await Task.sleep(for: .milliseconds(60))
  #expect(lock.tryLock(key, owner: second, timeoutMillis: 0, expireMillis: 50))
  lock.unlock(key, owner: second)
  #expect(lock.tryLock(key, owner: first, timeoutMillis: 0, expireMillis: 50))
}
