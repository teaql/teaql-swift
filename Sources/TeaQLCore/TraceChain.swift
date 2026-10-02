import Foundation

/// Business intent and physical route are separate values.
public struct TraceIntentFields: Sendable, Equatable {
  public let comment: String?
  public let purpose: String?
  public let auditReason: String?
}

public enum TraceChain {
  public static func assignedLineage(_ lineage: [TraceNode], key: EntityKey) -> [TraceNode] {
    let leaf = lineage.lastIndex { node in
      node.kind.lowercased() == "auditreason" && node.name == key.entity
        && (node.entityID == nil || (node.entityID?.int64Value ?? 0) <= 0)
    }
    return lineage.enumerated().map { index, node in
      guard index == leaf else { return node }
      return TraceNode(entity: node.entity, comment: node.comment, purpose: node.purpose,
        level: node.level, kind: node.kind, name: node.name, entityID: key.id)
    }
  }

  package static func maskLineage(_ lineage: [TraceNode], values: [TeaQLValue]) -> [TraceNode] {
    lineage.map { node in
      TraceNode(entity: node.entity, comment: LogPrivacy.scrub(node.comment, values: values),
        purpose: LogPrivacy.scrub(node.purpose, values: values), level: node.level,
        kind: node.kind, name: node.name, entityID: node.entityID)
    }
  }

  private static func isIntent(_ node: TraceNode) -> Bool {
    ["comment", "purpose", "auditreason"].contains(node.kind.lowercased())
  }

  public static func intent(_ source: [TraceNode]) -> TraceIntentFields {
    func last(_ kind: String) -> String? {
      source.last { $0.kind.lowercased() == kind }?.comment
    }
    return TraceIntentFields(comment: last("comment"), purpose: last("purpose"),
      auditReason: last("auditreason"))
  }

  /// Rust-canonical physical path. Unit inputs are not execution evidence.
  public static func canonical(
    _ source: [TraceNode], backend: String, operation: String
  ) -> [TraceNode] {
    func has(_ kind: String) -> Bool { source.contains { $0.kind.lowercased() == kind } }
    func nonblank(_ value: String) -> Bool {
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let nodes: [TraceNode]
    if has("operation") && has("provider") && has("sql") {
      nodes = source.filter { !isIntent($0) }
    } else {
      let root = source.first { nonblank($0.name) }?.name ?? "unknown"
      let query = operation == "select"
      let entity = query ? root
        : source.last { $0.kind.lowercased() == "entity" && nonblank($0.name) }?.name ?? root
      let provider = nonblank(backend) ? backend : "unknown"
      nodes = [
        TraceNode(entity: root, comment: query ? "query" : "mutation", purpose: "",
          kind: "operation", name: root),
        TraceNode(entity: entity, comment: "", purpose: "", kind: query ? "request" : "entity", name: entity),
      ] + source.filter { $0.kind.lowercased() == "relation" } + [
        TraceNode(entity: root, comment: "", purpose: "", kind: "provider", name: provider),
        TraceNode(entity: root, comment: "", purpose: "", kind: "sql", name: operation),
      ]
    }
    return nodes.enumerated().map { index, node in
      TraceNode(entity: node.entity, comment: node.comment, purpose: node.purpose,
        level: index, kind: node.kind, name: node.name, entityID: node.entityID)
    }
  }

  /// A readback is another physical SELECT, not a second SQL leaf in the write.
  public static func readback(_ write: [TraceNode]) -> [TraceNode] {
    let root = write.first?.entity ?? "unknown"
    let nodes = write.filter { $0.kind.lowercased() != "sql" }
      + [TraceNode(entity: root, comment: "", purpose: "", kind: "sql", name: "select")]
    return nodes.enumerated().map { index, node in
      TraceNode(entity: node.entity, comment: node.comment, purpose: node.purpose,
        level: index, kind: node.kind, name: node.name, entityID: node.entityID)
    }
  }
}
