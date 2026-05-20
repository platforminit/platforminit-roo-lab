#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PATH="${1:-/tmp/platforminit-aide-check.txt}"
PLATFORMINIT_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"

resolve_existing_file() {
  local explicit="${1:-}"
  shift || true
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

: > "$REPORT_PATH"

LIB_POLICY_FILE="$(resolve_existing_file "${PLATFORMINIT_LIB_POLICY:-}"   "$SCRIPT_DIR/lib-policy.sh"   "/usr/local/lib/platforminit/lib-policy.sh")" || {
  echo "Missing lib-policy.sh" | tee -a "$REPORT_PATH" >&2
  exit 1
}
source "$LIB_POLICY_FILE"

CONFIG_FILE="$(resolve_existing_file "${AIDE_CONFIG:-}"   "$SCRIPT_DIR/aide.conf"   "/etc/aide/aide.conf")" || {
  echo "Missing aide.conf" | tee -a "$REPORT_PATH" >&2
  exit 1
}

command -v aide >/dev/null 2>&1 || {
  echo "Missing aide" | tee -a "$REPORT_PATH"
  exit 1
}

[[ -f /var/lib/aide/aide.db ]] || {
  echo "Missing AIDE DB - run init first" | tee -a "$REPORT_PATH"
  exit 1
}

echo "AIDE | CHECK START $(date -u +%FT%TZ)" | tee -a "$REPORT_PATH"

set +e
aide --check -c "$CONFIG_FILE" >> "$REPORT_PATH" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  echo "AIDE | CLEAN"
  exit 0
fi

if [[ "$rc" -eq 1 ]]; then
  echo "AIDE | DRIFT DETECTED"
  exit 0
fi

echo "AIDE | NON-CLEAN (rc=$rc)"
exit 0
