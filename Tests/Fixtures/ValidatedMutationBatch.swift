import TeaQLCore
import TeaQLSQLite

func safeBatch(_ context: UserContext, children: [Mutation]) async throws -> [MutationResult] {
  try await context.execute(MutationBatchRequest(mutations: children, comment: "process validated batch"))
}
