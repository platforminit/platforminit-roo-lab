#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

############################################
# CH01 Shared Start/Rebuild Task Contract Validation
#
# Validates that both platform and n8n tracks
# properly consume the shared CH01 host lifecycle
# contract without duplicating lifecycle logic.
#
# This is a local-only validation — no infrastructure
# access required.
#
# Acceptance criteria (P-CH01-T02):
# 1. platform track declares P-CH01-T02 as shared foundation
# 2. n8n track declares P-CH01-T02 as shared foundation
# 3. Both tracks have project YAML with required fields
# 4. Track-specific volume layouts are valid per contract
# 5. No duplicate host lifecycle logic exists across tracks
# 6. Shared contract document exists and is referenced
# 7. Orchestrator scripts are track-aware (--track flag)
############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CH01_CODE_ROOT="${CH01_CODE_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REPO_ROOT="$(cd "${CH01_CODE_ROOT}/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${CH01_CODE_ROOT}/reports}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_MD="${REPORT_MD:-$REPORT_DIR/validate-shared-start-rebuild-contract-${TS}.md}"
REPORT_JSON="${REPORT_JSON:-$REPORT_DIR/validate-shared-start-rebuild-contract-${TS}.json}"
PROJECTS_DIR="${PROJECTS_DIR:-${REPO_ROOT}/platform/projects}"
STATUS_DIR="${STATUS_DIR:-${REPO_ROOT}/tasks/status}"
ROADMAP_DIR="${ROADMAP_DIR:-${REPO_ROOT}/tasks/roadmap}"

mkdir -p "$REPORT_DIR"
PASS=0; WARN=0; FAIL=0; CHECKS_JSON=""

json_escape(){ local s=${1:-}; s=${s//\\/\\\\}; s=${s//"/\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}; printf '%s' "$s"; }

append_check(){
  local id="$1" sev="$2" st="$3" obs="$4" exp="$5"
  local entry
  entry=$(printf '{"id":"%s","severity":"%s","status":"%s","observed":"%s","expected":"%s"}' \
    "$(json_escape "$id")" "$(json_escape "$sev")" "$(json_escape "$st")" \
    "$(json_escape "$obs")" "$(json_escape "$exp")")
  [[ -n "$CHECKS_JSON" ]] && CHECKS_JSON+=$'\n,'
  CHECKS_JSON+="$entry"
}

md(){ printf '%s\n' "$*" >> "$REPORT_MD"; }
section(){ md ""; md "## $1"; md ""; }

res(){
  local sev="$1" id="$2" msg="$3" obs="${4:-}" exp="${5:-}"
  case "$sev" in
    PASS) PASS=$((PASS+1)); append_check "$id" PASS pass "$obs" "$exp" ;;
    WARN) WARN=$((WARN+1)); append_check "$id" WARN warn "$obs" "$exp" ;;
    FAIL) FAIL=$((FAIL+1)); append_check "$id" FAIL fail "$obs" "$exp" ;;
  esac
  md "- **${sev}** | ${id} | ${msg}"
}

: > "$REPORT_MD"
md "# CH01 Shared Start/Rebuild Contract Validation"
md "- Generated: $(date -u +%FT%TZ)"
md "- Workspace: ${CH01_CODE_ROOT}"
md ""

# --------------------------------------------------
# Section 1: Shared foundation dependency declaration
# --------------------------------------------------
section "Shared foundation dependency declaration"

# Check platform track declares P-CH01-T02
PLATFORM_STATUS="${STATUS_DIR}/platform.json"
if [[ -f "$PLATFORM_STATUS" ]]; then
  if grep -q '"P-CH01-T02"' "$PLATFORM_STATUS"; then
    res PASS PLATFORM_DECLARES_P_CH01_T02 "platform track declares P-CH01-T02 in status" "found in ${PLATFORM_STATUS}" "P-CH01-T02 present"
  else
    res FAIL PLATFORM_DECLARES_P_CH01_T02 "platform track missing P-CH01-T02 in status" "not found in ${PLATFORM_STATUS}" "P-CH01-T02 must be present"
  fi
else
  res FAIL PLATFORM_STATUS_EXISTS "platform status file not found" "${PLATFORM_STATUS}" "file must exist"
fi

# Check n8n track declares P-CH01-T02
N8N_STATUS="${STATUS_DIR}/n8n.json"
if [[ -f "$N8N_STATUS" ]]; then
  if grep -q '"P-CH01-T02"' "$N8N_STATUS"; then
    res PASS N8N_DECLARES_P_CH01_T02 "n8n track declares P-CH01-T02 in status" "found in ${N8N_STATUS}" "P-CH01-T02 present"
  else
    res FAIL N8N_DECLARES_P_CH01_T02 "n8n track missing P-CH01-T02 in status" "not found in ${N8N_STATUS}" "P-CH01-T02 must be present"
  fi
else
  res FAIL N8N_STATUS_EXISTS "n8n status file not found" "${N8N_STATUS}" "file must exist"
fi

# Check platform roadmap declares P-CH01-T02 as shared foundation
PLATFORM_ROADMAP="${ROADMAP_DIR}/platform.json"
if [[ -f "$PLATFORM_ROADMAP" ]]; then
  # Use python3 to extract shared_foundation value for P-CH01-T02
  SHARED_VAL="$(python3 -c "
import json
data = json.load(open('${PLATFORM_ROADMAP}'))
for t in data['tasks']:
    if t['id'] == 'P-CH01-T02':
        print(str(t.get('shared_foundation', False)).lower())
" 2>/dev/null || echo "false")"
  if [[ "$SHARED_VAL" == "true" ]]; then
    res PASS PLATFORM_ROADMAP_SHARED "platform roadmap marks P-CH01-T02 as shared_foundation" "shared_foundation=true" "shared_foundation must be true"
  else
    res FAIL PLATFORM_ROADMAP_SHARED "platform roadmap does not mark P-CH01-T02 as shared_foundation" "shared_foundation=${SHARED_VAL}" "shared_foundation must be true"
  fi
else
  res FAIL PLATFORM_ROADMAP_EXISTS "platform roadmap file not found"
fi

# Check n8n roadmap consumes P-CH01-T02
N8N_ROADMAP="${ROADMAP_DIR}/n8n.json"
if [[ -f "$N8N_ROADMAP" ]]; then
  if grep -q '"P-CH01-T02"' "$N8N_ROADMAP"; then
    res PASS N8N_ROADMAP_CONSUMES "n8n roadmap references P-CH01-T02" "found in ${N8N_ROADMAP}" "P-CH01-T02 referenced"
  else
    res FAIL N8N_ROADMAP_CONSUMES "n8n roadmap does not reference P-CH01-T02" "not found in ${N8N_ROADMAP}" "P-CH01-T02 must be referenced"
  fi
else
  res FAIL N8N_ROADMAP_EXISTS "n8n roadmap file not found"
fi

# --------------------------------------------------
# Section 2: Project YAML contract
# --------------------------------------------------
section "Project YAML contract"

PROJECT_FILES=()
for f in "${PROJECTS_DIR}"/*.yaml; do
  [[ -f "$f" ]] && PROJECT_FILES+=("$f")
done

if [[ ${#PROJECT_FILES[@]} -ge 2 ]]; then
  res PASS PROJECT_YAML_COUNT "Project YAML files count sufficient for shared contract" "${#PROJECT_FILES[@]} files" "at least 2 (development, n8n)"
else
  res FAIL PROJECT_YAML_COUNT "Insufficient project YAML files for shared contract" "${#PROJECT_FILES[@]} files" "at least 2"
fi

# Validate each project YAML has required contract fields
for pf in "${PROJECT_FILES[@]}"; do
  pname="$(basename "$pf" .yaml)"
  pid="$(grep -E 'project_id:' "$pf" | awk '{print $2}' || true)"
  token="$(grep -E 'token_secret:' "$pf" | awk '{print $2}' || true)"
  prefix="$(grep -E 'server_prefix:' "$pf" | awk '{print $2}' || true)"
  layout="$(grep -E 'layout:' "$pf" | awk '{print $2}' || true)"

  [[ -n "$pid" ]] && res PASS "CONTRACT_PROJECT_ID_${pname^^}" "${pname}: project_id=${pid}" || res FAIL "CONTRACT_PROJECT_ID_${pname^^}" "${pname}: project_id missing"
  if [[ -n "$token" ]]; then
    if [[ "$token" =~ ^HCLOUD_TOKEN_ ]]; then
      res PASS "CONTRACT_TOKEN_SECRET_${pname^^}" "${pname}: token_secret=HCLOUD_TOKEN_*** (valid pattern)" "secret-name-valid"
    else
      res FAIL "CONTRACT_TOKEN_SECRET_${pname^^}" "${pname}: token_secret does not match HCLOUD_TOKEN_* pattern" "secret-name-invalid"
    fi
  else
    res FAIL "CONTRACT_TOKEN_SECRET_${pname^^}" "${pname}: token_secret missing"
  fi
  [[ -n "$prefix" ]] && res PASS "CONTRACT_SERVER_PREFIX_${pname^^}" "${pname}: server_prefix=${prefix}" || res FAIL "CONTRACT_SERVER_PREFIX_${pname^^}" "${pname}: server_prefix missing"
  [[ -n "$layout" ]] && res PASS "CONTRACT_VOLUME_LAYOUT_${pname^^}" "${pname}: layout=${layout}" || res FAIL "CONTRACT_VOLUME_LAYOUT_${pname^^}" "${pname}: layout missing"
done

# --------------------------------------------------
# Section 3: Track-specific volume layout contract
# --------------------------------------------------
section "Track-specific volume layout contract"

# development must be split
dev_layout="$(grep -E 'layout:' "${PROJECTS_DIR}/development.yaml" 2>/dev/null | awk '{print $2}' || true)"
if [[ "$dev_layout" == "split" ]]; then
  res PASS CONTRACT_DEV_LAYOUT "development volume_layout=split (platform k3s host)" "${dev_layout}" "split"
else
  res FAIL CONTRACT_DEV_LAYOUT "development volume_layout mismatch" "${dev_layout:-missing}" "split"
fi

# n8n must be none
n8n_layout="$(grep -E 'layout:' "${PROJECTS_DIR}/n8n.yaml" 2>/dev/null | awk '{print $2}' || true)"
if [[ "$n8n_layout" == "none" ]]; then
  res PASS CONTRACT_N8N_LAYOUT "n8n volume_layout=none (standalone, root-disk-only)" "${n8n_layout}" "none"
else
  res FAIL CONTRACT_N8N_LAYOUT "n8n volume_layout mismatch" "${n8n_layout:-missing}" "none"
fi

# platforminit must be split
plat_layout="$(grep -E 'layout:' "${PROJECTS_DIR}/platforminit.yaml" 2>/dev/null | awk '{print $2}' || true)"
if [[ "$plat_layout" == "split" ]]; then
  res PASS CONTRACT_PLATFORMINIT_LAYOUT "platforminit volume_layout=split (production)" "${plat_layout}" "split"
else
  res FAIL CONTRACT_PLATFORMINIT_LAYOUT "platforminit volume_layout mismatch" "${plat_layout:-missing}" "split"
fi

# --------------------------------------------------
# Section 4: No duplicate host lifecycle logic
# --------------------------------------------------
section "No duplicate host lifecycle logic"

# Check that n8n track does not duplicate CH01 lifecycle scripts
N8N_SCRIPTS_DIR="${REPO_ROOT}/platform/n8n/scripts"
N8N_VALIDATE_DIR="${REPO_ROOT}/platform/n8n/validate"
DUPLICATE_FOUND=0

# n8n should not have its own host lifecycle scripts
for pattern in "bootstrap-host" "create-host" "rebuild-host" "host-lifecycle"; do
  if find "$N8N_SCRIPTS_DIR" -name "*${pattern}*" -o -name "*${pattern}*" 2>/dev/null | grep -q .; then
    DUPLICATE_FOUND=$((DUPLICATE_FOUND+1))
    res FAIL N8N_DUPLICATE_LIFECYCLE "n8n track contains duplicate host lifecycle logic: ${pattern}" "found in ${N8N_SCRIPTS_DIR}" "no duplicate lifecycle scripts"
  fi
done

if [[ "$DUPLICATE_FOUND" == "0" ]]; then
  res PASS N8N_NO_DUPLICATE_LIFECYCLE "n8n track does not duplicate CH01 host lifecycle logic" "no duplicate scripts found" "no duplication"
fi

# Check that platform track does not duplicate CH01 lifecycle scripts
PLATFORM_SCRIPTS_DIR="${REPO_ROOT}/platform/platform-services/scripts"
PLATFORM_DUPLICATE=0
for pattern in "bootstrap-host" "create-host" "rebuild-host" "host-lifecycle"; do
  if find "$PLATFORM_SCRIPTS_DIR" -name "*${pattern}*" 2>/dev/null | grep -q .; then
    PLATFORM_DUPLICATE=$((PLATFORM_DUPLICATE+1))
    res FAIL PLATFORM_DUPLICATE_LIFECYCLE "platform track contains duplicate host lifecycle logic: ${pattern}" "found in ${PLATFORM_SCRIPTS_DIR}" "no duplicate lifecycle scripts"
  fi
done

if [[ "$PLATFORM_DUPLICATE" == "0" ]]; then
  res PASS PLATFORM_NO_DUPLICATE_LIFECYCLE "platform track does not duplicate CH01 host lifecycle logic" "no duplicate scripts found" "no duplication"
fi

# --------------------------------------------------
# Section 5: Orchestrator script track-awareness
# --------------------------------------------------
section "Orchestrator script track-awareness"

# start-next-task.sh must support --track flag
START_SCRIPT="${REPO_ROOT}/scripts/orchestrator/start-next-task.sh"
if [[ -f "$START_SCRIPT" ]]; then
  if grep -qE '\-\-track' "$START_SCRIPT"; then
    res PASS START_SCRIPT_TRACK_AWARE "start-next-task.sh supports --track flag" "--track present" "--track required"
  else
    res FAIL START_SCRIPT_TRACK_AWARE "start-next-task.sh missing --track support"
  fi
else
  res FAIL START_SCRIPT_EXISTS "start-next-task.sh not found"
fi

# close-current-task.sh must support --track flag
CLOSE_SCRIPT="${REPO_ROOT}/scripts/orchestrator/close-current-task.sh"
if [[ -f "$CLOSE_SCRIPT" ]]; then
  if grep -qE '\-\-track' "$CLOSE_SCRIPT"; then
    res PASS CLOSE_SCRIPT_TRACK_AWARE "close-current-task.sh supports --track flag" "--track present" "--track required"
  else
    res FAIL CLOSE_SCRIPT_TRACK_AWARE "close-current-task.sh missing --track support"
  fi
else
  res FAIL CLOSE_SCRIPT_EXISTS "close-current-task.sh not found"
fi

# generate-next-task.py must support --track flag
GENERATE_SCRIPT="${REPO_ROOT}/scripts/orchestrator/generate-next-task.py"
if [[ -f "$GENERATE_SCRIPT" ]]; then
  if grep -qE '\-\-track' "$GENERATE_SCRIPT"; then
    res PASS GENERATE_SCRIPT_TRACK_AWARE "generate-next-task.py supports --track flag" "--track present" "--track required"
  else
    res FAIL GENERATE_SCRIPT_TRACK_AWARE "generate-next-task.py missing --track support"
  fi
else
  res FAIL GENERATE_SCRIPT_EXISTS "generate-next-task.py not found"
fi

# --------------------------------------------------
# Section 6: Contract document exists
# --------------------------------------------------
section "Contract document exists"

CONTRACT_DOC="${REPO_ROOT}/docs/ch01-shared-start-rebuild-contract.md"
if [[ -f "$CONTRACT_DOC" ]]; then
  res PASS CONTRACT_DOC_EXISTS "Shared start/rebuild contract document exists" "${CONTRACT_DOC}" "file must exist"
else
  res FAIL CONTRACT_DOC_EXISTS "Shared start/rebuild contract document missing"
fi

# --------------------------------------------------
# Section 7: NEXT_TASK.md acceptance criteria refinement
# --------------------------------------------------
section "NEXT_TASK.md acceptance criteria refinement"

PLATFORM_NEXT="${REPO_ROOT}/tasks/active/platform/NEXT_TASK.md"
if [[ -f "$PLATFORM_NEXT" ]]; then
  if grep -qE 'P-CH01-T02' "$PLATFORM_NEXT"; then
    res PASS PLATFORM_NEXT_POINTER "platform NEXT_TASK.md points at P-CH01-T02" "P-CH01-T02 found" "current pointer"
  else
    res FAIL PLATFORM_NEXT_POINTER "platform NEXT_TASK.md does not point at P-CH01-T02" "P-CH01-T02 not found" "must point at current task"
  fi
else
  res FAIL PLATFORM_NEXT_EXISTS "platform NEXT_TASK.md not found"
fi

# --------------------------------------------------
# Summary
# --------------------------------------------------
section "Summary"

md ""
md "| Metric | Count |"
md "|---|---|"
md "| PASS | ${PASS} |"
md "| WARN | ${WARN} |"
md "| FAIL | ${FAIL} |"
md ""

TOTAL=$((PASS + WARN + FAIL))
OVERALL="PASS"
OVERALL_STATUS="pass"
if (( FAIL != 0 )); then
  OVERALL="FAIL"
  OVERALL_STATUS="fail"
elif (( WARN != 0 )); then
  OVERALL="WARN (no failures)"
fi
md "**Overall: ${OVERALL}** (${PASS}/${TOTAL} passed)"

cat > "$REPORT_JSON" <<EOFJSON
{
  "generated_at": "$(date -u +%FT%TZ)",
  "workspace": "$(json_escape "$CH01_CODE_ROOT")",
  "profile": "ch01-shared-start-rebuild-contract-validator-v1",
  "checks": [
$CHECKS_JSON
  ],
  "summary": {"pass": $PASS, "warn": $WARN, "fail": $FAIL, "total": $TOTAL, "status": "$OVERALL_STATUS"}
}
EOFJSON

ln -sfn "$(basename "$REPORT_MD")" "${REPORT_DIR}/validate-shared-start-rebuild-contract-latest.md"
ln -sfn "$(basename "$REPORT_JSON")" "${REPORT_DIR}/validate-shared-start-rebuild-contract-latest.json"

echo ""
echo "Report: ${REPORT_MD}"
echo "JSON:   ${REPORT_JSON}"
echo "Summary: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"

if (( FAIL != 0 )); then
  exit 2
fi
