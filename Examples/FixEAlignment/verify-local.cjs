#!/usr/bin/env node
"use strict";
// Build only the existing Core/SQLite example targets, with local package wiring.
const fs = require('node:fs'), path = require('node:path'), os = require('node:os'), cp = require('node:child_process'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const example = __dirname, repo = path.resolve(example, '../..'), sha = b => crypto.createHash('sha256').update(b).digest('hex');
function fingerprint() {
  const m = JSON.parse(fs.readFileSync(path.join(example, 'fixture-manifest.json')));
  assert.equal(m.language, 'swift'); assert.equal(m.evaluationErrors, 0);
  assert.equal(sha(fs.readFileSync(path.join(example, 'model.xml'))), m.modelSha256);
  const actual = [];
  function visit(dir, prefix = '') { for (const e of fs.readdirSync(dir, {withFileTypes: true})) {
    const name = path.join(prefix, e.name), file = path.join(dir, e.name); assert(!e.isSymbolicLink());
    if (e.isDirectory()) visit(file, name); else { assert(e.isFile()); actual.push(name); }
  } }
  visit(path.join(example, 'generated')); assert.deepEqual(actual.sort(), Object.keys(m.files).sort());
  for (const [name, expected] of Object.entries(m.files)) assert.equal(sha(fs.readFileSync(path.join(example, 'generated', name))), expected, name);
  return m;
}
const requested = process.env.TEAQL_FIX_E_EVIDENCE_DIR;
const evidence = requested ? path.resolve(requested) : fs.mkdtempSync(path.join(os.tmpdir(), 'teaql-swift-fix-e-evidence-'));
if (requested) { assert(path.isAbsolute(requested) && !fs.existsSync(evidence)); fs.mkdirSync(evidence, {recursive: true}); }
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'teaql-swift-fix-e-build-'));
const report = {schema: 'teaql.swift-fix-e-example/v1', passed: false, commands: [], sameDatabase: true,
  localRuntime: repo, databaseRetained: true, sharedCacheRemoved: false};
const {createOwnedRunner, ownedBytes} = require('./owned-command.cjs'), runner = createOwnedRunner();
async function main() {
try {
  const disk = fs.statfsSync(scratch); assert(disk.bavail * disk.bsize > 8 * 1024 ** 3);
  const m = fingerprint(); report.modelSha256 = m.modelSha256;
  report.partialAncestorApplicationSha256 = sha(fs.readFileSync(path.join(example, 'PartialAncestorProbe.swift')));
  report.partialRootApplicationSha256 = sha(fs.readFileSync(path.join(example, 'PartialRootProbe.swift')));
  report.restorationApplicationSha256 = sha(fs.readFileSync(path.join(example, 'RestorationProbe.swift')));
  report.projectionApplicationSha256 = sha(fs.readFileSync(path.join(example, 'ProjectionViewsProbe.swift')));
  report.unchangedViewsApplicationSha256 = sha(fs.readFileSync(path.join(example, 'UnchangedViewsProbe.swift')));
  report.checkerBoundaryApplicationSha256 = sha(fs.readFileSync(path.join(example, 'CheckerBoundaryProbe.swift')));
  report.expressionBoundaryApplicationSha256 = sha(fs.readFileSync(path.join(example, 'ExpressionBoundaryProbe.swift')));
  report.graphLifecycleApplicationSha256 = sha(fs.readFileSync(path.join(example, 'GraphFixLifecycleProbe.swift')));
  fs.cpSync(path.join(example, 'generated'), path.join(scratch, 'generated'), {recursive: true});
  fs.mkdirSync(path.join(scratch, 'Sources/FixEAlignment'), {recursive: true});
  for (const file of fs.readdirSync(example).filter(file => file.endsWith('.swift'))) fs.copyFileSync(path.join(example, file), path.join(scratch, 'Sources/FixEAlignment', file));
  const manifest = `// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FixEAlignment", dependencies: [.package(name: "teaql-swift", path: ${JSON.stringify(repo)})], targets: [
  .target(name: "GeneratedTeaQL", dependencies: [.product(name: "TeaQLCore", package: "teaql-swift")], path: "generated/Sources/GeneratedTeaQL"),
  .executableTarget(name: "FixEAlignment", dependencies: ["GeneratedTeaQL", .product(name: "TeaQLCore", package: "teaql-swift"),
    .product(name: "TeaQLSQLite", package: "teaql-swift")], path: "Sources/FixEAlignment")
], swiftLanguageModes: [.v6])
`;
  fs.writeFileSync(path.join(scratch, 'Package.swift'), manifest); fs.writeFileSync(path.join(evidence, 'consumer-Package.swift'), manifest);
  const build = path.join(scratch, 'build'), flags = ['--package-path', scratch, '--scratch-path', build, '--jobs', '2'];
  const env = {...process.env, TEAQL_FIX_E_DB: path.join(evidence, 'fixture.sqlite')};
  async function run(command, log, timeout = 120000) {
    const file = path.join(evidence, log), stderrLog = log.replace(/\.log$/, '.stderr.log');
    const stderrFile = path.join(evidence, stderrLog), fd = fs.openSync(file, 'wx'), err = fs.openSync(stderrFile, 'wx'); let result;
    // Preserve warning diagnostics, but never splice stderr into buffered JSON frames.
    try { result = await runner.run(command, {cwd: scratch, env, timeout, stdio: ['ignore', fd, err]}); }
    finally { fs.closeSync(fd); fs.closeSync(err); }
    const bytes = fs.readFileSync(file), diagnostics = fs.readFileSync(stderrFile);
    report.commands.push({command, exitCode: result.status, signal: result.signal, logSha256: sha(bytes),
      stderrLog, stderrLogSha256: sha(diagnostics)});
    if (result.status !== 0) process.exitCode = result.status || 1;
    assert.equal(result.status, 0, bytes.toString().slice(-6000) + diagnostics.toString().slice(-6000)); return bytes.toString();
  }
  await run(['swift', 'build', ...flags, '--product', 'FixEAlignment'], 'build.log', 540000);
  if (fs.existsSync(path.join(scratch, 'Package.resolved'))) fs.copyFileSync(path.join(scratch, 'Package.resolved'), path.join(evidence, 'Package.resolved'));
  const bin = (await run(['swift', 'build', ...flags, '--show-bin-path'], 'bin-path.log')).trim();
  assert(bin.startsWith(build + path.sep), 'execute only the actual owned Swift build');
  const executable = path.join(bin, 'FixEAlignment'); report.binarySha256 = sha(fs.readFileSync(executable));
  for (const round of [1, 2]) {
    env.TEAQL_FIX_E_ROUND = String(round);
    const log = await run([executable], 'round-' + round + '.log');
    for (const marker of ['FIX_E_EXAMPLE=', 'CORE_LOAD_EXAMPLE=', 'CORE_MUTATION_OWNERSHIP=', 'CORE_MUTATION_PAGING=', 'SWIFT_CHECKER_METADATA=', 'CORE_SWIFT_PARTIAL_ANCESTORS_RESULT=', 'CORE_SWIFT_PARTIAL_ROOT_RESULT=', 'CORE_SWIFT_RESTORATION_RESULT=']) {
      const values = log.split(/\r?\n/).filter(line => line.startsWith(marker)).map(line => JSON.parse(line.slice(marker.length)));
      assert.equal(values.length, 1, marker); assert.equal(values[0].passed, true, marker);
    }
    assert.deepEqual(fingerprint(), m);
    const projections=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_PROJECTION_VIEW_CASE=')).map(line=>JSON.parse(line.slice('SWIFT_PROJECTION_VIEW_CASE='.length)));
    assert.equal(projections.length,3);assert(projections.every(value=>value.round===round&&value.passed));
    const jsonViews=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_PROJECTION_JSON_ROUNDTRIP=')).map(line=>JSON.parse(line.slice('SWIFT_PROJECTION_JSON_ROUNDTRIP='.length)));
    assert.equal(jsonViews.length,1);assert.equal(jsonViews[0].round,round);assert.equal(jsonViews[0].implicitProviderCalls,0);
    const unchanged=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_UNCHANGED_VIEW_CASE='))
      .map(line=>JSON.parse(line.slice('SWIFT_UNCHANGED_VIEW_CASE='.length)));
    assert.deepEqual(unchanged.map(value=>value.scenario).sort(),[
      'sparse-null-forward','complete-independent-other','empty-reverse','rollback-after-write','rollback-before-commit',
    ].sort());assert(unchanged.every(value=>value.round===round&&value.passed));
    const checkerCases=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_CHECKER_BOUNDARY_CASE='))
      .map(line=>JSON.parse(line.slice('SWIFT_CHECKER_BOUNDARY_CASE='.length)));
    assert.equal(checkerCases.length,33);assert(checkerCases.every(value=>value.round===round&&value.passed));
    const checkerSummary=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_CHECKER_BOUNDARY_RESULT='))
      .map(line=>JSON.parse(line.slice('SWIFT_CHECKER_BOUNDARY_RESULT='.length)));
    assert.equal(checkerSummary.length,1);assert.equal(checkerSummary[0].passed,true);
    assert.equal(checkerSummary[0].round,round);assert.equal(checkerSummary[0].observations,33);
    const expressionCases=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_E_BOUNDARY_CASE='))
      .map(line=>JSON.parse(line.slice('SWIFT_E_BOUNDARY_CASE='.length)));
    const expressionNames=['late-leaf','indexed-leaf','first-indexed-leaf','loaded-null','loaded-empty','out-of-range',
      'missing-list-size','terminals','sibling-paths','fk-only-not-loaded','repeated-relation','no-side-effects'];
    assert.deepEqual(expressionCases.map(v=>v.name),expressionNames);
    assert(expressionCases.every(v=>v.passed&&v.round===round));
    const expressionResults=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_E_BOUNDARY_RESULT='))
      .map(line=>JSON.parse(line.slice('SWIFT_E_BOUNDARY_RESULT='.length)));
    assert.equal(expressionResults.length,1);assert(expressionResults[0].passed&&expressionResults[0].round===round);
    assert.deepEqual(expressionResults[0].cases,expressionNames);assert.equal(expressionResults[0].terminalObservations,3);
    const graphCases=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_GRAPH_LIFECYCLE_CASE='))
      .map(line=>JSON.parse(line.slice('SWIFT_GRAPH_LIFECYCLE_CASE='.length)));
    assert.equal(graphCases.length,13);assert(graphCases.every(v=>v.passed&&v.round===round));
    const graphResult=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_GRAPH_LIFECYCLE_RESULT='))
      .map(line=>JSON.parse(line.slice('SWIFT_GRAPH_LIFECYCLE_RESULT='.length)));
    assert.deepEqual(graphResult,[{round,cases:13,passed:true}]);
  }
  report.databaseSha256 = sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite'))); report.passed = true;
  report.expressionBoundaryDatabase = {file: 'fixture.sqlite.expression-boundaries.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.expression-boundaries.sqlite')))};
  report.graphLifecycleDatabase = {file: 'fixture.sqlite.graph-lifecycle.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.graph-lifecycle.sqlite')))};
  report.partialAncestorDatabase = {file: 'fixture.sqlite.partial-ancestors.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.partial-ancestors.sqlite')))};
  report.partialRootDatabase = {file: 'fixture.sqlite.partial-root.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.partial-root.sqlite')))};
  report.restorationDatabase = {file: 'fixture.sqlite.restoration.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.restoration.sqlite')))};
  report.projectionDatabase = {file: 'fixture.sqlite.projection-views.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.projection-views.sqlite')))};
  report.unchangedViewDatabases = {};
  for(const name of ['sparse-null-forward','complete-independent-other','empty-reverse','rollback-after-write','rollback-before-commit']){
    const file='fixture.sqlite.unchanged-views.'+name+'.sqlite';report.unchangedViewDatabases[file]=sha(fs.readFileSync(path.join(evidence,file)));
  }
  console.log('PASS Swift retained Fix/E/loading/ownership example twice on one database');
  report.checkerBoundaryDatabases=['fixture.sqlite.checker-boundaries.sqlite','fixture.sqlite.checker-boundaries.sqlite.no-schema.sqlite',
    'fixture.sqlite.checker-boundaries.sqlite.bootstrap-denied.sqlite']
    .map(file=>({file,sha256:sha(fs.readFileSync(path.join(evidence,file)))}));
} catch (error) { console.error(error.stack); process.exitCode ||= 1; }
finally {
  report.disposedOwnedBytes = runner.safeToClean ? ownedBytes(scratch) : 0;
  if (runner.safeToClean) fs.rmSync(scratch, {recursive: true});
  else report.unsafeBuildRetention = {path: scratch, processGroup: runner.unsafeGroup};
  report.scratchRemoved = !fs.existsSync(scratch); runner.dispose();
  fs.writeFileSync(path.join(evidence, 'receipt.json'), JSON.stringify(report, null, 2) + '\n');
  console.log('Retained compact example evidence: ' + evidence);
}
}
main().catch(error => { console.error(error.stack); process.exitCode ||= 1; });
