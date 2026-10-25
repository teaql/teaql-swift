/// No provider capability escapes into generated graph preparation. This also
/// blocks a checker that calls the preparation Context's public executor SPI.
package struct GraphPreparationExecutor: QueryExecutor, MutationExecutor {
  package func execute(_ request: QueryRequest) async throws -> QueryResult {
    throw TeaQLError.execution("GRAPH_PREPARATION_CANNOT_ACCESS_PROVIDER")
  }
  package func count(_ request: QueryRequest) async throws -> Int {
    throw TeaQLError.execution("GRAPH_PREPARATION_CANNOT_ACCESS_PROVIDER")
  }
  package func execute(_ request: MutationRequest) async throws -> MutationResult {
    throw TeaQLError.execution("GRAPH_PREPARATION_CANNOT_ACCESS_PROVIDER")
  }
}
