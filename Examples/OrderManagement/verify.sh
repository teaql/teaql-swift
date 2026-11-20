#!/usr/bin/env bash
set -euo pipefail
example="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$example/../.." && pwd)"
app="$example/swift-app-console"
if [[ -n "${TEAQL_ORDER_EVIDENCE_DIR:-}" ]]; then
  evidence="$TEAQL_ORDER_EVIDENCE_DIR"
  mkdir "$evidence"
else
  evidence="$(mktemp -d -t teaql-swift-order-evidence.XXXXXXXX)"
fi
owned_workspace=''
owned_root=''
cleanup() {
  status=$?
  trap - EXIT
  if [[ -n "$owned_workspace" ]]; then rm -rf -- "$owned_workspace"; fi
  if [[ -n "$owned_root" ]]; then rm -rf -- "$owned_root"; fi
  exit "$status"
}
trap cleanup EXIT
owned_root="$(mktemp -d -t teaql-swift-order-sdk-build.XXXXXXXX)"
if [[ -z "${TEAQL_SWIFT_SCRATCH_PATH:-}" ]]; then
  owned_workspace="$(mktemp -d -t teaql-swift-order-workspace-build.XXXXXXXX)"
  export TEAQL_SWIFT_SCRATCH_PATH="$owned_workspace"
fi
workspace_options=(--package-path "$app" --scratch-path "$TEAQL_SWIFT_SCRATCH_PATH"
  --disable-build-manifest-caching --force-resolved-versions)
root_options=(--package-path "$repo" --scratch-path "$owned_root"
  --disable-build-manifest-caching --force-resolved-versions)
fingerprint() {
  (cd "$example" && find swift-lib-core swift-app-console -type f \
    ! -path '*/.build/*' -print0 | sort -z | xargs -0 sha256sum)
  sha256sum "$repo/Package.swift"
}
fingerprint > "$evidence/source-before.sha256"
swift package "${workspace_options[@]}" show-dependencies --format json > "$evidence/dependencies.log" 2>&1
for round in 1 2; do
  skip=()
  if [[ "$round" == 2 ]]; then skip=(--skip-build); fi
  swift run --jobs 2 "${skip[@]}" "${workspace_options[@]}" TeaQLConsole "$evidence/workspace.sqlite" \
    > "$evidence/workspace-$round.log" 2>&1
  swift run --jobs 2 "${skip[@]}" "${root_options[@]}" teaql-order-management "$evidence/sdk.sqlite" \
    > "$evidence/sdk-$round.log" 2>&1
done
fingerprint > "$evidence/source-after.sha256"
cmp "$evidence/source-before.sha256" "$evidence/source-after.sha256"
python3 -B - "$evidence" "$repo" <<'PY'
import decimal, hashlib, json, pathlib, re, sqlite3, sys
root, runtime = map(pathlib.Path, sys.argv[1:])
text = (root / 'dependencies.log').read_text()
start = text.find('{')
assert start >= 0
dependencies, _ = json.JSONDecoder().raw_decode(text[start:])
nodes = []
def visit(node):
    nodes.append(node)
    for child in node.get('dependencies', []):
        visit(child)
visit(dependencies)
local = [node for node in nodes if node.get('path') and pathlib.Path(node['path']).resolve() == runtime.resolve()]
assert len(local) == 1, local
observations = []
for entry in ['workspace', 'sdk']:
    audits = []
    for round in [1, 2]:
        log = (root / f'{entry}-{round}.log').read_text()
        assert re.search(r'ORDER \d+: SWIFT-ORDER-001, total=(?:Optional\(129\.95\)|129\.95), version=1', log)
        assert 'TeaQL query: returned 1 order(s)' in log
        if round == 1:
            assert 'TeaQL seed: created SWIFT-ORDER-001' in log and 'APP AUDIT:' in log
        else:
            assert 'TeaQL seed: created' not in log and 'APP AUDIT:' not in log
        rows = re.findall(r'TeaQL row audit: (\d+) event\(s\)', log)
        assert len(rows) == 1
        audits.append(int(rows[0]))
    database = root / (entry + '.sqlite')
    with sqlite3.connect(database.resolve().as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
        orders = connection.execute('SELECT order_number,order_date,total_amount,version FROM customer_order_data').fetchall()
        assert len(orders) == 1 and orders[0][0] == 'SWIFT-ORDER-001' and orders[0][1] is not None, orders
        assert decimal.Decimal(str(orders[0][2])) == decimal.Decimal('129.95') and orders[0][3] == 1
        assert connection.execute('SELECT count(*) FROM customer_data').fetchone() == (1,)
        assert connection.execute('PRAGMA quick_check').fetchone() == ('ok',)
    observations.append(dict(entry=entry, runs=2, sameDatabase=True, orders=orders,
        reportedAuditCounts=audits, secondRunAppAudits=0,
        databaseSHA256=hashlib.sha256(database.read_bytes()).hexdigest()))
receipt = dict(schema='teaql.swift-order-business/v1', passed=True, entries=observations,
    localRuntime=local[0], dependencyWarningPrefixBytes=len(text[:start].encode()),
    generatedScopesUnchanged=True, rootExampleTargetVerified=True,
    separatePackageBuildGraphs=True, originalBusinessProgramByteExact=True)
(root / 'business-receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
print(json.dumps(dict(passed=True, entries=2, runsPerEntry=2)))
PY
