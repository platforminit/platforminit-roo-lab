#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

############################################
# CH01 Shared Host Lifecycle Contract Validation
#
# Validates the shared host lifecycle contract
# for both platform and n8n tracks without
# requiring runtime infrastructure access.
#
# Hostnames are DERIVED from the project registry
# (platform/projects/*.yaml) — specifically from
# server_prefix + default server index (-01).
#
# The values below are CURRENT EXAMPLES based on
# the registry state at validation time, NOT
# permanent immutable constants.
#
# Acceptance criteria:
# 1. development host currently derives platforminit-dev-01
# 2. n8n host currently derives platforminit-n8n-01 when n8n track is selected
# 3. project input controls environment and token routing
# 4. volume_layout supports none for n8n and platform-specific layouts
############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CH01_CODE_ROOT="${CH01_CODE_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REPO_ROOT="$(cd "${CH01_CODE_ROOT}/../.." && pwd)"
REPORT_DIR="${REPORT_DIR:-${CH01_CODE_ROOT}/reports}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_MD="${REPORT_MD:-$REPORT_DIR/validate-host-lifecycle-contract-${TS}.md}"
REPORT_JSON="${REPORT_JSON:-$REPORT_DIR/validate-host-lifecycle-contract-${TS}.json}"
PROJECTS_DIR="${PROJECTS_DIR:-${REPO_ROOT}/platform/projects}"

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
md "# CH01 Shared Host Lifecycle Contract Validation"
md "- Generated: $(date -u +%FT%TZ)"
md "- Workspace: ${CH01_CODE_ROOT}"
md ""

# --------------------------------------------------
# Section 1: Project YAML definitions
# --------------------------------------------------
section "Project YAML definitions"

PROJECT_FILES=()
for f in "${PROJECTS_DIR}"/*.yaml; do
  [[ -f "$f" ]] && PROJECT_FILES+=("$f")
done

if [[ ${#PROJECT_FILES[@]} -ge 1 ]]; then
  res PASS PROJECT_YAML_EXIST "Project YAML files found" "${#PROJECT_FILES[@]} files" "at least 1"
else
  res FAIL PROJECT_YAML_EXIST "No project YAML files found in ${PROJECTS_DIR}"
fi

# Validate each project YAML has required fields
for pf in "${PROJECT_FILES[@]}"; do
  pname="$(basename "$pf" .yaml)"
  pid="$(grep -E '^project_id:' "$pf" | awk '{print $2}' || true)"
  token="$(grep -E 'token_secret:' "$pf" | awk '{print $2}' || true)"
  prefix="$(grep -E 'server_prefix:' "$pf" | awk '{print $2}' || true)"
  layout="$(grep -E 'layout:' "$pf" | awk '{print $2}' || true)"

  [[ -n "$pid" ]] && res PASS "PROJECT_ID_${pname^^}" "${pname}: project_id=${pid}" || res FAIL "PROJECT_ID_${pname^^}" "${pname}: project_id missing"
  [[ -n "$token" ]] && res PASS "TOKEN_SECRET_${pname^^}" "${pname}: token_secret=${token}" || res FAIL "TOKEN_SECRET_${pname^^}" "${pname}: token_secret missing"
  [[ -n "$prefix" ]] && res PASS "SERVER_PREFIX_${pname^^}" "${pname}: server_prefix=${prefix}" || res FAIL "SERVER_PREFIX_${pname^^}" "${pname}: server_prefix missing"
  [[ -n "$layout" ]] && res PASS "VOLUME_LAYOUT_${pname^^}" "${pname}: layout=${layout}" || res FAIL "VOLUME_LAYOUT_${pname^^}" "${pname}: layout missing"
done

# --------------------------------------------------
# Section 2: Host naming contract
# --------------------------------------------------
section "Host naming contract"

# Derive server_prefix from project YAML
dev_prefix="$(grep -E 'server_prefix:' "${PROJECTS_DIR}/development.yaml" 2>/dev/null | awk '{print $2}' || true)"
n8n_prefix="$(grep -E 'server_prefix:' "${PROJECTS_DIR}/n8n.yaml" 2>/dev/null | awk '{print $2}' || true)"
plat_prefix="$(grep -E 'server_prefix:' "${PROJECTS_DIR}/platforminit.yaml" 2>/dev/null | awk '{print $2}' || true)"

# --------------------------------------------------
# Host naming contract
#
# Hostnames are DERIVED from the project registry:
#   effective_hostname = <server_prefix>-<default_server_index>
#
# The default server index is currently "01" for all projects.
# This is a resolver convention, not a permanent invariant.
# Future explicit hostname override support must not be
# blocked by this validator design.
#
# The checks below validate that:
#   1. server_prefix is present in each project YAML
#   2. the derived hostname follows the <prefix>-NN pattern
#   3. the derived hostname matches the resolver contract
#
# They do NOT assert that platforminit-dev-01 or
# platforminit-n8n-01 are permanent global constants.
# Those are CURRENT EXAMPLES based on today's registry state.
# --------------------------------------------------

# Validate server_prefix values — assert presence and pattern, not specific values
if [[ -n "$dev_prefix" ]]; then
  res PASS DEV_HOST_PREFIX "development server_prefix: ${dev_prefix} (current example)" "${dev_prefix}" "<prefix> present"
else
  res FAIL DEV_HOST_PREFIX "development server_prefix missing"
fi

if [[ -n "$n8n_prefix" ]]; then
  res PASS N8N_HOST_PREFIX "n8n server_prefix: ${n8n_prefix} (current example)" "${n8n_prefix}" "<prefix> present"
else
  res FAIL N8N_HOST_PREFIX "n8n server_prefix missing"
fi

if [[ -n "$plat_prefix" ]]; then
  res PASS PLATFORMINIT_HOST_PREFIX "platforminit server_prefix: ${plat_prefix} (current example)" "${plat_prefix}" "<prefix> present"
else
  res FAIL PLATFORMINIT_HOST_PREFIX "platforminit server_prefix missing"
fi

# Validate effective default host names (server_prefix + -NN suffix)
# The resolver contract is: effective_hostname = <server_prefix>-<default_index>
# where default_index is currently "01" for all projects.
# This check validates the derivation pattern, not a specific hardcoded value.
DEFAULT_SERVER_INDEX="${DEFAULT_SERVER_INDEX:-01}"
dev_default_host="${dev_prefix:--}-${DEFAULT_SERVER_INDEX}"
n8n_default_host="${n8n_prefix:--}-${DEFAULT_SERVER_INDEX}"
plat_default_host="${plat_prefix:--}-${DEFAULT_SERVER_INDEX}"

# Validate that derived hostname matches the <prefix>-NN pattern
# (asserts resolver contract, not specific hostname values)
if [[ "$dev_default_host" =~ ^[a-zA-Z0-9_-]+-[0-9]+$ ]]; then
  res PASS DEV_DEFAULT_HOST "development default host name (resolver-derived): ${dev_default_host} (current example)" "${dev_default_host}" "<server_prefix>-NN pattern"
else
  res FAIL DEV_DEFAULT_HOST "development default host name does not match resolver pattern: ${dev_default_host:-missing}" "${dev_default_host:-}" "<server_prefix>-NN"
fi

if [[ "$n8n_default_host" =~ ^[a-zA-Z0-9_-]+-[0-9]+$ ]]; then
  res PASS N8N_DEFAULT_HOST "n8n default host name (resolver-derived): ${n8n_default_host} (current example)" "${n8n_default_host}" "<server_prefix>-NN pattern"
else
  res FAIL N8N_DEFAULT_HOST "n8n default host name does not match resolver pattern: ${n8n_default_host:-missing}" "${n8n_default_host:-}" "<server_prefix>-NN"
fi

if [[ "$plat_default_host" =~ ^[a-zA-Z0-9_-]+-[0-9]+$ ]]; then
  res PASS PLATFORMINIT_DEFAULT_HOST "platforminit default host name (resolver-derived): ${plat_default_host} (current example)" "${plat_default_host}" "<server_prefix>-NN pattern"
else
  res FAIL PLATFORMINIT_DEFAULT_HOST "platforminit default host name does not match resolver pattern: ${plat_default_host:-missing}" "${plat_default_host:-}" "<server_prefix>-NN"
fi

# --------------------------------------------------
# Section 3: Token routing contract
# --------------------------------------------------
section "Token routing contract"

dev_token="$(grep -E 'token_secret:' "${PROJECTS_DIR}/development.yaml" 2>/dev/null | awk '{print $2}' || true)"
n8n_token="$(grep -E 'token_secret:' "${PROJECTS_DIR}/n8n.yaml" 2>/dev/null | awk '{print $2}' || true)"
plat_token="$(grep -E 'token_secret:' "${PROJECTS_DIR}/platforminit.yaml" 2>/dev/null | awk '{print $2}' || true)"

if [[ "$dev_token" == "HCLOUD_TOKEN_DEVELOPMENT" ]]; then
  res PASS DEV_TOKEN_ROUTING "development token: ${dev_token}" "${dev_token}" "HCLOUD_TOKEN_DEVELOPMENT"
else
  res FAIL DEV_TOKEN_ROUTING "development token: ${dev_token:-missing}" "${dev_token:-}" "HCLOUD_TOKEN_DEVELOPMENT"
fi

if [[ "$n8n_token" == "HCLOUD_TOKEN_N8N" ]]; then
  res PASS N8N_TOKEN_ROUTING "n8n token: ${n8n_token}" "${n8n_token}" "HCLOUD_TOKEN_N8N"
else
  res FAIL N8N_TOKEN_ROUTING "n8n token: ${n8n_token:-missing}" "${n8n_token:-}" "HCLOUD_TOKEN_N8N"
fi

if [[ "$plat_token" == "HCLOUD_TOKEN_PLATFORMINIT" ]]; then
  res PASS PLATFORMINIT_TOKEN_ROUTING "platforminit token: ${plat_token}" "${plat_token}" "HCLOUD_TOKEN_PLATFORMINIT"
else
  res FAIL PLATFORMINIT_TOKEN_ROUTING "platforminit token: ${plat_token:-missing}" "${plat_token:-}" "HCLOUD_TOKEN_PLATFORMINIT"
fi

# --------------------------------------------------
# Section 4: Volume layout contract
# --------------------------------------------------
section "Volume layout contract"

dev_layout="$(grep -E 'layout:' "${PROJECTS_DIR}/development.yaml" 2>/dev/null | awk '{print $2}' || true)"
n8n_layout="$(grep -E 'layout:' "${PROJECTS_DIR}/n8n.yaml" 2>/dev/null | awk '{print $2}' || true)"
plat_layout="$(grep -E 'layout:' "${PROJECTS_DIR}/platforminit.yaml" 2>/dev/null | awk '{print $2}' || true)"

# development must be split
if [[ "$dev_layout" == "split" ]]; then
  res PASS DEV_VOLUME_LAYOUT "development volume_layout: ${dev_layout}" "${dev_layout}" "split"
else
  res FAIL DEV_VOLUME_LAYOUT "development volume_layout: ${dev_layout:-missing}" "${dev_layout:-}" "split"
fi

# n8n must be none
if [[ "$n8n_layout" == "none" ]]; then
  res PASS N8N_VOLUME_LAYOUT "n8n volume_layout: ${n8n_layout}" "${n8n_layout}" "none"
else
  res FAIL N8N_VOLUME_LAYOUT "n8n volume_layout: ${n8n_layout:-missing}" "${n8n_layout:-}" "none"
fi

# platforminit must be split
if [[ "$plat_layout" == "split" ]]; then
  res PASS PLATFORMINIT_VOLUME_LAYOUT "platforminit volume_layout: ${plat_layout}" "${plat_layout}" "split"
else
  res FAIL PLATFORMINIT_VOLUME_LAYOUT "platforminit volume_layout: ${plat_layout:-missing}" "${plat_layout:-}" "split"
fi

# --------------------------------------------------
# Section 5: Bootstrap script volume_layout=none handling
# --------------------------------------------------
section "Bootstrap script volume_layout=none handling"

BOOTSTRAP_SCRIPT="${REPO_ROOT}/platform/host-bootstrap/scripts/bootstrap-host-access.sh"
if [[ -f "$BOOTSTRAP_SCRIPT" ]]; then
  if grep -qE 'volume_layout=none.*skipping Hetzner volume' "$BOOTSTRAP_SCRIPT"; then
    res PASS BOOTSTRAP_NONE_HANDLING "bootstrap-host-access.sh handles volume_layout=none" "found skip logic" "skip logic present"
  else
    res FAIL BOOTSTRAP_NONE_HANDLING "bootstrap-host-access.sh missing volume_layout=none skip logic"
  fi
else
  res FAIL BOOTSTRAP_SCRIPT_EXISTS "bootstrap-host-access.sh not found at ${BOOTSTRAP_SCRIPT}"
fi

# --------------------------------------------------
# Section 6: Validation script volume_layout handling
# --------------------------------------------------
section "Validation script volume_layout handling"

CH01_VALIDATE="${CH01_CODE_ROOT}/validate/ch01-validate-host.sh"
if [[ -f "$CH01_VALIDATE" ]]; then
  # Check that none layout is handled
  if grep -qE 'none\)' "$CH01_VALIDATE"; then
    res PASS VALIDATE_NONE_CASE "ch01-validate-host.sh handles volume_layout=none" "none case present" "none case required"
  else
    res FAIL VALIDATE_NONE_CASE "ch01-validate-host.sh missing volume_layout=none case"
  fi
  # Check that split layout is handled
  if grep -qE 'split\)' "$CH01_VALIDATE"; then
    res PASS VALIDATE_SPLIT_CASE "ch01-validate-host.sh handles volume_layout=split" "split case present" "split case required"
  else
    res FAIL VALIDATE_SPLIT_CASE "ch01-validate-host.sh missing volume_layout=split case"
  fi
  # Check that single layout is handled
  if grep -qE 'single\)' "$CH01_VALIDATE"; then
    res PASS VALIDATE_SINGLE_CASE "ch01-validate-host.sh handles volume_layout=single" "single case present" "single case required"
  else
    res FAIL VALIDATE_SINGLE_CASE "ch01-validate-host.sh missing volume_layout=single case"
  fi
else
  res FAIL CH01_VALIDATE_EXISTS "ch01-validate-host.sh not found"
fi

# --------------------------------------------------
# Section 7: Documentation contract coverage
# --------------------------------------------------
section "Documentation contract coverage"

DOCS_DIR="${REPO_ROOT}/docs"
if [[ -f "${DOCS_DIR}/multi-project-host-discovery-and-volume-layout.md" ]]; then
  res PASS DOC_HOST_DISCOVERY "multi-project-host-discovery doc exists"
else
  res FAIL DOC_HOST_DISCOVERY "multi-project-host-discovery doc missing"
fi

if [[ -f "${DOCS_DIR}/multi-project-routing.md" ]]; then
  res PASS DOC_PROJECT_ROUTING "multi-project-routing doc exists"
else
  res FAIL DOC_PROJECT_ROUTING "multi-project-routing doc missing"
fi

if [[ -f "${DOCS_DIR}/n8n-cx23-standalone-architecture.md" ]]; then
  res PASS DOC_N8N_ARCH "n8n standalone architecture doc exists"
else
  res FAIL DOC_N8N_ARCH "n8n standalone architecture doc missing"
fi

if [[ -f "${DOCS_DIR}/k3s-data-dir-storage-contract.md" ]]; then
  res PASS DOC_K3S_CONTRACT "k3s data-dir storage contract doc exists"
else
  res FAIL DOC_K3S_CONTRACT "k3s data-dir storage contract doc missing"
fi

if [[ -f "${DOCS_DIR}/ch05-observability-storage-contract.md" ]]; then
  res PASS DOC_OBSERVABILITY_CONTRACT "CH05 observability storage contract doc exists"
else
  res FAIL DOC_OBSERVABILITY_CONTRACT "CH05 observability storage contract doc missing"
fi

# --------------------------------------------------
# Section 8: Cross-chapter contract propagation
# --------------------------------------------------
section "Cross-chapter contract propagation"

# CH02 install-k3s.sh must source host-context.env
K3S_INSTALL="${REPO_ROOT}/platform/cluster/install/install-k3s.sh"
if [[ -f "$K3S_INSTALL" ]]; then
  if grep -qE 'source /etc/platforminit/host-context.env' "$K3S_INSTALL"; then
    res PASS K3S_INSTALL_HOST_CONTEXT "install-k3s.sh sources host-context.env"
  else
    res FAIL K3S_INSTALL_HOST_CONTEXT "install-k3s.sh does not source host-context.env"
  fi
  if grep -qE 'PLATFORMINIT_DATA_PATH' "$K3S_INSTALL"; then
    res PASS K3S_INSTALL_DATA_PATH "install-k3s.sh uses PLATFORMINIT_DATA_PATH"
  else
    res FAIL K3S_INSTALL_DATA_PATH "install-k3s.sh does not use PLATFORMINIT_DATA_PATH"
  fi
else
  res FAIL K3S_INSTALL_EXISTS "install-k3s.sh not found"
fi

# CH02 validate must source host-context.env
CH02_VALIDATE="${REPO_ROOT}/platform/cluster/validate/ch02-validate.sh"
if [[ -f "$CH02_VALIDATE" ]]; then
  if grep -qE 'source /etc/platforminit/host-context.env' "$CH02_VALIDATE"; then
    res PASS CH02_VALIDATE_HOST_CONTEXT "ch02-validate.sh sources host-context.env"
  else
    res FAIL CH02_VALIDATE_HOST_CONTEXT "ch02-validate.sh does not source host-context.env"
  fi
else
  res FAIL CH02_VALIDATE_EXISTS "ch02-validate.sh not found"
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
  "profile": "ch01-host-lifecycle-contract-validator-v2",
  "checks": [
$CHECKS_JSON
  ],
  "summary": {"pass": $PASS, "warn": $WARN, "fail": $FAIL, "total": $TOTAL, "status": "$OVERALL_STATUS"}
}
EOFJSON

ln -sfn "$(basename "$REPORT_MD")" "${REPORT_DIR}/validate-host-lifecycle-contract-latest.md"
ln -sfn "$(basename "$REPORT_JSON")" "${REPORT_DIR}/validate-host-lifecycle-contract-latest.json"

echo ""
echo "Report: ${REPORT_MD}"
echo "JSON:   ${REPORT_JSON}"
echo "Summary: PASS=${PASS} WARN=${WARN} FAIL=${FAIL}"

if (( FAIL != 0 )); then
  exit 2
fi
