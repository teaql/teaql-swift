import Foundation
import XCTest
import TeaQLCore
import TeaQLSQLite

private actor RequestTreeDiagnostic: DiagnosticSQLLogSink {
  var entries: [SQLExecutionMetadata] = []
  func write(_ entry: SQLExecutionMetadata) { entries.append(entry) }
  func snapshot() -> [SQLExecutionMetadata] { entries }
  func clear() { entries.removeAll() }
}

final class QueryRequestTreeSQLiteTests: XCTestCase {
  func testIdSetCollectionOwnsHelperAndCacheHitsDoNotInventSQL() async throws {
    for logging in [true, false] {
      let school = EntityDescriptor(name: "School", table: "id_tree_schools", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true),
        PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "name", type: .string)])
      let service = try SQLiteDataService(path: ":memory:")
      let seed = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        querySQLLogEnabled: false, mutationSQLLogEnabled: false)
      try await seed.ensureSchema(RuntimeModule(name: "helper test", entities: [school]))
      for id in 1...3 {
        _ = try await seed.execute(Mutation(kind: .create, entity: school,
          values: ["id": .int(Int64(id)), "name": .string("School \(id)")], auditReason: "seed helper test"))
      }
      let diagnostic = RequestTreeDiagnostic(), evidence = SQLExecutionEvidenceStore()
      let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        telemetrySink: evidence, diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging,
        idSetStore: InMemoryIdSetStore())
      var aggregate = SelectQuery(entity: school)
      aggregate.aggregates = [QueryAggregate(.count, field: "id", alias: "schoolCount"), QueryAggregate(.sum, field: "id", alias: "idTotal")]
      aggregate.comment = "calculate school totals"; aggregate.purpose = "render totals"
      let totals = try await context.execute(aggregate)
      XCTAssertEqual(totals.records.count, 1)
      XCTAssertEqual(totals.records.first?["schoolCount"], .int(3)); XCTAssertEqual(totals.records.first?["idTotal"], .int(6))
      let aggregateFacts = await evidence.snapshot(), aggregateLogs = await diagnostic.snapshot()
      XCTAssertEqual(aggregateFacts.count, 1); XCTAssertEqual(aggregateLogs.count, logging ? 1 : 0)
      XCTAssertTrue(aggregateFacts[0].parameterizedSQL.uppercased().contains("COUNT("))
      XCTAssertTrue(aggregateFacts[0].parameterizedSQL.uppercased().contains("SUM("))
      XCTAssertEqual(aggregateFacts[0].traceChain.map(\.comment), ["render totals", "calculate school totals"])
      print("RTC_COM_07_AGGREGATE_PASS logging=\(logging) expressions=2 statements=1")
      await evidence.enableAll(); await diagnostic.clear()
      func page(_ offset: Int) -> SelectQuery {
        var query = SelectQuery(entity: school)
        query.comment = "load school page"; query.purpose = "render school page"
        query.projection = ["id", "name"]; query.orderBy = [OrderBy("id", .descending)]
        query.offset = offset; query.limit = 1
        query.idSetPagination = IdSetPaginationOptions(namespace: "request-tree-schools", ttlSeconds: 60, maxIds: 10)
        return query
      }
      let first = try await context.executePage(page(1), offset: 1, limit: 1)
      XCTAssertEqual(first.items.first?["id"], .int(2)); XCTAssertEqual(first.total, 3)
      let firstFacts = await evidence.snapshot(), firstLogs = await diagnostic.snapshot()
      XCTAssertEqual(firstFacts.count, 2); XCTAssertEqual(firstLogs.count, logging ? 2 : 0)
      if firstFacts.count == 2 {
        XCTAssertEqual(firstFacts[0].traceChain.map(\.comment),
          ["render school page", "load school page", "collect School IDs for pagination"])
        XCTAssertEqual(firstFacts[1].traceChain.map(\.comment), ["render school page", "load school page"])
      }
      await evidence.enableAll(); await diagnostic.clear()
      let second = try await context.executePage(page(0), offset: 0, limit: 1)
      XCTAssertEqual(second.items.first?["id"], .int(3)); XCTAssertEqual(second.total, 3)
      let facts = await evidence.snapshot(), logs = await diagnostic.snapshot()
      XCTAssertEqual(facts.count, 1); XCTAssertEqual(logs.count, logging ? 1 : 0)
      XCTAssertEqual(facts.first?.traceChain.map(\.comment), ["render school page", "load school page"])
      let observation = await context.idSetPaginationObservation()
      XCTAssertEqual(observation.plan, "ID_SET_HIT"); XCTAssertEqual(observation.count, 3)
      XCTAssertFalse(facts[0].parameterizedSQL.uppercased().contains("COUNT("))
      print("RTC_COM_07_CACHE_PASS logging=\(logging) accuracy=EXACT hit_statements=1")
    }
  }

  func testPrefixesAndEscapedFacetAliasesPreserveBindingsUnderPrivacyProjection() async throws {
    for logging in [false, true] {
      let type = EntityDescriptor(name: "SchoolType", table: "prefix_types", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true)])
      let school = EntityDescriptor(name: "School", table: "prefix_schools", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "schoolType", type: .int), PropertyDescriptor(name: "name", type: .string)], auditMaskFields: ["name"])
      let service = try SQLiteDataService(path: ":memory:")
      let seed = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        querySQLLogEnabled: false, mutationSQLLogEnabled: false)
      try await seed.ensureSchema(RuntimeModule(name: "privacy test", entities: [school,type]))
      let secret = "TRACE-PRIVATE-CANARY"
      for (entity,values) in [(type,["id":TeaQLValue.int(1001)]),
        (school,["id":.int(1),"name":.string(secret),"schoolType":.int(1001)]),
        (school,["id":.int(2),"name":.string("Other school"),"schoolType":.int(1001)])] {
        _ = try await seed.execute(Mutation(kind: .create, entity: entity, values: values, auditReason: "seed privacy fixture"))
      }
      let diagnostic = RequestTreeDiagnostic(), evidence = SQLExecutionEvidenceStore()
      let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        telemetrySink: evidence, diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging)
      for privateInput in [false, true] {
        await evidence.enableAll(); await diagnostic.clear()
        let alias = "choices\"\\\n" + (privateInput ? secret : "")
        let nativeComment = "facetBySchoolTypeAs(\"choices\\\"\\\\\\n" + (privateInput ? secret : "") + "\")"
        let comment = privateInput ? "what: load \(secret)" : "what: load schools"
        let purpose = privateInput ? "why: inspect \(secret)" : "why: inspect schools"
        var child = SelectQuery(entity: type); child.limit = 10
        child.comment = privateInput ? "load \(secret) facets" : "load type facets"
        child.aggregates = [QueryAggregate(.count, field: "id", alias: "schoolCount")]
        var query = SelectQuery(entity: school); query.limit = 10
        query.comment = comment; query.purpose = purpose
        if privateInput { query.filter = .equal("name", .string(secret)) }
        let operation = QueryOperation("facet", method: "facetBySchoolTypeAs", alias: alias, relation: "schoolType")
        XCTAssertEqual(operation.comment, nativeComment)
        query.facets = [FacetRequest(name: alias, relationName: "schoolType", query: child, includeAllFacets: false, operation: operation)]
        let original = query
        let result = try await context.execute(query)
        XCTAssertEqual(result.records.count, privateInput ? 1 : 2)
        XCTAssertEqual(result.facets[alias]?.first?["schoolCount"], .int(privateInput ? 1 : 2))
        if privateInput { XCTAssertEqual(result.records.first?["name"], .string(secret)) }
        XCTAssertEqual(query, original); XCTAssertEqual(query.comment, comment); XCTAssertEqual(query.purpose, purpose)
        let facts = await evidence.snapshot(), logs = await diagnostic.snapshot()
        XCTAssertEqual(facts.count, 3); XCTAssertEqual(logs.count, logging ? 3 : 0)
        let safeComment = privateInput ? "what: load [REDACTED]" : comment
        let safePurpose = privateInput ? "why: inspect [REDACTED]" : purpose
        let chains = facts.map { $0.traceChain.map(\.comment) }
        XCTAssertTrue(chains.contains([safePurpose,safeComment]))
        for local in ["aggregate schoolType", privateInput ? "load [REDACTED] facets" : "load type facets"] {
          XCTAssertTrue(chains.contains([safePurpose,safeComment,nativeComment.replacingOccurrences(of: secret, with: "[REDACTED]"),local]))
        }
        if privateInput { XCTAssertFalse(facts.description.contains(secret)) }
      }
      print("RTC_COM_09_12_PASS logging=\(logging) plain=true private=true escaped=true bindings=true")
    }
  }

  func testNativePageFacetAndLocalCommentsWithLoggingOnAndOff() async throws {
    for logging in [true, false] {
      let type = EntityDescriptor(name: "SchoolType", table: "rt_types", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "name", type: .string)])
      let school = EntityDescriptor(name: "School", table: "rt_schools", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
        PropertyDescriptor(name: "schoolType", type: .int), PropertyDescriptor(name: "name", type: .string),
        PropertyDescriptor(name: "capacity", type: .int)])
      let service = try SQLiteDataService(path: ":memory:")
      let seed = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        querySQLLogEnabled: false, mutationSQLLogEnabled: false)
      try await seed.ensureSchema(RuntimeModule(name: "request tree", entities: [school, type]))
      for (entity, values) in [(type,["id":TeaQLValue.int(1001),"name":.string("Primary")]),
        (type,["id":.int(1002),"name":.string("Secondary")]),
        (school,["id":.int(1),"name":.string("KEEP A"),"schoolType":.int(1001),"capacity":.int(20)]),
        (school,["id":.int(2),"name":.string("KEEP B"),"schoolType":.int(1001),"capacity":.int(30)]),
        (school,["id":.int(3),"name":.string("DROP C"),"schoolType":.int(1001),"capacity":.int(900)])] {
        _ = try await seed.execute(Mutation(kind: .create, entity: entity, values: values, auditReason: "seed test"))
      }
      let diagnostic = RequestTreeDiagnostic(), store = SQLExecutionEvidenceStore()
      let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
        telemetrySink: store, diagnosticSQLLogSink: diagnostic, querySQLLogEnabled: logging)
      // SQL aliases are identifiers in Swift; rendering arbitrary caller text
      // is a separate header contract, not permission to bypass that check.
      XCTAssertEqual(QueryOperation("count", method: "countAs", alias: "a\"\\\n").comment,
        "countAs(\"a\\\"\\\\\\n\")")
      for alias in [nil, "totalSchools"] as [String?] {
        await store.enableAll(); await diagnostic.clear()
        var countQuery = SelectQuery(entity: school)
        countQuery.comment = "load schools"; countQuery.purpose = "render school page"
        if let alias { countQuery.pageCountOperation = QueryOperation("count", method: "countAs", alias: alias) }
        let page = try await context.executePage(countQuery, offset: 0, limit: 1)
        XCTAssertEqual(page.total, 3); XCTAssertEqual(page.items.count, 1)
        if let alias { XCTAssertEqual(page.items.aggregations[alias], .int(3)) }
        else { XCTAssertTrue(page.items.aggregations.isEmpty) }
        let facts = await store.snapshot(), logs = await diagnostic.snapshot()
        XCTAssertEqual(facts.count, 2); XCTAssertEqual(logs.count, logging ? 2 : 0)
        let local = alias == nil ? "count matching rows" : "countAs(\"totalSchools\")"
        let count = try XCTUnwrap(facts.first { $0.traceChain.last?.comment == local })
        XCTAssertEqual(count.traceChain.map(\.comment), ["render school page", "load schools", local])
        XCTAssertFalse(count.tracePath.contains { $0.kind == "relation" })
        XCTAssertEqual(countQuery.comment, "load schools")
      }
      print("RTC_COM_05_PASS logging=\(logging) named=true unnamed=true")
      await store.enableAll(); await diagnostic.clear()
      let defaultTarget = SelectQuery(entity: type)
      var defaultQuery = SelectQuery(entity: school)
      defaultQuery.comment = "load schools"; defaultQuery.purpose = "render schools"
      defaultQuery.relationQuery("schoolTypeEntity", localKey: "schoolType", foreignKey: "id", many: false,
        query: defaultTarget, operation: QueryOperation("relation", method: "selectSchoolTypeWith"))
      let defaultRows = try await context.execute(defaultQuery)
      XCTAssertEqual(defaultRows.records.count, 3)
      XCTAssertNotNil(defaultRows.records.first?["schoolTypeEntity"])
      let defaultFacts = await store.snapshot(), defaultLogs = await diagnostic.snapshot()
      XCTAssertEqual(defaultFacts.count, 2); XCTAssertEqual(defaultLogs.count, logging ? 2 : 0)
      XCTAssertTrue(defaultFacts.contains { $0.traceChain.map(\.comment) ==
        ["render schools", "load schools", "selectSchoolTypeWith(...)", "load SchoolType"] })
      XCTAssertNil(defaultTarget.comment)
      await store.enableAll(); await diagnostic.clear()
      for blank in ["", " \t", "\u{0085}"] {
        var invalidTarget = defaultTarget; invalidTarget.comment = blank
        var invalid = defaultQuery; invalid.relations = []
        invalid.relationQuery("schoolTypeEntity", localKey: "schoolType", foreignKey: "id", many: false,
          query: invalidTarget, operation: QueryOperation("relation", method: "selectSchoolTypeWith"))
        do { _ = try await context.execute(invalid); XCTFail("blank child comment was replaced by a default") }
        catch let error as RequestIntentError { XCTAssertEqual(error.field, "comment") }
        let facts = await store.snapshot(), logs = await diagnostic.snapshot()
        XCTAssertTrue(facts.isEmpty); XCTAssertTrue(logs.isEmpty)
        XCTAssertEqual(invalidTarget.comment, blank)
        print("RTC_COM_04_RELATION_PASS logging=\(logging) invalid_child_provider=0")
        var invalidFacet = defaultQuery; invalidFacet.relations = []
        invalidFacet.facets = [FacetRequest(name: "types", relationName: "schoolType", query: invalidTarget,
          operation: QueryOperation("facet", method: "facetBySchoolTypeAs", alias: "types", relation: "schoolType"))]
        do { _ = try await context.execute(invalidFacet); XCTFail("blank facet value comment was replaced by a default") }
        catch let error as RequestIntentError { XCTAssertEqual(error.field, "comment") }
        let facetFacts = await store.snapshot(), facetLogs = await diagnostic.snapshot()
        XCTAssertTrue(facetFacts.isEmpty); XCTAssertTrue(facetLogs.isEmpty)
        print("RTC_COM_04_FACET_PASS logging=\(logging) invalid_value_provider=0")
      }
      var sum = SelectQuery(entity: school)
      sum.aggregates = [QueryAggregate(.sum, field: "capacity", alias: "sumCapacity")]
      var facet = SelectQuery(entity: type); facet.comment = "load type facets"; facet.orderBy = [OrderBy("id", .ascending)]
      facet.aggregates = [QueryAggregate(.count, field: "id", alias: "schoolCount")]
      facet.relationAggregate("schools", foreignKey: "schoolType", alias: "sumCapacity", query: sum)
      var target = SelectQuery(entity: type); target.comment = "load selected type"
      var query = SelectQuery(entity: school); query.comment = "load schools"; query.purpose = "render schools"
      query.filter = .contains("name", "KEEP"); query.orderBy = [OrderBy("id", .descending)]
      query.aggregates = [QueryAggregate(.count, field: "id", alias: "totalSchools")]
      query.pageCountOperation = QueryOperation("count", method: "countAs", alias: "totalSchools")
      query.relationQuery("schoolTypeEntity", localKey: "schoolType", foreignKey: "id", many: false, query: target,
        operation: QueryOperation("relation", method: "selectSchoolTypeWith"))
      query.facets = [FacetRequest(name: "types", relationName: "schoolType", query: facet,
        operation: QueryOperation("facet", method: "facetBySchoolTypeAs", alias: "types", relation: "schoolType"))]
      let page = try await context.executePage(query, offset: 1, limit: 1)
      XCTAssertEqual(page.total, 2); XCTAssertEqual(page.items.aggregations["totalSchools"], .int(2))
      XCTAssertEqual(page.items.first?["name"], .string("KEEP A"))
      let types = try XCTUnwrap(page.items.facets["types"])
      XCTAssertEqual(types.map { $0["schoolCount"] }, [.int(2),.int(0)])
      XCTAssertEqual(types.first?["sumCapacity"]?.int64Value, 50)
      XCTAssertEqual(types.last?["sumCapacity"], .null)
      let entries = await store.snapshot(), logs = await diagnostic.snapshot()
      XCTAssertEqual(entries.count, 6); XCTAssertEqual(logs.count, logging ? 6 : 0)
      let chains = entries.map { $0.traceChain.map(\.comment) }
      XCTAssertTrue(chains.contains(["render schools","load schools","selectSchoolTypeWith(...)","load selected type"]))
      XCTAssertTrue(chains.contains(["render schools","load schools","facetBySchoolTypeAs(\"types\")","load type facets"]))
      XCTAssertEqual(chains.filter { $0.last == "aggregate schoolType" }.count, 2)
      XCTAssertTrue(chains.contains(["render schools","load schools","countAs(\"totalSchools\")"]))
      for entry in entries {
        XCTAssertEqual(entry.comment, entry.traceChain.last?.comment)
        XCTAssertEqual(entry.purpose, "render schools")
        XCTAssertTrue(entry.tracePath.contains { $0.kind == "provider" })
        XCTAssertFalse(entry.traceChain.contains { $0.kind == "provider" })
      }
      for comment in ["sum visible capacity", "", " \t", "\u{0085}"] {
        await store.enableAll(); await diagnostic.clear()
        var explicitSum = sum; explicitSum.comment = comment
        var explicitFacet = facet
        explicitFacet.relationAggregates = []
        explicitFacet.relationAggregate("schools", foreignKey: "schoolType", alias: "sumCapacity", query: explicitSum)
        var request = query
        request.facets = [FacetRequest(name: "types", relationName: "schoolType", query: explicitFacet,
          operation: QueryOperation("facet", method: "facetBySchoolTypeAs", alias: "types", relation: "schoolType"))]
        if comment == "sum visible capacity" {
          let page = try await context.executePage(request, offset: 1, limit: 1)
          XCTAssertEqual(page.items.facets["types"]?.first?["sumCapacity"]?.int64Value, 50)
          let facts = await store.snapshot(), logs = await diagnostic.snapshot()
          XCTAssertEqual(facts.count, 6); XCTAssertEqual(logs.count, logging ? 6 : 0)
          let fact = try XCTUnwrap(facts.first { $0.parameterizedSQL.contains("SUM(") })
          XCTAssertEqual(fact.traceChain.map(\.comment), ["render schools", "load schools",
            "facetBySchoolTypeAs(\"types\")", "aggregate schoolType", comment])
          XCTAssertEqual(fact.comment, comment)
        } else {
          do { _ = try await context.executePage(request, offset: 1, limit: 1); XCTFail("blank nested aggregate accepted") }
          catch let error as RequestIntentError { XCTAssertEqual(error.field, "comment") }
          let facts = await store.snapshot(), logs = await diagnostic.snapshot()
          XCTAssertTrue(facts.isEmpty); XCTAssertTrue(logs.isEmpty)
        }
      }
      print("RTC_COM_02_PASS logging=\(logging) explicit=both")
    }
  }
}
