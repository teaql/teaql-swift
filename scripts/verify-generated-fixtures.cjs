#!/usr/bin/env node
"use strict";
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const repo = path.resolve(__dirname, '..'), sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const roots = ['Examples/Conformance', 'Examples/SchoolManagement', 'Examples/FacetTrace/Generated',
  'Examples/TraceChain/Generated', 'Examples/TraceChain/standard-order/lib'];
let files = 0;
for (const relative of roots) {
  const root = path.join(repo, relative), manifest = JSON.parse(fs.readFileSync(path.join(root, 'fixture-manifest.json')));
  assert.equal(manifest.schema, 'teaql.retained-example-fixture/v1');
  assert.equal(manifest.evaluatedScope, 'swift-lib-core'); assert.equal(manifest.evaluationErrors, 0);
  assert.equal(manifest.applicationManifestsPreserved, true);
  const model = path.resolve(repo, manifest.modelSource); assert(model.startsWith(repo + path.sep));
  assert.equal(sha(fs.readFileSync(model)), manifest.modelSha256, 'model changed: ' + relative);
  const generated = Object.entries(manifest.files); assert(generated.length > 0);
  for (const [file, expected] of generated) {
    assert(file.startsWith('Sources/GeneratedTeaQL/') && !file.split(/[\\/]/).includes('..'));
    const source = path.join(root, file);
    assert(fs.lstatSync(source).isFile() && !fs.lstatSync(source).isSymbolicLink());
    assert.equal(sha(fs.readFileSync(source)), expected, 'generated library changed: ' + relative + '/' + file);
    files++;
  }
}
console.log('PASS Swift retained validated generation: ' + roots.length + ' libraries, ' + files + ' byte-exact sources and original model hashes');
