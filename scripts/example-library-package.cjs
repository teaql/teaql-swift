'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const publishedRuntime = '.package(url: "https://github.com/teaql/teaql-swift.git", from: "0.6.0")';

function runtimeDependency(location) {
  return '.package(name: "teaql-swift", path: ' + JSON.stringify(location) + ')';
}

function replaceDependency(manifest, before, after) {
  assert.equal(manifest.split(before).length, 2, 'Expected one TeaQL runtime dependency');
  return manifest.replace(before, after);
}

function generatedLibraryFile(library, name, runtime) {
  const bytes = fs.readFileSync(path.join(library, name));
  if (name !== 'Package.swift') return bytes;
  return Buffer.from(replaceDependency(bytes.toString(), runtimeDependency(path.relative(library, runtime)), publishedRuntime));
}

function useRuntimeInLibraryCopy(library, copy, runtime) {
  const manifest = path.join(copy, 'Package.swift');
  const bytes = fs.readFileSync(manifest, 'utf8');
  fs.writeFileSync(manifest, replaceDependency(bytes, runtimeDependency(path.relative(library, runtime)), runtimeDependency(runtime)));
}

module.exports = {generatedLibraryFile, useRuntimeInLibraryCopy};
