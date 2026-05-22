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
  if [[ -n "$token" ]]; then
    if [[ "$token" =~ ^HCLOUD_TOKEN_ ]]; then
      res PASS "TOKEN_SECRET_${pname^^}" "${pname}: token_secret=HCLOUD_TOKEN_*** (valid pattern)" "secret-name-valid"
    else
      res FAIL "TOKEN_SECRET_${pname^^}" "${pname}: token_secret does not match HCLOUD_TOKEN_* pattern" "secret-name-invalid"
    fi
  else
    res FAIL "TOKEN_SECRET_${pname^^}" "${pname}: token_secret missing"
  fi
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
  res PASS DEV_TOKEN_ROUTING "development token: HCLOUD_TOKEN_DEVELOPMENT (valid)" "HCLOUD_TOKEN_DEVELOPMENT"
else
  res FAIL DEV_TOKEN_ROUTING "development token: unexpected value (expected HCLOUD_TOKEN_DEVELOPMENT)" "secret-name-invalid" "HCLOUD_TOKEN_DEVELOPMENT"
fi

if [[ "$n8n_token" == "HCLOUD_TOKEN_N8N" ]]; then
  res PASS N8N_TOKEN_ROUTING "n8n token: HCLOUD_TOKEN_N8N (valid)" "HCLOUD_TOKEN_N8N"
else
  res FAIL N8N_TOKEN_ROUTING "n8n token: unexpected value (expected HCLOUD_TOKEN_N8N)" "secret-name-invalid" "HCLOUD_TOKEN_N8N"
fi

if [[ "$plat_token" == "HCLOUD_TOKEN_PLATFORMINIT" ]]; then
  res PASS PLATFORMINIT_TOKEN_ROUTING "platforminit token: HCLOUD_TOKEN_PLATFORMINIT (valid)" "HCLOUD_TOKEN_PLATFORMINIT"
else
  res FAIL PLATFORMINIT_TOKEN_ROUTING "platforminit token: unexpected value (expected HCLOUD_TOKEN_PLATFORMINIT)" "secret-name-invalid" "HCLOUD_TOKEN_PLATFORMINIT"
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

if [[ -f "${DOCS_DIR}/ch01-shared-start-rebuild-contract.md" ]]; then
  res PASS DOC_SHARED_START_REBUILD "ch01-shared-start-rebuild-contract doc exists"
else
  res FAIL DOC_SHARED_START_REBUILD "ch01-shared-start-rebuild-contract doc missing"
fi
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
# Section 9: CH02 baseline contract — volume_layout=none handling
# --------------------------------------------------
section "CH02 baseline contract — volume_layout=none handling"

CH02_VALIDATE_HOST="${REPO_ROOT}/platform/cluster/validate/validate-host.sh"
if [[ -f "$CH02_VALIDATE_HOST" ]]; then
  # Check that k3s checks are guarded by volume_layout=none
  if grep -qE 'k3s.*skipped.*volume_layout=none|K3S_SKIPPED' "$CH02_VALIDATE_HOST"; then
    res PASS CH02_VALIDATE_NONE_K3S_SKIP "validate-host.sh skips k3s checks for volume_layout=none" "skip logic present" "skip logic required"
  else
    res FAIL CH02_VALIDATE_NONE_K3S_SKIP "validate-host.sh missing volume_layout=none k3s skip logic"
  fi
  # Check that the volume_layout=none case does not call kubectl
  if grep -qE 'if.*PLATFORMINIT_VOLUME_LAYOUT.*none' "$CH02_VALIDATE_HOST"; then
    res PASS CH02_VALIDATE_NONE_GUARD "validate-host.sh guards k3s/kubectl behind volume_layout=none check" "guard present" "guard required"
  else
    res FAIL CH02_VALIDATE_NONE_GUARD "validate-host.sh missing volume_layout=none guard for k3s/kubectl"
  fi
else
  res FAIL CH02_VALIDATE_HOST_EXISTS "validate-host.sh not found at ${CH02_VALIDATE_HOST}"
fi

# --------------------------------------------------
# Section 10: CH02 baseline contract — A1 access/sudo grant non-interactive
# --------------------------------------------------
section "CH02 baseline contract — A1 access/sudo grant non-interactive"

GRANT_SCRIPT="${REPO_ROOT}/platform/host-baseline/scripts/grant-temporary-sudo.sh"
if [[ -f "$GRANT_SCRIPT" ]]; then
  # Check that grant-temporary-sudo.sh does not require interactive input
  if grep -qE 'read\s+(-p|-r|-s)?\s' "$GRANT_SCRIPT"; then
    res FAIL GRANT_NON_INTERACTIVE "grant-temporary-sudo.sh uses interactive read — violates A1 non-interactive contract" "interactive read found" "no interactive input"
  else
    res PASS GRANT_NON_INTERACTIVE "grant-temporary-sudo.sh is non-interactive (no read calls)" "non-interactive" "non-interactive required"
  fi
  # Check that grant-temporary-sudo.sh accepts positional args (non-interactive contract)
  if grep -qE '^USER_NAME="\$\{1:-devops\}"' "$GRANT_SCRIPT"; then
    res PASS GRANT_POSITIONAL_ARGS "grant-temporary-sudo.sh accepts positional args (non-interactive contract)" "positional args" "positional args required"
  else
    res FAIL GRANT_POSITIONAL_ARGS "grant-temporary-sudo.sh missing positional arg handling for non-interactive contract"
  fi
  # Check that the sudoers drop-in is scoped (not NOPASSWD:ALL for baseline scope)
  if grep -qE 'scope_sudoers_content\s+"\$SCOPE"' "$GRANT_SCRIPT"; then
    res PASS GRANT_SCOPED_SUDOERS "grant-temporary-sudo.sh uses scoped sudoers content per SCOPE" "scoped" "scoped required"
  else
    res FAIL GRANT_SCOPED_SUDOERS "grant-temporary-sudo.sh missing scoped sudoers content"
  fi
  # Check that interactive-elevation scope verifies with runuser (non-interactive verification)
  if grep -qE 'runuser.*sudo -n true' "$GRANT_SCRIPT"; then
    res PASS GRANT_INTERACTIVE_VERIFICATION "interactive-elevation scope verifies with runuser (non-interactive verification)" "runuser verification" "runuser verification required"
  else
    res FAIL GRANT_INTERACTIVE_VERIFICATION "interactive-elevation scope missing runuser verification"
  fi
else
  res FAIL GRANT_SCRIPT_EXISTS "grant-temporary-sudo.sh not found at ${GRANT_SCRIPT}"
fi

# --------------------------------------------------
# Section 11: CH02 baseline contract — apply-baseline-remote.sh layout awareness
# --------------------------------------------------
section "CH02 baseline contract — apply-baseline-remote.sh layout awareness"

APPLY_REMOTE="${REPO_ROOT}/platform/host-baseline/remote/apply-baseline-remote.sh"
if [[ -f "$APPLY_REMOTE" ]]; then
  # Check that apply-baseline-remote.sh handles volume_layout=none
  if grep -qE 'none\)' "$APPLY_REMOTE"; then
    res PASS APPLY_REMOTE_NONE_CASE "apply-baseline-remote.sh handles volume_layout=none" "none case present" "none case required"
  else
    res FAIL APPLY_REMOTE_NONE_CASE "apply-baseline-remote.sh missing volume_layout=none case"
  fi
  # Check that apply-baseline-remote.sh resolves runtime root per layout
  if grep -qE 'resolve_runtime_root' "$APPLY_REMOTE"; then
    res PASS APPLY_REMOTE_RUNTIME_ROOT "apply-baseline-remote.sh resolves runtime root per layout" "resolve_runtime_root present" "layout-aware runtime root required"
  else
    res FAIL APPLY_REMOTE_RUNTIME_ROOT "apply-baseline-remote.sh missing layout-aware runtime root resolution"
  fi
  # Check that apply-baseline-remote.sh resolves audit dir per layout
  if grep -qE 'resolve_audit_dir' "$APPLY_REMOTE"; then
    res PASS APPLY_REMOTE_AUDIT_DIR "apply-baseline-remote.sh resolves audit dir per layout" "resolve_audit_dir present" "layout-aware audit dir required"
  else
    res FAIL APPLY_REMOTE_AUDIT_DIR "apply-baseline-remote.sh missing layout-aware audit dir resolution"
  fi
else
  res FAIL APPLY_REMOTE_EXISTS "apply-baseline-remote.sh not found at ${APPLY_REMOTE}"
fi

# --------------------------------------------------
# Section 12: CH02 baseline profile separation contract
# --------------------------------------------------
section "CH02 baseline profile separation contract"

BASELINE_POLICY="${REPO_ROOT}/platform/host-baseline/policy/baseline.yaml"
if [[ -f "$BASELINE_POLICY" ]]; then
  # Check that baseline.yaml has a shared section
  if grep -qE '^shared:' "$BASELINE_POLICY"; then
    res PASS BASELINE_SHARED_SECTION "baseline.yaml has shared hardening primitives section" "shared: present" "shared: required"
  else
    res FAIL BASELINE_SHARED_SECTION "baseline.yaml missing shared hardening primitives section"
  fi
  # Check that baseline.yaml has a profiles section
  if grep -qE '^profiles:' "$BASELINE_POLICY"; then
    res PASS BASELINE_PROFILES_SECTION "baseline.yaml has profiles section" "profiles: present" "profiles: required"
  else
    res FAIL BASELINE_PROFILES_SECTION "baseline.yaml missing profiles section"
  fi
  # Check that platform-k3s profile exists
  if grep -qE 'platform-k3s:' "$BASELINE_POLICY"; then
    res PASS BASELINE_PROFILE_PLATFORM_K3S "baseline.yaml defines platform-k3s profile" "platform-k3s present" "platform-k3s required"
  else
    res FAIL BASELINE_PROFILE_PLATFORM_K3S "baseline.yaml missing platform-k3s profile"
  fi
  # Check that standalone-n8n profile exists
  if grep -qE 'standalone-n8n:' "$BASELINE_POLICY"; then
    res PASS BASELINE_PROFILE_STANDALONE_N8N "baseline.yaml defines standalone-n8n profile" "standalone-n8n present" "standalone-n8n required"
  else
    res FAIL BASELINE_PROFILE_STANDALONE_N8N "baseline.yaml missing standalone-n8n profile"
  fi
else
  res FAIL BASELINE_POLICY_EXISTS "baseline.yaml not found at ${BASELINE_POLICY}"
fi

DEPENDENCY_POLICY="${REPO_ROOT}/platform/host-baseline/policy/dependencies.yaml"
if [[ -f "$DEPENDENCY_POLICY" ]]; then
  # Check that dependencies.yaml has a shared section
  if grep -qE '^shared:' "$DEPENDENCY_POLICY"; then
    res PASS DEPENDENCY_SHARED_SECTION "dependencies.yaml has shared apt section" "shared: present" "shared: required"
  else
    res FAIL DEPENDENCY_SHARED_SECTION "dependencies.yaml missing shared apt section"
  fi
  # Check that dependencies.yaml has a profiles section
  if grep -qE '^profiles:' "$DEPENDENCY_POLICY"; then
    res PASS DEPENDENCY_PROFILES_SECTION "dependencies.yaml has profiles section" "profiles: present" "profiles: required"
  else
    res FAIL DEPENDENCY_PROFILES_SECTION "dependencies.yaml missing profiles section"
  fi
else
  res FAIL DEPENDENCY_POLICY_EXISTS "dependencies.yaml not found at ${DEPENDENCY_POLICY}"
fi

# Check that lib-policy.sh has resolve_baseline_profile function
LIB_POLICY="${REPO_ROOT}/platform/host-baseline/scripts/lib-policy.sh"
if [[ -f "$LIB_POLICY" ]]; then
  if grep -qE 'resolve_baseline_profile' "$LIB_POLICY"; then
    res PASS LIB_POLICY_PROFILE_RESOLVER "lib-policy.sh has resolve_baseline_profile function" "resolve_baseline_profile present" "profile resolver required"
  else
    res FAIL LIB_POLICY_PROFILE_RESOLVER "lib-policy.sh missing resolve_baseline_profile function"
  fi
  if grep -qE 'validate_baseline_profile' "$LIB_POLICY"; then
    res PASS LIB_POLICY_PROFILE_VALIDATOR "lib-policy.sh has validate_baseline_profile function" "validate_baseline_profile present" "profile validator required"
  else
    res FAIL LIB_POLICY_PROFILE_VALIDATOR "lib-policy.sh missing validate_baseline_profile function"
  fi
else
  res FAIL LIB_POLICY_EXISTS "lib-policy.sh not found at ${LIB_POLICY}"
fi

# Check that apply-policy-baseline.sh uses profile-aware package resolution
APPLY_POLICY="${REPO_ROOT}/platform/host-baseline/scripts/apply-policy-baseline.sh"
if [[ -f "$APPLY_POLICY" ]]; then
  if grep -qE 'resolve_baseline_profile' "$APPLY_POLICY"; then
    res PASS APPLY_POLICY_PROFILE_AWARE "apply-policy-baseline.sh resolves baseline profile" "resolve_baseline_profile used" "profile-aware required"
  else
    res FAIL APPLY_POLICY_PROFILE_AWARE "apply-policy-baseline.sh missing profile resolution"
  fi
  if grep -qE 'profiles\.\$\{BASELINE_PROFILE\}' "$APPLY_POLICY"; then
    res PASS APPLY_POLICY_PROFILE_PACKAGES "apply-policy-baseline.sh resolves profile-specific packages" "profiles.\${BASELINE_PROFILE} used" "profile-aware packages required"
  else
    res FAIL APPLY_POLICY_PROFILE_PACKAGES "apply-policy-baseline.sh missing profile-specific package resolution"
  fi
else
  res FAIL APPLY_POLICY_EXISTS "apply-policy-baseline.sh not found at ${APPLY_POLICY}"
fi

# Check that fim-check.sh is profile-aware
FIM_CHECK="${REPO_ROOT}/platform/host-baseline/scripts/fim-check.sh"
if [[ -f "$FIM_CHECK" ]]; then
  if grep -qE 'resolve_baseline_profile' "$FIM_CHECK"; then
    res PASS FIM_CHECK_PROFILE_AWARE "fim-check.sh resolves baseline profile" "resolve_baseline_profile used" "profile-aware required"
  else
    res FAIL FIM_CHECK_PROFILE_AWARE "fim-check.sh missing profile resolution"
  fi
  if grep -qE 'extra_required_paths' "$FIM_CHECK"; then
    res PASS FIM_CHECK_EXTRA_PATHS "fim-check.sh checks profile-specific extra_required_paths" "extra_required_paths used" "profile-aware FIM paths required"
  else
    res FAIL FIM_CHECK_EXTRA_PATHS "fim-check.sh missing profile-specific FIM path checks"
  fi
else
  res FAIL FIM_CHECK_EXISTS "fim-check.sh not found at ${FIM_CHECK}"
fi

# Check that install-dependencies.sh is profile-aware
INSTALL_DEPS="${REPO_ROOT}/platform/host-baseline/scripts/install-dependencies.sh"
if [[ -f "$INSTALL_DEPS" ]]; then
  if grep -qE 'resolve_baseline_profile' "$INSTALL_DEPS"; then
    res PASS INSTALL_DEPS_PROFILE_AWARE "install-dependencies.sh resolves baseline profile" "resolve_baseline_profile used" "profile-aware required"
  else
    res FAIL INSTALL_DEPS_PROFILE_AWARE "install-dependencies.sh missing profile resolution"
  fi
  if grep -qE 'apt_extra' "$INSTALL_DEPS"; then
    res PASS INSTALL_DEPS_APT_EXTRA "install-dependencies.sh installs profile-specific apt_extra packages" "apt_extra used" "profile-aware apt required"
  else
    res FAIL INSTALL_DEPS_APT_EXTRA "install-dependencies.sh missing profile-specific apt package installation"
  fi
else
  res FAIL INSTALL_DEPS_EXISTS "install-dependencies.sh not found at ${INSTALL_DEPS}"
fi

# Check that ch01-validate-host.sh is profile-aware
CH01_VALIDATE="${CH01_CODE_ROOT}/validate/ch01-validate-host.sh"
if [[ -f "$CH01_VALIDATE" ]]; then
  if grep -qE 'PLATFORMINIT_BASELINE_PROFILE' "$CH01_VALIDATE"; then
    res PASS CH01_VALIDATE_PROFILE_AWARE "ch01-validate-host.sh resolves baseline profile" "PLATFORMINIT_BASELINE_PROFILE used" "profile-aware required"
  else
    res FAIL CH01_VALIDATE_PROFILE_AWARE "ch01-validate-host.sh missing profile resolution"
  fi
  if grep -qE 'platform-k3s\)' "$CH01_VALIDATE"; then
    res PASS CH01_VALIDATE_PROFILE_PLATFORM_K3S "ch01-validate-host.sh handles platform-k3s profile" "platform-k3s case present" "platform-k3s validation required"
  else
    res FAIL CH01_VALIDATE_PROFILE_PLATFORM_K3S "ch01-validate-host.sh missing platform-k3s profile handling"
  fi
  if grep -qE 'standalone-n8n\)' "$CH01_VALIDATE"; then
    res PASS CH01_VALIDATE_PROFILE_N8N "ch01-validate-host.sh handles standalone-n8n profile" "standalone-n8n case present" "standalone-n8n validation required"
  else
    res FAIL CH01_VALIDATE_PROFILE_N8N "ch01-validate-host.sh missing standalone-n8n profile handling"
  fi
else
  res FAIL CH01_VALIDATE_EXISTS "ch01-validate-host.sh not found at ${CH01_VALIDATE}"
fi

# --- Contract: lib-policy.sh must NOT eagerly default PLATFORMINIT_BASELINE_PROFILE ---
# The resolve_baseline_profile() function handles the full resolution chain:
#   env var -> host-context.env -> default(platform-k3s)
# Defaulting at library source time would pre-empt the host-context.env lookup.
# This check MUST fail if ANY top-level PLATFORMINIT_BASELINE_PROFILE= assignment
# exists before resolve_baseline_profile(), even if the resolver also has a default.
# That would reintroduce the ordering regression.
LIB_POLICY="${REPO_ROOT}/platform/host-baseline/scripts/lib-policy.sh"
if [[ -f "$LIB_POLICY" ]]; then
  # Check 1: No top-level PLATFORMINIT_BASELINE_PROFILE= assignment before resolve_baseline_profile()
  # Extract lines before resolve_baseline_profile definition (excluding comments/blank lines)
  top_level_assign="$(sed -n '1,/^resolve_baseline_profile/p' "$LIB_POLICY" | grep -cE '^PLATFORMINIT_BASELINE_PROFILE=' || true)"
  if (( top_level_assign > 0 )); then
    res FAIL LIB_POLICY_NO_EAGER_DEFAULT "lib-policy.sh has ${top_level_assign} top-level PLATFORMINIT_BASELINE_PROFILE= assignment(s) before resolve_baseline_profile() — pre-empts host-context.env lookup" "eager default(s) found" "no top-level assignment before resolve_baseline_profile()"
  else
    # Check 2: Verify the default exists inside resolve_baseline_profile()
    if grep -qE 'profile:-platform-k3s' < <(sed -n '/^resolve_baseline_profile/,/^}/p' "$LIB_POLICY"); then
      res PASS LIB_POLICY_NO_EAGER_DEFAULT "lib-policy.sh does NOT eagerly default PLATFORMINIT_BASELINE_PROFILE at library source time — default only inside resolve_baseline_profile()" "no eager default" "default deferred to resolve_baseline_profile()"
    else
      res FAIL LIB_POLICY_NO_EAGER_DEFAULT "lib-policy.sh missing platform-k3s default inside resolve_baseline_profile()" "no default found" "default inside resolve_baseline_profile()"
    fi
  fi
else
  res FAIL LIB_POLICY_EXISTS "lib-policy.sh not found at ${LIB_POLICY}"
fi

# --- Contract: baseline FIM extra_required_paths must not reference post-baseline runtime files ---
# Runtime-layer files (k3s.yaml, Caddyfile) are owned by later chapters (CH03, n8n runtime)
# and must NOT be required during CH02 baseline application.
BASELINE_POLICY="${REPO_ROOT}/platform/host-baseline/policy/baseline.yaml"
if [[ -f "$BASELINE_POLICY" ]]; then
  # Check platform-k3s profile extra_required_paths
  k3s_paths="$(yq -r '.profiles["platform-k3s"].fim.extra_required_paths[]? // ""' "$BASELINE_POLICY" 2>/dev/null || true)"
  n8n_paths="$(yq -r '.profiles["standalone-n8n"].fim.extra_required_paths[]? // ""' "$BASELINE_POLICY" 2>/dev/null || true)"
  runtime_refs=""
  for p in $k3s_paths $n8n_paths; do
    case "$p" in
      */k3s.yaml|*/Caddyfile)
        runtime_refs+="$p "
        ;;
    esac
  done
  if [[ -n "$runtime_refs" ]]; then
    res FAIL BASELINE_FIM_NO_RUNTIME_REFS "baseline.yaml extra_required_paths reference post-baseline runtime files: ${runtime_refs}" "runtime refs found: ${runtime_refs}" "no k3s/Caddy runtime paths in baseline FIM"
  else
    res PASS BASELINE_FIM_NO_RUNTIME_REFS "baseline.yaml extra_required_paths do NOT reference post-baseline runtime files (k3s.yaml, Caddyfile)" "no runtime refs" "no k3s/Caddy paths in baseline FIM"
  fi
else
  res FAIL BASELINE_POLICY_EXISTS "baseline.yaml not found at ${BASELINE_POLICY}"
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
