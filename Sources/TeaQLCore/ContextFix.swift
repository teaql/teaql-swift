import Foundation

public struct ContextFixInput: Sendable {
  public let entity: String
  public let field: String
  public let function: String
  public let arguments: [String]
  public let operation: MutationKind
  public let now: Date
}

/// Trusted synchronous inputs. Resolve HTTP/async work before entering Save.
public protocol ContextFixResolver: Sendable {
  func resolve(context: UserContext, input: ContextFixInput) throws -> TeaQLValue
}

/// Application-owned declarations supplement generated field metadata without
/// replacing a generated entity's identity, schema or native descriptor.
public struct ContextFieldFunctions: Sendable, Hashable {
  public let create: String?
  public let update: String?
  public init(create: String? = nil, update: String? = nil) { self.create = create; self.update = update }
}

// Passed only to the invocation's Context value-copy, not shared Context state,
// a task-global current ledger, a generated entity field or a wire capability.
package final class ContextFixFrame: @unchecked Sendable {
  let original: Mutation
  let allowed: Bool
  let fields: [String: ContextFieldFunctions]
  private let lock = NSLock()
  private var active = true
  init(_ original: Mutation, fields: [String: ContextFieldFunctions]) {
    self.original = original
    self.fields = fields
    allowed = Self.hasBusinessChange(original, baseline: original, fields: fields)
  }
  private static func hasBusinessChange(_ mutation: Mutation, baseline: Mutation,
    fields: [String: ContextFieldFunctions]) -> Bool {
    mutation.kind == .create || mutation.kind == .update && mutation.values.contains { field, value in
      guard !field.hasPrefix("_"), field != "id", field != "version", fields[field] == nil else { return false }
      guard let property = baseline.entity.property(named: field) else { return true }
      let old = baseline.loadedValues[property.name] ?? baseline.loadedValues[field] ?? baseline.loadedValues[property.column]
      return old.map { !LoadedScalarRestoration.same(value, $0, property: property) } ?? true
    }
  }
  func normalizeFinalIntent(_ mutation: inout Mutation) {
    guard mutation.kind == .update, !Self.hasBusinessChange(mutation, baseline: original, fields: fields) else { return }
    for field in fields.keys { mutation.values[field] = original.values[field] }
  }
  func isActive() -> Bool { lock.withLock { active } }
  func close() { lock.withLock { active = false } }
}

public enum ContextFix {
  package static func fields(_ context: UserContext, mutation: Mutation) -> [String: ContextFieldFunctions] {
    var fields = context.runtime.contextFixFields(named: mutation.entity.name)
    for property in mutation.entity.properties where property.createFunction != nil || property.updateFunction != nil {
      fields[property.modelName ?? property.name] = ContextFieldFunctions(create: property.createFunction, update: property.updateFunction)
    }
    return fields
  }
  public static func allowed(_ context: UserContext, mutation: Mutation) -> Bool {
    guard let frame = context.contextFixFrame, frame.isActive(), owns(frame, mutation) else { return false }
    return frame.allowed
  }

  public static func apply(_ context: UserContext, mutation: inout Mutation, now: Date,
    field: String, function: String, arguments: [String] = []) throws {
    func invalid() -> CheckException {
      CheckException(context.translateCheckResults([CheckResult(ruleID: "invalid_type", location: .property(field),
        message: "Context Fix failed for this field", entityType: mutation.entity.name)]))
    }
    guard let frame = context.contextFixFrame, frame.isActive(), owns(frame, mutation) else { throw invalid() }
    guard frame.allowed else { return }
    guard let property = frame.original.entity.property(named: field), field == (property.modelName ?? property.name),
      let declaration = frame.fields[field],
      (mutation.kind == .create ? declaration.create : declaration.update) == function else { throw invalid() }
    var result: TeaQLValue?
    // Do not retain a provider error, raw input or underlying-error cause.
    do {
      let input = ContextFixInput(entity: mutation.entity.name, field: field, function: function,
        arguments: arguments, operation: mutation.kind, now: now)
      let value: TeaQLValue
      if let resolver = context.contextFixResolver { value = try resolver.resolve(context: context, input: input) }
      else if function == "now" {
        let millis = now.timeIntervalSince1970 * 1_000
        guard millis.isFinite, millis >= Double(Int64.min), millis < Double(Int64.max) else { throw invalid() }
        value = .timestamp(Int64(millis))
      } else if function == "uniStr" {
        value = .string((arguments.first ?? "") + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
      } else { throw invalid() }
      if try valid(value, property: property) { result = value }
    } catch { result = nil }
    guard let result else { throw invalid() }
    mutation.values[field] = result
    context.recordFixEvidence(FixEvidence(entityType: mutation.entity.name, modelPath: field,
      source: function == "now" ? .clock : .context, sourceLabel: "contextFix:" + function))
  }

  private static func owns(_ frame: ContextFixFrame, _ mutation: Mutation) -> Bool {
    frame.original.entity == mutation.entity && frame.original.kind == mutation.kind
      && frame.original.id == mutation.id && frame.original.expectedVersion == mutation.expectedVersion
  }

  private static func valid(_ value: TeaQLValue, property: PropertyDescriptor) throws -> Bool {
    if value == .null { return property.nullable }
    switch (property.type, value) {
    case (.bool, .bool), (.string, .string), (.uint, .uint), (.data, .data): return true
    case (.int, .int(let number)): return !property.isInt32 || Int32(exactly: number) != nil
    case (.double, .double(let number)): return number.isFinite
    case (.decimal, .decimal(let number)): return !number.isNaN
    case (.timestamp, .timestamp): return true
    case (.timestamp, .date(let date)): return date.timeIntervalSince1970.isFinite
    case (.date, .date(let date)): return date.timeIntervalSince1970.isFinite
    case (.date, .calendarDate), (.localDateTime, .localDateTime): return value.dateValue != nil
    case (.json, _): _ = try JSONEncoder().encode(value); return true
    default: return false
    }
  }
}
