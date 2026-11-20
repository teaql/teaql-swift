#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
app="$example/swift-app-console"
if [[ -n "${TEAQL_SCHOOL_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_SCHOOL_EVIDENCE_DIR"
  mkdir "$evidence"
else
  evidence="$(mktemp -d -t teaql-swift-school-evidence.XXXXXXXX)"
fi
owned_build=''
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$owned_build" ]]; then rm -rf -- "$owned_build"; fi
  exit "$status"
}
trap cleanup EXIT
if [[ -z "${TEAQL_SWIFT_SCRATCH_PATH:-}" ]]; then
  owned_build="$(mktemp -d -t teaql-swift-school-build.XXXXXXXX)"
  export TEAQL_SWIFT_SCRATCH_PATH="$owned_build"
fi
options=(--package-path "$app" --scratch-path "$TEAQL_SWIFT_SCRATCH_PATH"
  --disable-build-manifest-caching --force-resolved-versions)
fingerprint() {
  (cd "$example" && find swift-lib-core swift-app-console -type f \
    ! -path '*/.build/*' -print0 | sort -z | xargs -0 sha256sum)
}
fingerprint > "$evidence/source-before.sha256"
swift package "${options[@]}" show-dependencies --format json > "$evidence/dependencies.log" 2>&1
TEAQL_SCHOOL_MANAGEMENT_DB="$evidence/showcase.sqlite" \
  swift run --jobs 2 "${options[@]}" TeaQLConsole > "$evidence/application.log" 2>&1
sha256sum "$evidence/showcase.sqlite" > "$evidence/database-before-rejection.sha256"
set +e
TEAQL_SCHOOL_MANAGEMENT_DB="$evidence/showcase.sqlite" \
  swift run --skip-build "${options[@]}" TeaQLConsole > "$evidence/existing-database-rejected.log" 2>&1
rejected=$?
set -e
[[ "$rejected" != 0 ]]
rg -Fq 'existing data is preserved' "$evidence/existing-database-rejected.log"
sha256sum "$evidence/showcase.sqlite" > "$evidence/database-after-rejection.sha256"
cmp "$evidence/database-before-rejection.sha256" "$evidence/database-after-rejection.sha256"
fingerprint > "$evidence/source-after.sha256"
cmp "$evidence/source-before.sha256" "$evidence/source-after.sha256"
python3 -B - "$evidence" "$repo" <<'PY'
import hashlib, json, pathlib, sqlite3, sys
root, runtime = map(pathlib.Path, sys.argv[1:])
# Swift may emit a deprecation warning before its valid JSON document.
text = (root / 'dependencies.log').read_text()
start = text.find('{')
assert start >= 0, text[-1000:]
dependencies, _ = json.JSONDecoder().raw_decode(text[start:])
direct = dependencies['dependencies']
local, = [node for node in direct if node.get('path') and pathlib.Path(node['path']).resolve() == runtime]
domain, = [node for node in direct if node.get('path') and
    pathlib.Path(node['path']).resolve() == runtime / 'Examples/SchoolManagement/swift-lib-core']
assert any(node['identity'] == local['identity'] and pathlib.Path(node['path']).resolve() == runtime
    for node in domain['dependencies'])
log = (root / 'application.log').read_text()
for expected in ['PASS Mutation ledger identity', 'PASS generated bootstrap SQL intent, committed lineage and no-op reseeding',
    'PASS required Query and Mutation comments, including logging disabled',
    'PASS Swift School bootstrap, portable Query parity, and constant relation graph']:
    assert expected in log, expected
results = [json.loads(line.removeprefix('SHOWCASE_RESULT ')) for line in log.splitlines() if line.startswith('SHOWCASE_RESULT ')]
assert results == [dict(roots=1, types=2, schools=1, restartAudits=1, repeatWrites=0)], results
database = root / 'showcase.sqlite'
with sqlite3.connect(database.resolve().as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
    rows = connection.execute('SELECT name,version,student_capacity FROM school_data').fetchall()
    assert rows == [('Riverside Primary School', 1, 800)], rows
    types = connection.execute('SELECT id,version FROM school_type_data ORDER BY id').fetchall()
    assert types == [(1001, 3), (1002, 1)], types
    assert connection.execute('PRAGMA quick_check').fetchone() == ('ok',)
receipt = dict(schema='teaql.swift-school-business/v1', passed=True,
    originalApplicationAssertionsPassed=True, localRuntime=local, domainLibraryPath=domain['path'],
    dependencyWarningPrefixBytes=len(text[:start].encode()), sameDatabaseContextRestart=True,
    restartAudits=1, repeatWrites=0, preexistingDatabaseRejectedWithoutModification=True,
    generatedScopesUnchanged=True, sqliteRows=rows, schoolTypeVersions=types,
    databaseSHA256=hashlib.sha256(database.read_bytes()).hexdigest())
(root / 'business-receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
print(json.dumps(dict(passed=True, sameDatabaseContextRestart=True, repeatWrites=0)))
PY
