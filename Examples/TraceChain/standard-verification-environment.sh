# Sourced by the standard Order, graph and startup scripts.
standard_verification_environment() {
  local label="$1"
  shift
  if [[ $# -eq 1 && "$1" == --enabled ]]; then
    [[ "${TEAQL_TELEMETRY_ENABLED:-}" == true && -n "${TEAQL_TELEMETRY_SERVICE_NAME:-}" && -n "${TEAQL_TELEMETRY_OTLP_ENDPOINT:-}" ]]
    launch=(env)
    startup='TeaQL telemetry: enabled;'
  elif [[ $# -eq 0 ]]; then
    launch=(env -u TEAQL_TELEMETRY_ENABLED -u TEAQL_TELEMETRY_SERVICE_NAME -u TEAQL_TELEMETRY_OTLP_ENDPOINT)
    startup='TeaQL telemetry: supported, disabled.'
  else
    echo "usage: $label [--enabled]" >&2
    return 2
  fi
  evidence="${TEAQL_SWIFT_STANDARD_EVIDENCE_DIR:-}"
  if [[ -n "$evidence" ]]; then
    mkdir -p "$(dirname "$evidence")"
    mkdir "$evidence"
  else
    evidence="$(mktemp -d "${TMPDIR:-/tmp}/teaql-swift-standard-$label.XXXXXX")"
  fi
  evidence="$(cd "$evidence" && pwd)"
}

check_standard_startup() {
  rg -Fq "$startup" "$1"
  if [[ "$startup" == 'TeaQL telemetry: supported, disabled.' ]]; then
    local name
    for name in TEAQL_TELEMETRY_ENABLED TEAQL_TELEMETRY_SERVICE_NAME TEAQL_TELEMETRY_OTLP_ENDPOINT; do
      rg -Fq "$name" "$1"
    done
  fi
}

fingerprint() {
  find ../swift-lib-core/Sources -type f -name '*.swift' -print0 | sort -z | xargs -0 sha256sum
  sha256sum Package.swift Package.resolved ../swift-lib-core/Package.swift
}
