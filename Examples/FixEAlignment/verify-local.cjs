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
  report.restorationApplicationSha256 = sha(fs.readFileSync(path.join(example, 'RestorationProbe.swift')));
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
    const file = path.join(evidence, log), fd = fs.openSync(file, 'w'); let result;
    try { result = await runner.run(command, {cwd: scratch, env, timeout, stdio: ['ignore', fd, fd]}); }
    finally { fs.closeSync(fd); }
    const bytes = fs.readFileSync(file);
    report.commands.push({command, exitCode: result.status, signal: result.signal, logSha256: sha(bytes)});
    if (result.status !== 0) process.exitCode = result.status || 1;
    assert.equal(result.status, 0, bytes.toString().slice(-12000)); return bytes.toString();
  }
  await run(['swift', 'build', ...flags, '--product', 'FixEAlignment'], 'build.log', 540000);
  if (fs.existsSync(path.join(scratch, 'Package.resolved'))) fs.copyFileSync(path.join(scratch, 'Package.resolved'), path.join(evidence, 'Package.resolved'));
  const bin = (await run(['swift', 'build', ...flags, '--show-bin-path'], 'bin-path.log')).trim();
  assert(bin.startsWith(build + path.sep), 'execute only the actual owned Swift build');
  const executable = path.join(bin, 'FixEAlignment'); report.binarySha256 = sha(fs.readFileSync(executable));
  for (const round of [1, 2]) {
    const log = await run([executable], 'round-' + round + '.log');
    for (const marker of ['FIX_E_EXAMPLE=', 'CORE_LOAD_EXAMPLE=', 'CORE_MUTATION_OWNERSHIP=', 'CORE_MUTATION_PAGING=', 'SWIFT_CHECKER_METADATA=', 'CORE_SWIFT_PARTIAL_ANCESTORS_RESULT=', 'CORE_SWIFT_RESTORATION_RESULT=']) {
      const values = log.split(/\r?\n/).filter(line => line.startsWith(marker)).map(line => JSON.parse(line.slice(marker.length)));
      assert.equal(values.length, 1, marker); assert.equal(values[0].passed, true, marker);
    }
    assert.deepEqual(fingerprint(), m);
  }
  report.databaseSha256 = sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite'))); report.passed = true;
  report.partialAncestorDatabase = {file: 'fixture.sqlite.partial-ancestors.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.partial-ancestors.sqlite')))};
  report.restorationDatabase = {file: 'fixture.sqlite.restoration.sqlite',
    sha256: sha(fs.readFileSync(path.join(evidence, 'fixture.sqlite.restoration.sqlite')))};
  console.log('PASS Swift retained Fix/E/loading/ownership example twice on one database');
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
