import Foundation

/// Pure validation of model-declared references. A custom Checker can repair
/// business values, but cannot change ownership or remove its loaded baseline.
package struct ContextRootAdmission {
  let context: UserContext
  let original: Mutation
  let fields: [String: String]

  init(context: UserContext, mutation: Mutation) {
    self.context = context; original = mutation
    fields = context.runtime.contextRootFields(named: mutation.entity.name)
  }

  private func originalValue(_ field: String, in values: TeaQLRecord) -> TeaQLValue? {
    guard let property = original.entity.property(named: field) else { return nil }
    return values[field] ?? values[property.name] ?? values[property.column]
  }
  private func absentCreateValue(_ value: TeaQLValue) -> Bool {
    // Generated new structs historically represent an unset reference as zero.
    original.kind == .create && (value == .null || value == .int(0) || value == .uint(0))
  }
  private func positiveID(_ value: TeaQLValue) -> Int64? {
    switch value {
    case .int(let id): return id > 0 ? id : nil
    case .uint(let id): return id > 0 && id <= UInt64(Int64.max) ? Int64(id) : nil
    default: return nil
    }
  }
  func validate(_ mutation: Mutation, final: Bool = false) throws {
    for field in fields.keys.sorted() {
      let target = fields[field]!
      guard let root = context.activeRoot, root.entity == target, let rootID = positiveID(root.id) else {
        try reject(field, rule: "context_root_missing"); continue
      }
      var seen = false
      func inspect(_ value: TeaQLValue) throws {
        if absentCreateValue(value) { return }
        seen = true
        if positiveID(value) != rootID { try reject(field, rule: "context_root_mismatch") }
      }
      if let value = originalValue(field, in: original.loadedValues) { try inspect(value) }
      if let value = originalValue(field, in: mutation.loadedValues) { try inspect(value) }
      if let value = original.values[field] { try inspect(value) }
      if let value = mutation.values[field] {
        if final && absentCreateValue(value) { try reject(field, rule: "context_root_missing") }
        try inspect(value)
      } else if final && original.kind == .create {
        try reject(field, rule: "context_root_missing")
      }
      if !seen && (original.kind != .create || final) { try reject(field, rule: "context_root_missing") }
    }
  }
  func applyCreateDefaults(_ mutation: inout Mutation) throws {
    guard original.kind == .create else { return }
    for field in fields.keys.sorted() where mutation.values[field].map(absentCreateValue) ?? true {
      let target = fields[field]!, root = try context.requireActiveRoot(target)
      mutation.values[field] = root.id
      context.recordFixEvidence(FixEvidence(entityType: original.entity.name, modelPath: field,
        source: .context, sourceLabel: "activeRoot:" + target))
    }
  }
  private func reject(_ field: String, rule: String) throws {
    // Neither raw root IDs nor request values cross this diagnostic boundary.
    throw CheckException(context.translateCheckResults([
      CheckResult(ruleID: rule, location: .property(field), entityType: original.entity.name)
    ]))
  }
}
