#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

POLICY_FILE="$(resolve_existing_file "${POLICY_FILE:-}"   "$SCRIPT_DIR/baseline.yaml"   "$SCRIPT_DIR/../policy/baseline.yaml")" || {
  echo "Error: baseline policy file not found" >&2
  exit 1
}

LIB_POLICY_FILE="$(resolve_existing_file "${PLATFORMINIT_LIB_POLICY:-}"   "$SCRIPT_DIR/lib-policy.sh"   "/usr/local/lib/platforminit/lib-policy.sh")" || {
  echo "Error: lib-policy.sh not found" >&2
  exit 1
}
source "$LIB_POLICY_FILE"

report="${1:-/tmp/platforminit-fim-check.txt}"
: > "$report"

command -v yq >/dev/null 2>&1 || { echo "Missing yq" | tee -a "$report"; exit 1; }

fail=0

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  if [[ -e "$path" ]]; then
    printf 'PASS | REQUIRED_PATH | %s
' "$path" | tee -a "$report"
  else
    printf 'FAIL | REQUIRED_PATH | missing %s
' "$path" | tee -a "$report"
    fail=1
  fi
done < <(yq -r '.fim.required_paths[]?' "$POLICY_FILE")

count="$(yq -r '.fim.file_contains | length // 0' "$POLICY_FILE")"
if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
  for idx in $(seq 0 $((count - 1))); do
    file_path="$(yq -r ".fim.file_contains[$idx].path" "$POLICY_FILE")"
    if [[ ! -f "$file_path" ]]; then
      printf 'FAIL | FILE_CONTAINS | missing file %s
' "$file_path" | tee -a "$report"
      fail=1
      continue
    fi
    while IFS= read -r expected; do
      [[ -n "$expected" ]] || continue
      if grep -Fqx "$expected" "$file_path" || grep -Fq "$expected" "$file_path"; then
        printf 'PASS | FILE_CONTAINS | %s contains %s
' "$file_path" "$expected" | tee -a "$report"
      else
        printf 'FAIL | FILE_CONTAINS | %s missing %s
' "$file_path" "$expected" | tee -a "$report"
        fail=1
      fi
    done < <(yq -r ".fim.file_contains[$idx].contains[]?" "$POLICY_FILE")
  done
fi

if (( fail == 0 )); then
  baseline_event "fim_check" "ok" "$report"
else
  baseline_event "fim_check" "fail" "$report"
fi

cat "$report"
exit $fail
