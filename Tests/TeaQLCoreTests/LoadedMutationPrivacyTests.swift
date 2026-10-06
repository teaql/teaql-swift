import Foundation
import Testing
@testable import TeaQLCore

@Test
func loadedMutationPrivacyUsesModelPolicyAndNeverTrustsWireProvenance() throws {
  let entity = EntityDescriptor(name: "Payment", table: "payment_data", properties: [
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "referenceCode", modelName: "reference_code", column: "legacy_reference", type: .string),
    PropertyDescriptor(name: "apiKey", modelName: "api_key", type: .string),
  ], auditMaskFields: ["reference_code"])
  var mutation = Mutation(kind: .update, entity: entity, id: .int(99),
    values: ["reference_code": .string("new value")], auditReason: "page 1 PRIVATEOLD credential-old")
  mutation.loadedValues = ["version": .int(1), "referenceCode": .string("PRIVATEOLD"), "apiKey": .string("credential-old")]
  let source = LogPrivacy.loadedMutationSource(mutation)
  #expect(source.parameterLogPolicies == [.plain, .masked, .credential])
  #expect(LogPrivacy.privateValues(source) == [.string("PRIVATEOLD"), .string("credential-old")])
  let metadata = SQLExecutionMetadata(operation: .update, auditReason: mutation.auditReason,
    parameterizedSQL: "UPDATE payment_data SET reference_code = ?", parameters: [.string("new value")],
    debugSQL: "", elapsedMicros: 0, resultSummary: "", parameterLogPolicies: [.masked], generatedSQL: true)
  let safe = LogPrivacy.project(metadata, intentSource: source)
  #expect(safe.auditReason == "page 1 [REDACTED] [REDACTED]")
  let debug = LogPrivacy.project(metadata, allowPlaintext: true, intentSource: source)
  #expect(debug.auditReason == "page 1 PRIVATEOLD [REDACTED]")
  #expect(LogPrivacy.project(debug).auditReason == safe.auditReason)
  var wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as! [String: Any]
  #expect(wire["loadedValues"] == nil)
  wire["loadedValues"] = ["referenceCode": "forged"]
  let decoded = try JSONDecoder().decode(Mutation.self, from: JSONSerialization.data(withJSONObject: wire))
  #expect(decoded.loadedValues.isEmpty)
  #expect(decoded.values == mutation.values)
}
