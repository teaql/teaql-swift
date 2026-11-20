#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
if [[ -n "${TEAQL_CONFORMANCE_EVIDENCE_DIR:-}" ]]; then
 evidence="$TEAQL_CONFORMANCE_EVIDENCE_DIR"
 mkdir "$evidence"
else
 evidence="$(mktemp -d -t teaql-work-item-evidence.XXXXXXXX)"
fi
unset TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS
app="$example/swift-app-console"
owned_scratch=''
cleanup() {
 status=$?
 trap - EXIT
 if [[ -n "$owned_scratch" ]]; then rm -rf -- "$owned_scratch"; fi
 exit "$status"
}
trap cleanup EXIT
if [[ -z "${TEAQL_SWIFT_SCRATCH_PATH:-}" ]]; then
 owned_scratch="$(mktemp -d -t teaql-swift-work-item-build.XXXXXXXX)"
 export TEAQL_SWIFT_SCRATCH_PATH="$owned_scratch"
fi
options=(--package-path "$app" --scratch-path "$TEAQL_SWIFT_SCRATCH_PATH" --disable-build-manifest-caching --force-resolved-versions)
fingerprint() {
 (cd "$example" && find swift-lib-core swift-app-console -type f ! -path '*/.build/*' -print0 | sort -z | xargs -0 sha256sum)
}
fingerprint > "$evidence/source-before.sha256"
python3 -B - "$example" <<'CHECK' > "$evidence/generated-domain-origins.json"
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);library=root/'swift-lib-core/Sources/GeneratedTeaQL';workspace=root/'swift-app-console/Sources/GeneratedTeaQL'
files={str(p.relative_to(library)):hashlib.sha256(p.read_bytes()).hexdigest() for p in library.rglob('*.swift')}
assert set(files)=={str(p.relative_to(workspace)) for p in workspace.rglob('*.swift')}
for name,digest in files.items():assert hashlib.sha256((workspace/name).read_bytes()).hexdigest()==digest,name
print(json.dumps(dict(passed=True,domainFiles=files,siblingLibraryImplementationByteExact=True),indent=2,sort_keys=True))
CHECK
node "$repo/scripts/verify-generated-fixtures.cjs" > "$evidence/fixture-origins.log"
swift package "${options[@]}" show-dependencies --format json > "$evidence/dependencies.log" 2>&1
for round in 1 2; do
 skip=()
 if [[ "$round" == 2 ]]; then skip=(--skip-build); fi
 TEAQL_CONFORMANCE_DB="$evidence/work-items.sqlite" swift run --jobs 2 "${skip[@]}" "${options[@]}" TeaQLConsole > "$evidence/run-$round.log" 2>&1
 rg -Fq 'PASS Swift minimum runtime conformance: 9/9' "$evidence/run-$round.log"
done
fingerprint > "$evidence/source-after.sha256"
cmp "$evidence/source-before.sha256" "$evidence/source-after.sha256"
python3 -B - "$evidence" "$repo" <<'CHECK'
import hashlib,json,pathlib,sqlite3,sys
root,runtime=map(pathlib.Path,sys.argv[1:]);text=(root/'dependencies.log').read_text();start=text.find('{');assert start>=0
dependencies,_=json.JSONDecoder().raw_decode(text[start:]);nodes=[]
def visit(node):
 nodes.append(node)
 for child in node.get('dependencies',[]):visit(child)
visit(dependencies)
local=[node for node in nodes if node.get('path') and pathlib.Path(node['path']).resolve()==runtime.resolve()];assert len(local)==1
for round in [1,2]:
 log=(root/f'run-{round}.log').read_text();assert 'SWIFT_OPERATIONAL_CLOCK_EXAMPLE' in log
 assert 'PASS Swift minimum runtime conformance: 9/9' in log
database=root/'work-items.sqlite'
with sqlite3.connect(database.resolve().as_uri()+'?mode=ro&immutable=1',uri=True) as connection:
 rows=connection.execute('SELECT title,version FROM work_item_data ORDER BY id').fetchall();assert len(rows)==2 and all(row[1]==-3 for row in rows),rows
 assert connection.execute('PRAGMA quick_check').fetchone()==('ok',)
receipt=dict(schema='teaql.swift-work-item-business/v1',passed=True,originalBusinessAssertionsRetained=True,
 starts=2,sameDatabase=True,databaseNeverReset=True,nativeWorkspaceEntryUsed=True,generatedScopesUnchanged=True,
 localRuntimePath=local[0]['path'],dependencyWarningPrefixBytes=len(text[:start].encode()),workItems=rows,
 generatedDomainOrigins=json.loads((root/'generated-domain-origins.json').read_text()),
 databaseSHA256=hashlib.sha256(database.read_bytes()).hexdigest())
(root/'business-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
print(json.dumps(dict(passed=True,starts=2,sameDatabase=True)))
CHECK
