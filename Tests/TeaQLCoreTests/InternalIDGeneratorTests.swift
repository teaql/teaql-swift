import Foundation
import Testing
@testable import TeaQLCore

private enum AllocationFailure: Error { case refused }

private actor AllocationProvider: QueryExecutor, MutationExecutor, InternalIDGenerator {
  var reservations = 0
  var queries = 0
  var writes = 0
  let result: Int64
  let fails: Bool
  init(_ result: Int64, fails: Bool = false) { self.result = result; self.fails = fails }
  func nextID(for entity: String, context: UserContext) throws -> Int64 {
    reservations += 1
    if fails { throw AllocationFailure.refused }
    return result
  }
  func execute(_ request: QueryRequest) throws -> QueryResult { queries += 1; throw AllocationFailure.refused }
  func execute(_ request: MutationRequest) throws -> MutationResult { writes += 1; throw AllocationFailure.refused }
}

private struct NoAllocationProvider: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) throws -> QueryResult { throw AllocationFailure.refused }
  func execute(_ request: MutationRequest) throws -> MutationResult { throw AllocationFailure.refused }
}

private actor SuspendedAllocator: InternalIDGenerator {
  private var entered = false
  private var started: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Int64, Never>?
  func nextID(for entity: String, context: UserContext) async -> Int64 {
    if entered { return 43 }
    entered = true; started?.resume(); started = nil
    return await withCheckedContinuation { release = $0 }
  }
  func waitUntilEntered() async {
    if !entered { await withCheckedContinuation { started = $0 } }
  }
  func finish() { release?.resume(returning: 42); release = nil }
}

@Suite("Creation identity allocation")
struct InternalIDGeneratorTests {
  private func context(_ provider: AllocationProvider = AllocationProvider(99), generator: (any InternalIDGenerator)? = nil) -> UserContext {
    UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, internalIDGenerator: generator)
  }

  @Test func selectedAllocatorPrecedesProviderWithoutBusinessIO() async throws {
    let provider = AllocationProvider(99), selected = AllocationProvider(42), ctx = context(provider, generator: selected)
    #expect(try await ctx.generateInternalID(for: "WorkItem") == 42)
    #expect(await selected.reservations == 1); #expect(await provider.reservations == 0)
    #expect(await provider.queries == 0); #expect(await provider.writes == 0)
  }
  @Test func durableProviderIsTheDefaultAllocator() async throws {
    let provider = AllocationProvider(99), ctx = context(provider)
    #expect(try await ctx.generateInternalID(for: "WorkItem") == 99)
    #expect(await provider.reservations == 1); #expect(await provider.writes == 0)
  }
  @Test(arguments: [Int64(0), -1, Int64.min])
  func invalidSelectedValuesDoNotFallback(_ value: Int64) async throws {
    let provider = AllocationProvider(99), selected = AllocationProvider(value), ctx = context(provider, generator: selected)
    do { _ = try await ctx.generateInternalID(for: "WorkItem"); Issue.record("invalid ID returned") }
    catch let error as InternalIDError { #expect(error == .invalidValue(value)) }
    #expect(await selected.reservations == 1); #expect(await provider.reservations == 0)
    #expect(await provider.writes == 0)
  }
  @Test func originalErrorPropagatesWithoutFallback() async throws {
    let provider = AllocationProvider(99), selected = AllocationProvider(42, fails: true), ctx = context(provider, generator: selected)
    do { _ = try await ctx.generateInternalID(for: "WorkItem"); Issue.record("allocation error swallowed") }
    catch AllocationFailure.refused {}
    #expect(await selected.reservations == 1); #expect(await provider.reservations == 0)
  }
  @Test func missingAllocatorFailsClosed() async throws {
    let provider = NoAllocationProvider()
    let ctx = UserContext(queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 })
    do { _ = try await ctx.generateInternalID(for: "WorkItem"); Issue.record("implicit memory fallback") }
    catch let error as InternalIDError { #expect(error == .unavailable) }
  }
  @Test func invalidEntityIsRejectedBeforeAllocator() async throws {
    let provider = AllocationProvider(99), ctx = context(provider)
    do { _ = try await ctx.generateInternalID(for: " \n"); Issue.record("blank entity accepted") }
    catch let error as InternalIDError { #expect(error == .invalidEntityName) }
    #expect(await provider.reservations == 0)
  }
  @Test func memorySequencesAreTypeQualifiedAndSharedByContextCopies() async throws {
    let generator = try InMemoryInternalIDGenerator(), ctx = context(generator: generator), copied = ctx
    #expect(try await ctx.generateInternalID(for: "WorkItem") == 1)
    #expect(try await copied.generateInternalID(for: "WorkItem") == 2)
    #expect(try await copied.generateInternalID(for: "Platform") == 1)
  }
  @Test func memoryExhaustionNeverWraps() async throws {
    let generator = try InMemoryInternalIDGenerator(initialFloor: Int64.max - 1), ctx = context(generator: generator)
    #expect(try await ctx.generateInternalID(for: "WorkItem") == Int64.max)
    for _ in 0..<2 {
      do { _ = try await ctx.generateInternalID(for: "WorkItem"); Issue.record("allocator wrapped") }
      catch let error as InternalIDError { #expect(error == .exhausted("WorkItem")) }
    }
  }
  @Test func concurrentReservationsRemainUnique() async throws {
    let generator = try InMemoryInternalIDGenerator(), ctx = context(generator: generator)
    let ids = try await withThrowingTaskGroup(of: Int64.self) { group in
      for _ in 0..<64 { group.addTask { try await ctx.generateInternalID(for: "WorkItem") } }
      var ids: [Int64] = []; for try await id in group { ids.append(id) }; return ids
    }
    #expect(ids.sorted() == Array(1...64).map(Int64.init))
  }
  @Test func cancellationBeforeAllocationDoesNotCallProvider() async throws {
    let provider = AllocationProvider(99), ctx = context(provider)
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await ctx.generateInternalID(for: "WorkItem") }
    do { _ = try await task.value; Issue.record("cancelled creation returned ID") }
    catch is CancellationError {}
    #expect(await provider.reservations == 0)
  }
  @Test func cancellationAfterReservationReturnsNoIdentityAndReleasesGate() async throws {
    let allocator = SuspendedAllocator(), ctx = context(generator: allocator)
    let task = Task { try await ctx.generateInternalID(for: "WorkItem") }
    await allocator.waitUntilEntered(); task.cancel(); await allocator.finish()
    do { _ = try await task.value; Issue.record("cancelled creation returned ID") }
    catch is CancellationError {}
    #expect(try await ctx.generateInternalID(for: "WorkItem") == 43)
  }
  @Test func bootstrapContextPreservesSelectedAllocator() async throws {
    let selected = AllocationProvider(42), ctx = context(generator: selected)._generatedBootstrapContext()
    #expect(try await ctx.generateInternalID(for: "WorkItem") == 42)
    #expect(await selected.reservations == 1)
  }
}
