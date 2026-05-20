#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$CODE_ROOT/scripts/ch01-env.sh"

BASE="${BASELINE_KNOWN_GOOD_FILE:-$CODE_ROOT/baseline/state-known-good.json}"
[ -f "$BASE" ] || { echo "FAIL: missing $BASE (run capture-state.sh + promote-known-good.sh once)"; exit 1; }

mkdir -p "$REPORT_DIR" "$STATE_DIR"
"$CODE_ROOT/baseline/capture-state.sh" "$STATE_DIR" >/dev/null
CUR="$STATE_DIR/state-current.json"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$REPORT_DIR/drift-${TS}.md"

PASS=0; WARN=0; FAIL=0
cmp_field() {
  local name="$1" jqexpr="$2" severity="$3"
  local old new
  old="$(jq -r "$jqexpr" "$BASE" 2>/dev/null || true)"
  new="$(jq -r "$jqexpr" "$CUR" 2>/dev/null || true)"

  if [ "$old" = "$new" ]; then
    echo "| PASS | $name |" >> "$REPORT"
    PASS=$((PASS+1))
  else
    if [ "$severity" = "FAIL" ]; then
      echo "| FAIL | $name |" >> "$REPORT"
      FAIL=$((FAIL+1))
    else
      echo "| WARN | $name |" >> "$REPORT"
      WARN=$((WARN+1))
    fi
  fi
}

{
  echo "# CH01 Drift Report"
  echo
  echo "- known-good: \
\`$BASE\`"
  echo "- current: \
\`$CUR\`"
  echo
  echo "## Matrix"
  echo
  echo "| Verdict | Check |"
  echo "|---|---|"
} > "$REPORT"

cmp_field "SSHD subset" '.security.sshd_effective_subset' "FAIL"
cmp_field "UFW status" '.security.ufw' "FAIL"
cmp_field "/srv UUID (from fstab)" '.storage.srv_uuid_from_fstab' "FAIL"
cmp_field "Baseline allowlist" '.packages.baseline_allowlist' "FAIL"
cmp_field "Host kernel" '.host.kernel' "WARN"

{
  echo
  echo "## Summary"
  echo
  echo "- PASS: $PASS"
  echo "- WARN: $WARN"
  echo "- FAIL: $FAIL"
} >> "$REPORT"

ln -sfn "$(basename "$REPORT")" "$REPORT_DIR/drift-latest.md"
echo "Report: $REPORT"
[ "$FAIL" -gt 0 ] && exit 2 || exit 0
