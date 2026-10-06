import TeaQLCore
import TeaQLSQLite

// Intentionally invalid external consumer: child reasons cannot stand in for
// a required root Mutation Request. The public bypass must not exist.
func unsafeBatch(_ provider: SQLiteDataService, children: [Mutation]) async throws {
  _ = try await provider.transaction(children)
}
