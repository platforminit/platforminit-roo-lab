#!/usr/bin/env bash
set -euo pipefail

BASE="/srv/ch01/baseline/state-known-good.json"
[ -f "$BASE" ] || { echo "FAIL: missing $BASE (run promote-known-good.sh once)"; exit 1; }

mkdir -p /srv/ch01/reports

/srv/ch01/baseline/capture-state-v2.1.sh >/dev/null
CUR="/srv/ch01/baseline/state-current.json"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="/srv/ch01/reports/drift-${TS}.md"

PASS=0; WARN=0; FAIL=0
cmp_field() {
  local name="$1" jqexpr="$2" severity="$3"
  local old new
  old="$(jq -r "$jqexpr" "$BASE" 2>/dev/null || true)"
  new="$(jq -r "$jqexpr" "$CUR" 2>/dev/null || true)"

  if [ "$old" = "$new" ]; then
    echo "PASS | $name" | tee -a "$REPORT"
    PASS=$((PASS+1))
  else
    if [ "$severity" = "FAIL" ]; then
      echo "FAIL | $name" | tee -a "$REPORT"
      FAIL=$((FAIL+1))
    else
      echo "WARN | $name" | tee -a "$REPORT"
      WARN=$((WARN+1))
    fi
  fi
}

{
  echo "# CH01 Drift Report"
  echo ""
  echo "- known-good: \`$BASE\`"
  echo "- current: \`$CUR\`"
  echo ""
  echo "## Matrix"
  echo ""
  echo "| Verdict | Check |"
  echo "|---|---|"
} > "$REPORT"

cmp_field "SSHD subset" '.security.sshd_effective_subset' "FAIL"
cmp_field "UFW status" '.security.ufw' "FAIL"
cmp_field "/srv UUID (from fstab)" '.storage.srv_uuid_from_fstab' "FAIL"
cmp_field "Baseline allowlist" '.packages.baseline_allowlist' "FAIL"
cmp_field "Host kernel" '.host.kernel' "WARN"

{
  echo ""
  echo "## Summary"
  echo ""
  echo "- PASS: $PASS"
  echo "- WARN: $WARN"
  echo "- FAIL: $FAIL"
} >> "$REPORT"

echo "Report: $REPORT"
if [ "$FAIL" -gt 0 ]; then exit 2; fi
