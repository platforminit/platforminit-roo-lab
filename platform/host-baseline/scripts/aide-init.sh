#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PATH="${1:-/tmp/platforminit-aide-init.txt}"
PLATFORMINIT_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"

resolve_existing_file() {
  local explicit="${1:-}"
  shift || true
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    printf '%s
' "$explicit"
    return 0
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      printf '%s
' "$candidate"
      return 0
    fi
  done
  return 1
}

DEPENDENCY_FILE="$(resolve_existing_file "${DEPENDENCY_FILE:-}"   "$SCRIPT_DIR/dependencies.yaml"   "$SCRIPT_DIR/../policy/dependencies.yaml")" || {
  echo "Missing dependencies.yaml" >&2
  exit 1
}
export DEPENDENCY_FILE

LIB_POLICY_FILE="$(resolve_existing_file "${PLATFORMINIT_LIB_POLICY:-}"   "$SCRIPT_DIR/lib-policy.sh"   "/usr/local/lib/platforminit/lib-policy.sh")" || {
  echo "Missing lib-policy.sh" >&2
  exit 1
}
source "$LIB_POLICY_FILE"

: > "$REPORT_PATH"
install -d -m 755 /var/lib/aide /var/log/aide "$PLATFORMINIT_AUDIT_DIR"

if ! command -v aide >/dev/null 2>&1; then
  "$SCRIPT_DIR/install-dependencies.sh"
fi
command -v aide >/dev/null 2>&1 || { echo "Missing aide after dependency install" | tee -a "$REPORT_PATH"; exit 1; }

printf 'AIDE init started at %s
' "$(date -u +%FT%TZ)" | tee -a "$REPORT_PATH"
rm -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db.new.gz

set +e
if command -v aideinit >/dev/null 2>&1; then
  aideinit -y >> "$REPORT_PATH" 2>&1
  rc=$?
else
  aide --init >> "$REPORT_PATH" 2>&1
  rc=$?
fi
set -e
(( rc == 0 )) || { baseline_event "aide_init" "fail" "$REPORT_PATH rc=$rc"; exit "$rc"; }

new_db=""
for candidate in /var/lib/aide/aide.db.new /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.new.*; do
  [[ -e "$candidate" ]] || continue
  new_db="$candidate"
  break
done
[[ -n "$new_db" ]] || { echo "AIDE init did not produce a database" | tee -a "$REPORT_PATH"; baseline_event "aide_init" "fail" "$REPORT_PATH missing_db"; exit 1; }

case "$new_db" in
  *.gz)
    gzip -dc "$new_db" > /var/lib/aide/aide.db
    ;;
  *)
    install -m 600 "$new_db" /var/lib/aide/aide.db
    ;;
esac
chmod 600 /var/lib/aide/aide.db
printf 'AIDE database ready: %s
' "/var/lib/aide/aide.db" | tee -a "$REPORT_PATH"
baseline_event "aide_init" "ok" "$REPORT_PATH"
audit_event "aide_init" "ok" "report=$REPORT_PATH"
