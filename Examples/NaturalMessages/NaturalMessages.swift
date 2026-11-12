import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ value: Bool, _ reason: String) throws { if !value { throw TeaQLError.execution(reason) } }
private func emit(_ marker: String, _ value: [String: Any]) throws {
  print(marker+String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self))
}
private final class Observer: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink, @unchecked Sendable {
  let service: SQLiteDataService; private let lock=NSLock(); private var calls=0,audits=0,writes=0
  init(_ service: SQLiteDataService) { self.service=service }
  private func call() { lock.withLock { calls += 1 } }
  func execute(_ request: QueryRequest) async throws -> QueryResult { call(); return try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { lock.withLock { calls += 1; writes += 1 }; return try await service.execute(request) }
  func beginGraphTransaction() async throws { call(); try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { call(); try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { call(); try await service.rollbackGraphTransaction() }
  func nextID(for entity: String, context: UserContext) async throws -> Int64 { call(); return try await service.nextID(for:entity,context:context) }
  func record(_ event: AuditEvent) { lock.withLock { audits += 1 } }
  var counts: (calls:Int,audits:Int,writes:Int) { lock.withLock { (calls,audits,writes) } }
  func reset() { lock.withLock { calls=0; audits=0; writes=0 } }
}
private struct Resolver: ContextFixResolver {
  func resolve(context: UserContext, input: ContextFixInput) throws -> TeaQLValue {
    input.function == "now" ? .timestamp(Int64(input.now.timeIntervalSince1970*1000)) : .string(input.function == "uniStr" ? "seed-A" : input.function+"-A")
  }
}
private struct AppChecker: EntityChecker {
  let generated: any EntityChecker
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if mutation.kind == .create {
      try ContextFix.apply(context,mutation:&mutation,now:now,field:"source_ip",function:"ip")
      try ContextFix.apply(context,mutation:&mutation,now:now,field:"opened_by",function:"actor")
    }
    try ContextFix.apply(context,mutation:&mutation,now:now,field:"last_ip",function:"ip")
    try ContextFix.apply(context,mutation:&mutation,now:now,field:"changed_by",function:"actor")
    return try generated.checkAndFix(context:context,mutation:&mutation,now:now)
  }
}
@main enum NaturalMessages {
  @MainActor static func main() async throws {
    let service=try SQLiteDataService(path:ProcessInfo.processInfo.environment["TEAQL_NATURAL_MESSAGES_DB"] ?? ":memory:")
    let observer=Observer(service),module=GeneratedRuntimeModule.module
    let presentation=try CheckerPresentationModel(data:Data("""
      {"schema":"teaql.checker-model/v1","revision":"natural-sqlite-v1","entities":{
        "Catalog":{"labels":{"en":"catalog","zh-CN":"目录"},"fields":[
          {"name":"name","labels":{"en":"name","zh-CN":"名称"}},
          {"name":"entry_list","targetType":"Entry","labels":{"en":"entry","zh-CN":"明细"},"classifiers":{"zh-CN":"条"},"aliases":["entryList"]}]},
        "Entry":{"labels":{"en":"entry","zh-CN":"明细"},"fields":[
          {"name":"name","labels":{"en":"name","zh-CN":"名称"}},
          {"name":"guarded_token","labels":{"en":"private token","zh-CN":"私密标记"}}]}}}
      """.utf8))
    var runtime=TeaQLRuntime(); try runtime.install(module)
    try runtime.install(RuntimeModule(name:"Application natural messages",entities:[],
      checkers:["Entry":AppChecker(generated:runtime.checker(named:"Entry")!)],
      contextFixFields:["Entry":["source_ip":.init(create:"ip"),"last_ip":.init(create:"ip",update:"ip"),
        "opened_by":.init(create:"actor"),"changed_by":.init(create:"actor",update:"actor")]],checkerPresentation:presentation))
    func context(schema: Bool=false) -> UserContext {
      UserContext(runtime:runtime,actor:"Natural example",queryExecutor:schema ? service : observer,
        mutationExecutor:schema ? service : observer,requestPolicy:RequestPolicy { $0 },auditSink:observer,
        querySQLLogEnabled:false,mutationSQLLogEnabled:false,businessClock:FixedBusinessClock(Date(timeIntervalSince1970:1700000000)),contextFixResolver:Resolver())
    }
    var ctx=context(); try await context(schema:true).ensureSchema(module)
    let suffix=String(UUID().uuidString.prefix(8))
    func child(_ name:String) throws -> Entry {
      var value=try Q.entries().comment("Prepare a natural-message child").purpose("Verify generated Checker behavior").newEntity(ctx)
      value.updateName(name); return value
    }
    var parent=try Q.catalogs().comment("Prepare a natural-message graph").purpose("Verify graph origin and masking").newEntity(ctx)
    parent.updateName("graph-"+suffix); parent.entryList=SmartList([try child("first-"+suffix),try child("second-"+suffix)])
    parent=try await parent.auditAs("Create the natural-message graph").save(ctx)
    func load(_ id:Int64) async throws -> Catalog {
      let rows=try await Q.catalogs().withIdIs(id).selectEntryListWith(Q.entries().orderByIdAscending().limit(10)).limit(1)
        .comment("Load the complete natural-message graph").purpose("Use Q and E to verify persisted values").executeForList(ctx)
      try require(rows.count == 1,"Expected one graph"); return rows[0]
    }
    parent=try await load(parent.id); let first=parent.entryList[0]; var second=parent.entryList[1]
    try require(try E.entry(first).name().eval() == "first-"+suffix && E.entry(second).name().eval() == "second-"+suffix,"Q/E hydration")
    let parentVersion=parent.version,firstVersion=first.version,secondVersion=second.version
    let secret=String(repeating:"e\u{301}",count:101)
    try require(secret.count == 101 && secret.unicodeScalars.count == 202,"Distinct measurement units")
    second.updateGuardedToken(secret); parent.entryList=SmartList([first,second]); observer.reset()
    var failure:CheckException?
    do { _=try await parent.auditAs("Reject the second child's private value").save(ctx) } catch let error as CheckException { failure=error }
    guard let failure else { throw TeaQLError.execution("Expected a located length error") }
    try require(failure.violations.count == 1,"Expected one generated length error")
    let violation=failure.violations[0]
    let english="The private token of the 2nd entry must not exceed 100 grapheme clusters; its current length is 101."
    try require(violation.message == english,"Generated grapheme count and graph role")
    try require(violation.entityType == "Entry" && violation.location.modelPath == "entry_list[1].guarded_token"
      && violation.location.instancePath == "/entryList/1/guardedToken","Declaring type and stable paths")
    try require(observer.counts.calls == 0 && observer.counts.audits == 0,"Rejection precedes providers and audits")
    try require(!failure.description.contains(secret),"No secret in native exception")
    print("SWIFT_NATURAL_EN="+String(decoding:try JSONEncoder().encode(violation.wire()),as:UTF8.self))
    try ctx.setLocaleCode("zh-CN")
    let translated=ctx.translateCheckResults(failure.violations)[0]
    try require(translated.message == "第2条明细的私密标记最多允许100个字素簇，当前长度为101。","Chinese message preserves the measurement")
    print("SWIFT_NATURAL_ZH="+String(decoding:try JSONEncoder().encode(translated.wire()),as:UTF8.self))
    try ctx.setLocaleCode("en"); second.updateGuardedToken("safe-B"); parent.entryList=SmartList([first,second]); observer.reset()
    parent=try await parent.auditAs("Save the corrected second child only").save(ctx)
    try require(observer.counts.writes == 1 && observer.counts.audits == 1,"Only the modified child writes/audits")
    let loaded=try await load(parent.id)
    try require(loaded.version == parentVersion && loaded.entryList[0].version == firstVersion
      && loaded.entryList[1].version == secondVersion+1,"Only modified version advances")
    try require(try E.entry(loaded.entryList[1]).guardedToken().eval() == "safe-B","Corrected value persisted")
    try emit("SWIFT_NATURAL_SQLITE=",["passed":true,"typedQ":true,"typedE":true,"unchangedParent":true,
      "failedCheckProviderCalls":0,"correctedWrites":1,"correctedAudits":1,"originalLength":101,"unicodeScalars":202,
      "parentId":parent.id,"firstId":first.id,"secondId":second.id,"parentVersion":parentVersion,
      "firstVersion":firstVersion,"secondVersion":loaded.entryList[1].version])
  }
}
