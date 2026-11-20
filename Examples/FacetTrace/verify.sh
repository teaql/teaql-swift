#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
if [[ -n "${TEAQL_FACET_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_FACET_EVIDENCE_DIR"
  mkdir "$evidence"
else
  evidence="$(mktemp -d -t teaql-facet-evidence.XXXXXXXX)"
fi
export TEAQL_FACET_TRACE_DB="$evidence/school.sqlite"
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
 owned_scratch="$(mktemp -d -t teaql-swift-facet-build.XXXXXXXX)"
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
assert files and not workspace.exists()
print(json.dumps(dict(passed=True,domainFiles=files,consumer='sibling Swift package'),indent=2,sort_keys=True))
CHECK
node "$repo/scripts/verify-generated-fixtures.cjs" > "$evidence/fixture-origins.log"
swift package "${options[@]}" show-dependencies --format json > "$evidence/dependencies.log" 2>&1
for round in 1 2; do
 skip=()
 if [[ "$round" == 2 ]]; then skip=(--skip-build); fi
 swift run --jobs 2 "${skip[@]}" "${options[@]}" TeaQLConsole "$TEAQL_FACET_TRACE_DB" > "$evidence/run-$round.log" 2>&1
 rg -Fq 'Swift generated Facet acceptance passed: 26 scenarios;' "$evidence/run-$round.log"
done
fingerprint > "$evidence/source-after.sha256"
cmp "$evidence/source-before.sha256" "$evidence/source-after.sha256"
python3 -B - "$evidence" "$repo" <<'CHECK'
import hashlib,json,pathlib,sqlite3,sys
root,runtime=map(pathlib.Path,sys.argv[1:]);text=(root/'dependencies.log').read_text();start=text.find('{');assert start>=0
dependencies,_=json.JSONDecoder().raw_decode(text[start:])
direct=dependencies['dependencies']
local=[node for node in direct if node.get('path') and pathlib.Path(node['path']).resolve()==runtime.resolve()];assert len(local)==1
domain=runtime/'Examples/FacetTrace/swift-lib-core'
assert any(node.get('path') and pathlib.Path(node['path']).resolve()==domain for node in direct)
observations=[]
for round in [1,2]:
 log=(root/f'run-{round}.log').read_text();proofs=[json.loads(line.removeprefix('SWIFT_FACET ')) for line in log.splitlines() if line.startswith('SWIFT_FACET ')]
 assert len(proofs)==26,len(proofs);observations.append(dict(round=round,scenarios=len(proofs)))
database=root/'school.sqlite'
with sqlite3.connect(database.resolve().as_uri()+'?mode=ro&immutable=1',uri=True) as connection:
 rows=connection.execute('SELECT name,address,version FROM school_data ORDER BY name').fetchall()
 assert rows==[('Facet School A','12 River Road',5),('Facet School B','12 River Road',1)],rows
 assert connection.execute('PRAGMA quick_check').fetchone()==('ok',)
receipt=dict(schema='teaql.swift-facet-business/v1',passed=True,scenariosPerRun=26,runs=2,sameDatabase=True,
 businessBodyUnchangedWithNativeMainEntryAdaptation=True,generatedScopesUnchanged=True,
 nativeWorkspaceEntryUsed=True,reverseChildWritebackVerified=True,observations=observations,
 generatedDomainOrigins=json.loads((root/'generated-domain-origins.json').read_text()),
 localRuntimePath=local[0]['path'],dependencyWarningPrefixBytes=len(text[:start].encode()),schools=rows,
 databaseSHA256=hashlib.sha256(database.read_bytes()).hexdigest())
(root/'business-receipt.json').write_text(json.dumps(receipt,indent=2,sort_keys=True)+'\n')
print(json.dumps(dict(passed=True,scenariosPerRun=26,runs=2)))
CHECK
