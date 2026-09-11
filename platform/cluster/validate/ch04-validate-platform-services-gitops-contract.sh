#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - platform services GitOps contract validation (repository-only)
#
# Validates the committed contract without touching any cluster:
#   - Traefik LoadBalancer exposure is declared for ports 80/443 and the live
#     validator requires a bound IP or hostname
#   - cert-manager Cloudflare DNS-01 issuers are declared and a guarded,
#     bounded staging-issuance smoke procedure exists
#   - Argo CD can bootstrap itself on a fresh cluster (no AppProject
#     dependency cycle), owns the platform-services ApplicationSet, and its
#     GitOps repo/revision are deployment inputs with lab-safe defaults
#   - every component has a validation script
#   - no plaintext secret material is committed
#
# Safe to run anywhere (CI, laptop, host). Aggregates all findings before
# exiting non-zero.
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-contract] $*"; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-contract][FAIL] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

CLUSTER_DIR="${ROOT_DIR}/platform/cluster"
TRAEFIK_CFG="${CLUSTER_DIR}/manifests/traefik/traefik-helmchartconfig.yaml"
CM_ISSUERS="${CLUSTER_DIR}/addons/cert-manager/clusterissuer-letsencrypt-cloudflare.yaml"
CM_INSTALL="${CLUSTER_DIR}/addons/cert-manager/install-cert-manager.sh"
CM_SMOKE_MANIFEST="${CLUSTER_DIR}/addons/cert-manager/smoke/demo-cert-smoke.yaml"
ARGO_BOOTSTRAP="${CLUSTER_DIR}/addons/argocd/bootstrap-argocd.sh"
ARGO_PROJECT="${CLUSTER_DIR}/manifests/argocd/appproject-platform-services.yaml"
ARGO_APPSET="${CLUSTER_DIR}/manifests/argocd/applicationset-platform-services.yaml"
ARGO_SELF_APP="${CLUSTER_DIR}/manifests/argocd/application-argocd-self.yaml"
TRAEFIK_VALIDATOR="${CLUSTER_DIR}/validate/ch04-validate-traefik-exposure.sh"
CM_VALIDATOR="${CLUSTER_DIR}/validate/ch04-validate-cert-manager-dns01.sh"
ARGO_VALIDATOR="${CLUSTER_DIR}/validate/ch04-validate-argocd-bootstrap.sh"
SMOKE_VALIDATOR="${CLUSTER_DIR}/validate/ch04-smoke-staging-certificate.sh"

# Documentation that must stay consistent with the enforced contract.
CONTRACT_DOC="${ROOT_DIR}/docs/ch04-platform-services-gitops-contract.md"
ARGO_README="${CLUSTER_DIR}/addons/argocd/README.md"
CM_README="${CLUSTER_DIR}/addons/cert-manager/README.md"
CLUSTER_README="${CLUSTER_DIR}/README.md"

# GitOps source defaults that must stay consistent across the manifest and the
# bootstrap script (single source of truth for the roo-lab boundary).
LAB_REPO_URL="https://github.com/platforminit/platforminit-roo-lab.git"
STABLE_REPO_URL="https://github.com/platforminit/platforminit-platform.git"

PASS=0
FAIL=0
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-contract][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

require_file() {
  if [[ -f "$1" ]]; then
    pass "file present: ${1#"${ROOT_DIR}/"}"
    return 0
  fi
  fail "file missing: ${1#"${ROOT_DIR}/"}"
  return 1
}

# First YAML scalar for a top-level-ish key (quotes stripped).
first_scalar() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 0
  grep -E "^[[:space:]]*${key}:" "${file}" 2>/dev/null \
    | head -n1 \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" \
    | tr -d '"' \
    | tr -d "'"
}

# First shell assignment value for a NAME=... line (quotes stripped).
shell_default() {
  local file="$1" name="$2"
  [[ -f "${file}" ]] || return 0
  grep -E "^${name}=" "${file}" 2>/dev/null \
    | head -n1 \
    | sed -E 's/^[^=]+=//' \
    | tr -d '"' \
    | tr -d "'"
}

# First 1-based line number matching an extended regex (0 when absent).
line_of() {
  local file="$1" pattern="$2" line=""
  [[ -f "${file}" ]] || { printf '0'; return 0; }
  line="$(grep -nE "${pattern}" "${file}" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
  printf '%s' "${line:-0}"
}

# "group/kind" pair per YAML document in a manifest file. Used to prove that
# every kind Argo CD actually syncs is explicitly allowed by the AppProject.
yaml_doc_pairs() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '
    /^---[[:space:]]*$/ { api = ""; next }
    /^[[:space:]]*apiVersion:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*apiVersion:[[:space:]]*/, "", line)
      gsub(/"/, "", line); gsub(/\047/, "", line)
      api = line
      next
    }
    /^[[:space:]]*kind:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]*kind:[[:space:]]*/, "", line)
      gsub(/"/, "", line); gsub(/\047/, "", line)
      if (api ~ /\//) { split(api, parts, "/"); print parts[1] "/" line } else { print "core/" line }
      api = ""
    }
  ' "${file}"
}

# Explicit "group/kind" allowlist pairs declared by the AppProject whitelists.
project_resource_pairs() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      if (line ~ /^[[:space:]]*(clusterResourceWhitelist|namespaceResourceWhitelist):/) {
        inlist = 1; grp = ""; list_indent = 0
        match(line, /^[[:space:]]*/); list_indent = RLENGTH
        next
      }
      if (inlist && line ~ /^[[:space:]]*[A-Za-z]/ && line !~ /^[[:space:]]*-[[:space:]]/) {
        match(line, /^[[:space:]]*/)
        if (RLENGTH <= list_indent) { inlist = 0; next }
      }
      if (!inlist) { next }
      if (line ~ /^[[:space:]]*-[[:space:]]/) { grp = "" }
      if (line ~ /^[[:space:]]*-?[[:space:]]*group:[[:space:]]*/) {
        grp = line
        sub(/^.*group:[[:space:]]*/, "", grp)
        gsub(/"/, "", grp); gsub(/\047/, "", grp)
        next
      }
      if (line ~ /^[[:space:]]*kind:[[:space:]]*/) {
        kind = line
        sub(/^.*kind:[[:space:]]*/, "", kind)
        gsub(/"/, "", kind); gsub(/\047/, "", kind)
        print grp "/" kind
      }
    }
  ' "${file}"
}

# Destination namespaces declared by the AppProject.
project_destinations() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      if (line ~ /^[[:space:]]*destinations:/) {
        inlist = 1; list_indent = 0
        match(line, /^[[:space:]]*/); list_indent = RLENGTH
        next
      }
      if (inlist && line ~ /^[[:space:]]*[A-Za-z]/ && line !~ /^[[:space:]]*-[[:space:]]/) {
        match(line, /^[[:space:]]*/)
        if (RLENGTH <= list_indent) { inlist = 0; next }
      }
      if (!inlist) { next }
      if (line ~ /^[[:space:]]*namespace:[[:space:]]*/) {
        ns = line
        sub(/^.*namespace:[[:space:]]*/, "", ns)
        gsub(/"/, "", ns); gsub(/\047/, "", ns)
        print ns
      }
    }
  ' "${file}"
}

log "=== CH04 platform services GitOps contract validation (repo: ${ROOT_DIR}) ==="

# --- Required artifacts ---
require_file "${TRAEFIK_CFG}"
require_file "${CM_ISSUERS}"
require_file "${CM_INSTALL}"
require_file "${CM_SMOKE_MANIFEST}"
require_file "${ARGO_BOOTSTRAP}"
require_file "${ARGO_PROJECT}"
require_file "${ARGO_APPSET}"
require_file "${ARGO_SELF_APP}"
require_file "${TRAEFIK_VALIDATOR}"
require_file "${CM_VALIDATOR}"
require_file "${ARGO_VALIDATOR}"
require_file "${SMOKE_VALIDATOR}"
require_file "${CONTRACT_DOC}"
require_file "${ARGO_README}"
require_file "${CM_README}"
require_file "${CLUSTER_README}"

# --- Traefik exposure contract ---
if [[ -f "${TRAEFIK_CFG}" ]]; then
  if grep -Eq '^[[:space:]]*type:[[:space:]]*LoadBalancer[[:space:]]*$' "${TRAEFIK_CFG}"; then
    pass "Traefik HelmChartConfig declares a LoadBalancer service"
  else
    fail "Traefik HelmChartConfig does not declare a LoadBalancer service"
  fi

  if grep -Eq '^[[:space:]]*(port|exposedPort):[[:space:]]*80[[:space:]]*$' "${TRAEFIK_CFG}" \
    && grep -Eq '^[[:space:]]*(port|exposedPort):[[:space:]]*443[[:space:]]*$' "${TRAEFIK_CFG}"; then
    pass "Traefik HelmChartConfig declares ports 80 and 443"
  else
    fail "Traefik HelmChartConfig does not declare ports 80 and 443"
  fi
fi

# --- Regression guard (review finding 4): a pending LoadBalancer must FAIL ---
if [[ -f "${TRAEFIK_VALIDATOR}" ]]; then
  if grep -q 'status.loadBalancer.ingress\[0\].ip' "${TRAEFIK_VALIDATOR}" \
    && grep -q 'status.loadBalancer.ingress\[0\].hostname' "${TRAEFIK_VALIDATOR}"; then
    pass "Traefik validator accepts either a LoadBalancer ip or hostname"
  else
    fail "Traefik validator does not check both status.loadBalancer.ingress[].ip and .hostname"
  fi

  if grep -q 'fail "LoadBalancer endpoint' "${TRAEFIK_VALIDATOR}" \
    && ! grep -q 'warn "LoadBalancer VIP not bound' "${TRAEFIK_VALIDATOR}"; then
    pass "Traefik validator fails (not warns) when no LoadBalancer endpoint is bound"
  else
    fail "Traefik validator still treats a missing LoadBalancer endpoint as a warning"
  fi

  if grep -q 'LB_WAIT_TIMEOUT' "${TRAEFIK_VALIDATOR}"; then
    pass "Traefik validator bounds the LoadBalancer endpoint wait (LB_WAIT_TIMEOUT)"
  else
    fail "Traefik validator does not bound the LoadBalancer endpoint wait"
  fi

  # Regression guard (review finding 3): LB_WAIT_TIMEOUT must be range-validated
  # before the first cluster call, so bad input fails as a clear message.
  if grep -q 'LB_WAIT_TIMEOUT_MIN' "${TRAEFIK_VALIDATOR}" \
    && grep -q 'LB_WAIT_TIMEOUT_MAX' "${TRAEFIK_VALIDATOR}"; then
    pass "Traefik validator enforces lower/upper LB_WAIT_TIMEOUT bounds"
  else
    fail "Traefik validator does not enforce lower/upper LB_WAIT_TIMEOUT bounds"
  fi

  LB_TIMEOUT_LINE="$(line_of "${TRAEFIK_VALIDATOR}" 'LB_WAIT_TIMEOUT_MAX')"
  LB_NODES_LINE="$(line_of "${TRAEFIK_VALIDATOR}" 'kubectl get nodes')"
  if [[ "${LB_TIMEOUT_LINE}" -gt 0 && "${LB_TIMEOUT_LINE}" -lt "${LB_NODES_LINE}" ]]; then
    pass "Traefik validator range-validates LB_WAIT_TIMEOUT before cluster access"
  else
    fail "Traefik validator does not range-validate LB_WAIT_TIMEOUT before cluster access (guard line ${LB_TIMEOUT_LINE}, cluster line ${LB_NODES_LINE})"
  fi
fi

# --- cert-manager DNS-01 contract ---
if [[ -f "${CM_ISSUERS}" ]]; then
  for issuer in letsencrypt-staging letsencrypt-prod; do
    if grep -Eq "^[[:space:]]*name:[[:space:]]*${issuer}[[:space:]]*$" "${CM_ISSUERS}"; then
      pass "ClusterIssuer ${issuer} declared"
    else
      fail "ClusterIssuer ${issuer} not declared"
    fi
  done

  if grep -Eq '^[[:space:]]*(-[[:space:]]+)?dns01:[[:space:]]*$' "${CM_ISSUERS}" \
    && grep -Eq '^[[:space:]]*cloudflare:[[:space:]]*$' "${CM_ISSUERS}"; then
    pass "ClusterIssuers use the Cloudflare dns01 solver"
  else
    fail "ClusterIssuers do not use the Cloudflare dns01 solver"
  fi

  if grep -Eq '^[[:space:]]*name:[[:space:]]*cloudflare-api-token-secret[[:space:]]*$' "${CM_ISSUERS}"; then
    pass "ClusterIssuers reference the cloudflare-api-token-secret secret"
  else
    fail "ClusterIssuers do not reference cloudflare-api-token-secret"
  fi
fi

# --- Regression guard (review finding 3): bounded staging issuance smoke ---
if [[ -f "${CM_VALIDATOR}" ]] && ! grep -q 'kubectl apply' "${CM_VALIDATOR}"; then
  pass "default cert-manager validator stays read-only (no resource creation)"
else
  fail "default cert-manager validator mutates cluster state; the issuance smoke check must be opt-in"
fi

if [[ -f "${SMOKE_VALIDATOR}" ]]; then
  if grep -q 'PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check requires an explicit acknowledgement guard"
  else
    fail "staging certificate smoke check lacks the PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE guard"
  fi

  if grep -q 'letsencrypt-staging' "${SMOKE_VALIDATOR}" \
    && ! grep -q 'letsencrypt-prod' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check is restricted to the staging issuer"
  else
    fail "staging certificate smoke check must use only the letsencrypt-staging issuer"
  fi

  if grep -q 'SMOKE_TIMEOUT' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check is bounded by SMOKE_TIMEOUT"
  else
    fail "staging certificate smoke check is not time-bounded"
  fi

  if grep -q '^trap cleanup EXIT$' "${SMOKE_VALIDATOR}" \
    && grep -q 'delete namespace' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check cleans up its temporary resources"
  else
    fail "staging certificate smoke check does not clean up its temporary resources"
  fi

  if grep -q 'orders.acme.cert-manager.io' "${SMOKE_VALIDATOR}" \
    && grep -q 'challenges.acme.cert-manager.io' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check reports Order/Challenge diagnostics on failure"
  else
    fail "staging certificate smoke check lacks Order/Challenge failure diagnostics"
  fi

  if ! grep -Eq -- '-o (json|yaml)( |$)' "${SMOKE_VALIDATOR}" \
    && ! grep -q 'get secret.*-o' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check never dumps Secret or raw resource data"
  else
    fail "staging certificate smoke check may print raw Secret/resource data"
  fi

  # Regression guard (review finding 2): exclusive run ownership and cleanup.
  if grep -q 'SMOKE_RUN_ID' "${SMOKE_VALIDATOR}" \
    && grep -q 'SMOKE_NAMESPACE_PREFIX' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check derives unique run-owned resource names"
  else
    fail "staging certificate smoke check does not derive unique run-owned resource names (SMOKE_RUN_ID / SMOKE_NAMESPACE_PREFIX)"
  fi

  # Regression guard: the smoke manifest must resolve inside platform/cluster,
  # otherwise the run-owned resources are never created at all.
  if grep -q 'addons/cert-manager/smoke/demo-cert-smoke.yaml' "${SMOKE_VALIDATOR}" \
    && ! grep -q '\.\./\.\./addons/' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check resolves the committed smoke manifest inside platform/cluster"
  else
    fail "staging certificate smoke check resolves the smoke manifest outside platform/cluster"
  fi

  if grep -q 'platforminit.io/smoke-run' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check labels its resources with the run id"
  else
    fail "staging certificate smoke check does not label its resources with the run id"
  fi

  if grep -q 'Refusing to reuse existing namespace' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check refuses pre-existing (possibly operator-owned) resources"
  else
    fail "staging certificate smoke check may adopt or overwrite pre-existing operator resources"
  fi

  if ! grep -q 'SMOKE_KEEP_RESOURCES' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check has no keep-resources bypass"
  else
    fail "staging certificate smoke check still ships a keep-resources bypass that can strand resources"
  fi

  if grep -q 'RUN_STARTED' "${SMOKE_VALIDATOR}" \
    && grep -q 'NAMESPACE_CREATED' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check cleans up only resources created by this run"
  else
    fail "staging certificate smoke check cleanup is not scoped to run-owned resources"
  fi

  # Regression guard (review finding 3): bounded smoke wait.
  if grep -q 'SMOKE_TIMEOUT_MIN' "${SMOKE_VALIDATOR}" \
    && grep -q 'SMOKE_TIMEOUT_MAX' "${SMOKE_VALIDATOR}"; then
    pass "staging certificate smoke check enforces lower/upper SMOKE_TIMEOUT bounds"
  else
    fail "staging certificate smoke check does not enforce lower/upper SMOKE_TIMEOUT bounds"
  fi

  SMOKE_TIMEOUT_LINE="$(line_of "${SMOKE_VALIDATOR}" 'SMOKE_TIMEOUT_MAX')"
  SMOKE_NODES_LINE="$(line_of "${SMOKE_VALIDATOR}" 'kubectl get nodes')"
  if [[ "${SMOKE_TIMEOUT_LINE}" -gt 0 && "${SMOKE_TIMEOUT_LINE}" -lt "${SMOKE_NODES_LINE}" ]]; then
    pass "staging certificate smoke check range-validates SMOKE_TIMEOUT before cluster access"
  else
    fail "staging certificate smoke check does not range-validate SMOKE_TIMEOUT before cluster access (guard line ${SMOKE_TIMEOUT_LINE}, cluster line ${SMOKE_NODES_LINE})"
  fi
fi

if [[ -f "${CM_SMOKE_MANIFEST}" ]]; then
  if grep -Eq '^[[:space:]]*name:[[:space:]]*letsencrypt-staging[[:space:]]*$' "${CM_SMOKE_MANIFEST}"; then
    pass "smoke manifest requests the letsencrypt-staging issuer"
  else
    fail "smoke manifest does not request the letsencrypt-staging issuer"
  fi

  if grep -q 'platforminit.io/purpose: cert-manager-smoke' "${CM_SMOKE_MANIFEST}"; then
    pass "smoke manifest is labelled as smoke-only (safe to delete)"
  else
    fail "smoke manifest is not labelled as smoke-only"
  fi
fi

if [[ -f "${ARGO_APPSET}" ]] && ! grep -q 'smoke/' "${ARGO_APPSET}"; then
  pass "smoke manifest directory is outside the Argo CD synced path"
else
  fail "Argo CD ApplicationSet references the smoke manifest directory (it would be synced)"
fi

# --- Bootstrap script safety ---
for script in "${CM_INSTALL}" "${ARGO_BOOTSTRAP}"; do
  [[ -f "${script}" ]] || continue
  name="${script#"${ROOT_DIR}/"}"

  if grep -q '^set -euo pipefail$' "${script}"; then
    pass "${name} uses set -euo pipefail"
  else
    fail "${name} does not use set -euo pipefail"
  fi

  if [[ -x "${script}" ]]; then
    pass "${name} is executable"
  else
    fail "${name} is not executable"
  fi
done

if [[ -f "${CM_INSTALL}" ]] && grep -q 'PLATFORMINIT_ALLOW_LIVE_CERT_MANAGER_INSTALL' "${CM_INSTALL}"; then
  pass "cert-manager bootstrap requires an explicit live-install acknowledgement"
else
  fail "cert-manager bootstrap lacks the live-install acknowledgement guard"
fi

if [[ -f "${ARGO_BOOTSTRAP}" ]] && grep -q 'PLATFORMINIT_ALLOW_LIVE_ARGOCD_BOOTSTRAP' "${ARGO_BOOTSTRAP}"; then
  pass "Argo CD bootstrap requires an explicit live-bootstrap acknowledgement"
else
  fail "Argo CD bootstrap lacks the live-bootstrap acknowledgement guard"
fi

# --- Regression guard (security review finding 2): verified upstream installs ---
for script in "${CM_INSTALL}" "${ARGO_BOOTSTRAP}"; do
  [[ -f "${script}" ]] || continue
  name="${script#"${ROOT_DIR}/"}"

  if grep -Eq 'kubectl apply[^|]*(-f|--filename)[[:space:]]*"?https?://' "${script}" \
    || grep -Eq 'kubectl apply[^|]*(-f|--filename)[[:space:]]*"\$\{[A-Z_]*URL[A-Z_]*\}"' "${script}"; then
    fail "${name} still sends a remote URL to kubectl apply"
  else
    pass "${name} never applies a remote URL directly"
  fi

  if grep -Eq 'download_verified(_install)?_manifest' "${script}" \
    && grep -q 'sha256sum' "${script}" \
    && grep -q -- "--proto '=https'" "${script}"; then
    pass "${name} downloads the upstream manifest to temporary storage and verifies its SHA-256 over HTTPS"
  else
    fail "${name} does not download and SHA-256-verify the upstream manifest before applying it"
  fi

  if grep -q 'validate_version_syntax' "${script}"; then
    pass "${name} validates the upstream version tag syntax"
  else
    fail "${name} accepts an unvalidated upstream version override"
  fi

  if grep -Eq '^[A-Z_]*PINNED_VERSION="v[0-9]+\.[0-9]+\.[0-9]+"$' "${script}" \
    && grep -Eq '^[A-Z_]*PINNED_MANIFEST_SHA256="[0-9a-f]{64}"$' "${script}"; then
    pass "${name} keeps the upstream version and SHA-256 pin in Git"
  else
    fail "${name} does not keep a committed version/SHA-256 pin in Git"
  fi

  if grep -Eq '^[A-Z_]*(INSTALL|MANIFEST)_URL="\$\{[A-Z_]+:-https?://' "${script}"; then
    fail "${name} still accepts an arbitrary manifest URL override"
  else
    pass "${name} does not accept an arbitrary manifest URL override"
  fi

  VERIFY_LINE="$(line_of "${script}" '^download_verified(_install)?_manifest "')"
  INSTALL_APPLY_LINE="$(line_of "${script}" 'kubectl apply --server-side')"
  if [[ "${VERIFY_LINE}" -gt 0 && "${VERIFY_LINE}" -lt "${INSTALL_APPLY_LINE}" ]]; then
    pass "${name} verifies the manifest before the first server-side apply"
  else
    fail "${name} does not verify the manifest before the first server-side apply (verify line ${VERIFY_LINE}, apply line ${INSTALL_APPLY_LINE})"
  fi
done

# --- Argo CD ownership contract ---
if [[ -f "${ARGO_PROJECT}" ]]; then
  if grep -Eq '^[[:space:]]*name:[[:space:]]*platform-services[[:space:]]*$' "${ARGO_PROJECT}"; then
    pass "AppProject platform-services declared"
  else
    fail "AppProject platform-services not declared"
  fi

  if grep -qF -- "${STABLE_REPO_URL}" "${ARGO_PROJECT}"; then
    pass "AppProject allows the stable platforminit-platform repository"
  else
    fail "AppProject does not allow the stable platforminit-platform repository"
  fi
fi

# --- Regression guard (security review finding 1): least-privilege AppProject ---
if [[ -f "${ARGO_PROJECT}" ]]; then
  if grep -Eq '^[[:space:]]*(group|kind):[[:space:]]*"?\*"?[[:space:]]*$' "${ARGO_PROJECT}"; then
    fail "AppProject platform-services still grants wildcard group/kind permissions"
  else
    pass "AppProject platform-services declares no wildcard group/kind permissions"
  fi

  PROJECT_PAIRS="$(project_resource_pairs "${ARGO_PROJECT}")"

  for required_pair in cert-manager.io/ClusterIssuer helm.cattle.io/HelmChartConfig; do
    if grep -qxF "${required_pair}" <<< "${PROJECT_PAIRS}"; then
      pass "AppProject explicitly allows ${required_pair}"
    else
      fail "AppProject does not explicitly allow ${required_pair}"
    fi
  done

  # Every kind in a directory the ApplicationSet syncs must be explicitly allowed;
  # a wildcard is the only way a missing entry could stay invisible.
  SYNCED_PAIRS=""
  for synced_dir in "${CLUSTER_DIR}/manifests/traefik" "${CLUSTER_DIR}/addons/cert-manager"; do
    [[ -d "${synced_dir}" ]] || continue
    for synced_file in "${synced_dir}"/*.yaml; do
      [[ -f "${synced_file}" ]] || continue
      SYNCED_PAIRS="${SYNCED_PAIRS}$(yaml_doc_pairs "${synced_file}")"$'\n'
    done
  done
  MISSING_PAIRS=""
  while IFS= read -r pair; do
    [[ -n "${pair}" ]] || continue
    grep -qxF "${pair}" <<< "${PROJECT_PAIRS}" || MISSING_PAIRS="${MISSING_PAIRS}${pair} "
  done < <(printf '%s\n' "${SYNCED_PAIRS}" | sort -u)
  if [[ -z "${MISSING_PAIRS}" ]]; then
    pass "every kind synced by the ApplicationSet is explicitly allowed by the AppProject"
  else
    fail "synced kinds missing from the AppProject allowlist: ${MISSING_PAIRS}"
  fi

  # Unused destinations must not stay granted: they widen the blast radius of a
  # repository-write compromise without serving any generated Application.
  PROJECT_NS="$(project_destinations "${ARGO_PROJECT}" | sort -u)"
  if [[ "${PROJECT_NS}" == "$(printf '%s\n' cert-manager kube-system)" ]]; then
    pass "AppProject destinations are limited to the namespaces platform services use"
  else
    fail "AppProject destinations are not limited to cert-manager + kube-system (found: '$(printf '%s ' ${PROJECT_NS})')"
  fi
fi

if [[ -f "${ARGO_APPSET}" ]]; then
  if grep -Eq '^[[:space:]]*project:[[:space:]]*platform-services[[:space:]]*$' "${ARGO_APPSET}"; then
    pass "ApplicationSet targets the platform-services project"
  else
    fail "ApplicationSet does not target the platform-services project"
  fi

  if grep -Eq '^[[:space:]]*automated:[[:space:]]*$' "${ARGO_APPSET}"; then
    pass "ApplicationSet Applications use automated sync"
  else
    fail "ApplicationSet Applications do not use automated sync"
  fi

  if grep -q 'platform/cluster/manifests/traefik' "${ARGO_APPSET}" \
    && grep -q 'platform/cluster/addons/cert-manager' "${ARGO_APPSET}"; then
    pass "ApplicationSet generates Traefik and cert-manager Applications"
  else
    fail "ApplicationSet does not generate both Traefik and cert-manager Applications"
  fi

  if grep -Eq '^[[:space:]]*recurse:[[:space:]]*false[[:space:]]*$' "${ARGO_APPSET}"; then
    pass "ApplicationSet does not recurse (smoke manifests stay unsynced)"
  else
    fail "ApplicationSet must not recurse into the synced directories"
  fi
fi

if [[ -f "${ARGO_SELF_APP}" ]]; then
  if grep -q 'platform/cluster/manifests/argocd' "${ARGO_SELF_APP}"; then
    pass "argocd-self Application owns platform/cluster/manifests/argocd"
  else
    fail "argocd-self Application does not own the Argo CD GitOps directory"
  fi

  if grep -Eq '^[[:space:]]*prune:[[:space:]]*false[[:space:]]*$' "${ARGO_SELF_APP}"; then
    pass "argocd-self disables pruning (self-management safety)"
  else
    fail "argocd-self must disable pruning"
  fi
fi

# --- Regression guard (review finding 1): fresh-cluster bootstrap ordering ---
SELF_PROJECT="$(first_scalar "${ARGO_SELF_APP}" project)"
if [[ -z "${SELF_PROJECT}" ]]; then
  fail "argocd-self Application does not declare spec.project"
elif [[ "${SELF_PROJECT}" == "default" ]]; then
  pass "argocd-self bootstraps in Argo CD's built-in 'default' project (fresh-cluster safe)"
elif [[ -f "${ARGO_BOOTSTRAP}" ]] && grep -qF 'appproject-platform-services.yaml' "${ARGO_BOOTSTRAP}"; then
  pass "argocd-self uses project '${SELF_PROJECT}' and the bootstrap pre-creates that AppProject"
else
  fail "argocd-self targets project '${SELF_PROJECT}', which does not exist before its own first sync (fresh-cluster AppProject dependency cycle)"
fi

# --- Regression guard (review finding 2): reconcilable GitOps source ---
COMMITTED_REPO_URL="$(first_scalar "${ARGO_SELF_APP}" repoURL)"
COMMITTED_TARGET_REVISION="$(first_scalar "${ARGO_SELF_APP}" targetRevision)"
APPSET_REPO_URL="$(first_scalar "${ARGO_APPSET}" repoURL)"
APPSET_TARGET_REVISION="$(first_scalar "${ARGO_APPSET}" targetRevision)"

if grep -Eq "^[[:space:]]*repoURL:.*${STABLE_REPO_URL#https://}" "${ARGO_SELF_APP}" "${ARGO_APPSET}" 2>/dev/null; then
  fail "GitOps source is hard-coded to the stable platforminit-platform repository (manifests from this branch would not be reconcilable)"
else
  pass "no hard-coded stable platforminit-platform GitOps source"
fi

if [[ -n "${COMMITTED_REPO_URL}" ]]; then
  if [[ "${COMMITTED_REPO_URL}" == *"platforminit-roo-lab.git" ]]; then
    pass "argocd-self GitOps source targets the lab repository (${COMMITTED_REPO_URL})"
  else
    fail "argocd-self GitOps source '${COMMITTED_REPO_URL}' is outside the documented roo-lab development boundary"
  fi
else
  fail "argocd-self does not declare repoURL"
fi

if [[ -z "${COMMITTED_TARGET_REVISION}" ]]; then
  fail "argocd-self does not pin targetRevision"
else
  pass "argocd-self pins targetRevision ${COMMITTED_TARGET_REVISION}"
fi

if [[ "${APPSET_REPO_URL}" == "${COMMITTED_REPO_URL}" \
  && "${APPSET_TARGET_REVISION}" == "${COMMITTED_TARGET_REVISION}" \
  && -n "${APPSET_REPO_URL}" ]]; then
  pass "ApplicationSet GitOps source matches the argocd-self source"
else
  fail "ApplicationSet source ('${APPSET_REPO_URL:-unset}'@'${APPSET_TARGET_REVISION:-unset}') differs from argocd-self ('${COMMITTED_REPO_URL:-unset}'@'${COMMITTED_TARGET_REVISION:-unset}')"
fi

if [[ -f "${ARGO_PROJECT}" && -n "${COMMITTED_REPO_URL}" ]]; then
  if grep -qF -- "${COMMITTED_REPO_URL}" "${ARGO_PROJECT}"; then
    pass "AppProject sourceRepos allows the committed GitOps source"
  else
    fail "AppProject sourceRepos does not allow the committed GitOps source ${COMMITTED_REPO_URL}"
  fi
fi

if [[ -f "${ARGO_BOOTSTRAP}" ]]; then
  if grep -q 'PLATFORMINIT_GITOPS_REPO_URL' "${ARGO_BOOTSTRAP}" \
    && grep -q 'PLATFORMINIT_GITOPS_TARGET_REVISION' "${ARGO_BOOTSTRAP}"; then
    pass "bootstrap-argocd.sh exposes repoURL/revision as deployment inputs"
  else
    fail "bootstrap-argocd.sh does not expose PLATFORMINIT_GITOPS_REPO_URL / PLATFORMINIT_GITOPS_TARGET_REVISION"
  fi

  SCRIPT_DEFAULT_REPO="$(shell_default "${ARGO_BOOTSTRAP}" GITOPS_COMMITTED_REPO_URL)"
  SCRIPT_DEFAULT_REVISION="$(shell_default "${ARGO_BOOTSTRAP}" GITOPS_COMMITTED_TARGET_REVISION)"

  if [[ -n "${SCRIPT_DEFAULT_REPO}" \
    && "${SCRIPT_DEFAULT_REPO}" == "${COMMITTED_REPO_URL}" \
    && "${SCRIPT_DEFAULT_REVISION}" == "${COMMITTED_TARGET_REVISION}" ]]; then
    pass "bootstrap GitOps defaults match the committed Application/ApplicationSet source"
  else
    fail "bootstrap GitOps defaults ('${SCRIPT_DEFAULT_REPO:-unset}'@'${SCRIPT_DEFAULT_REVISION:-unset}') do not match the committed source ('${COMMITTED_REPO_URL:-unset}'@'${COMMITTED_TARGET_REVISION:-unset}')"
  fi

  if grep -q 'PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE' "${ARGO_BOOTSTRAP}"; then
    pass "bootstrap-argocd.sh guards the stable repository behind an explicit acknowledgement"
  else
    fail "bootstrap-argocd.sh can bootstrap from the stable repository without an explicit acknowledgement"
  fi

  # Regression guard (review finding 1): the selected revision must exist in the
  # remote repository before any cluster mutation.
  if grep -q 'verify_gitops_source_reachable' "${ARGO_BOOTSTRAP}" \
    && grep -q 'git ls-remote' "${ARGO_BOOTSTRAP}"; then
    pass "bootstrap-argocd.sh verifies the selected revision exists in the remote repository"
  else
    fail "bootstrap-argocd.sh does not verify that the selected GitOps revision is fetchable by Argo CD"
  fi

  if grep -qF '*"@"*' "${ARGO_BOOTSTRAP}"; then
    pass "bootstrap-argocd.sh refuses credentials embedded in the GitOps repository URL"
  else
    fail "bootstrap-argocd.sh accepts credentials embedded in the GitOps repository URL"
  fi
fi

# --- Regression guard (security review finding 1): bounded ARGOCD_SYNC_TIMEOUT ---
# wait_for_application_synced()/wait_for_object() evaluate ARGOCD_SYNC_TIMEOUT
# inside Bash arithmetic, which recursively evaluates array subscripts and
# command substitutions. The guard must exist, must be digit-only and bounded,
# and must appear before the first arithmetic use and the first cluster access.
if [[ -f "${ARGO_BOOTSTRAP}" ]]; then
  if grep -q 'ARGOCD_SYNC_TIMEOUT_MIN' "${ARGO_BOOTSTRAP}" \
    && grep -q 'ARGOCD_SYNC_TIMEOUT_MAX' "${ARGO_BOOTSTRAP}"; then
    pass "bootstrap-argocd.sh enforces lower/upper ARGOCD_SYNC_TIMEOUT bounds"
  else
    fail "bootstrap-argocd.sh does not enforce lower/upper ARGOCD_SYNC_TIMEOUT bounds"
  fi

  if grep -qF 'ARGOCD_SYNC_TIMEOUT=$((10#' "${ARGO_BOOTSTRAP}"; then
    pass "bootstrap-argocd.sh normalizes ARGOCD_SYNC_TIMEOUT to base 10 before use"
  else
    fail "bootstrap-argocd.sh does not normalize ARGOCD_SYNC_TIMEOUT to base 10"
  fi

  # Safe negative regression: replay the committed digit-only guard against
  # malformed payloads in this shell only. Nothing is sourced from the bootstrap
  # script, no cluster is contacted, and the payload is used exclusively in a
  # string comparison, so it is never evaluated as arithmetic.
  SYNC_GUARD_REGEX="$(grep -oE '\^\[0-9\]\{1,[0-9]+\}\$' "${ARGO_BOOTSTRAP}" 2>/dev/null | head -n1 || true)"
  SYNC_ARITH_PAYLOAD='x[$(touch /tmp/platforminit-arithmetic-probe)]'
  if [[ -n "${SYNC_GUARD_REGEX}" ]] \
    && [[ ! "${SYNC_ARITH_PAYLOAD}" =~ ${SYNC_GUARD_REGEX} ]] \
    && [[ ! "abc" =~ ${SYNC_GUARD_REGEX} ]] \
    && [[ ! "300 " =~ ${SYNC_GUARD_REGEX} ]] \
    && [[ "300" =~ ${SYNC_GUARD_REGEX} ]]; then
    pass "digit-only ARGOCD_SYNC_TIMEOUT guard ('${SYNC_GUARD_REGEX}') rejects arithmetic/nonnumeric payloads and accepts 300"
  else
    fail "digit-only ARGOCD_SYNC_TIMEOUT guard rejects valid input or accepts a malformed/arithmetic payload (guard regex: '${SYNC_GUARD_REGEX:-none}')"
  fi

  SYNC_GUARD_LINE="$(line_of "${ARGO_BOOTSTRAP}" 'ARGOCD_SYNC_TIMEOUT\}" =~')"
  # Anchor on the arithmetic assignment itself, not on the prose in the guard's
  # own comment block, so the check proves where the value is actually evaluated.
  SYNC_ARITH_LINE="$(line_of "${ARGO_BOOTSTRAP}" 'deadline=\$\(\(SECONDS \+ ARGOCD_SYNC_TIMEOUT')"
  SYNC_CLUSTER_LINE="$(line_of "${ARGO_BOOTSTRAP}" 'kubectl -n')"
  if [[ "${SYNC_GUARD_LINE}" -gt 0 && "${SYNC_ARITH_LINE}" -gt 0 && "${SYNC_CLUSTER_LINE}" -gt 0 \
    && "${SYNC_GUARD_LINE}" -lt "${SYNC_ARITH_LINE}" \
    && "${SYNC_GUARD_LINE}" -lt "${SYNC_CLUSTER_LINE}" ]]; then
    pass "bootstrap-argocd.sh type/range guard precedes the first arithmetic use (line ${SYNC_ARITH_LINE}) and cluster access (line ${SYNC_CLUSTER_LINE})"
  else
    fail "bootstrap-argocd.sh type/range guard does not precede arithmetic/cluster use (guard line ${SYNC_GUARD_LINE}, arithmetic line ${SYNC_ARITH_LINE}, cluster line ${SYNC_CLUSTER_LINE})"
  fi
fi

# --- Regression guard (review findings 1-3): documentation matches the contract ---
if [[ -f "${CONTRACT_DOC}" ]]; then
  if grep -qi 'pushed' "${CONTRACT_DOC}" && grep -qi 'reachab' "${CONTRACT_DOC}"; then
    pass "contract documents that the rehearsal revision must be pushed and reachable"
  else
    fail "contract does not document the pushed/reachable GitOps revision prerequisite"
  fi

  if ! grep -q 'no PR required' "${CONTRACT_DOC}"; then
    pass "contract does not advertise an unpushed local-branch rehearsal"
  else
    fail "contract still advertises a rehearsal revision that may never reach the remote repository"
  fi

  if grep -q 'argocd.argoproj.io/secret-type=repository' "${CONTRACT_DOC}" \
    && grep -q 'PLATFORMINIT_GITOPS_REPO_TOKEN' "${CONTRACT_DOC}"; then
    pass "contract documents secret-safe private repository registration for Argo CD"
  else
    fail "contract does not document secret-safe private repository registration (repository secret + token from the environment)"
  fi

  if ! grep -Eq -- '--from-literal=(password|username)=[^"$]' "${CONTRACT_DOC}"; then
    pass "contract registration snippet never inlines a literal credential value"
  else
    fail "contract registration snippet inlines a literal credential value"
  fi

  if grep -q 'SMOKE_TIMEOUT' "${CONTRACT_DOC}" && grep -q '1800' "${CONTRACT_DOC}"; then
    pass "contract documents the bounded SMOKE_TIMEOUT range"
  else
    fail "contract does not document the bounded SMOKE_TIMEOUT range"
  fi

  if grep -q 'LB_WAIT_TIMEOUT' "${CONTRACT_DOC}" && grep -q '900' "${CONTRACT_DOC}"; then
    pass "contract documents the bounded LB_WAIT_TIMEOUT range"
  else
    fail "contract does not document the bounded LB_WAIT_TIMEOUT range"
  fi

  if grep -q 'ARGOCD_SYNC_TIMEOUT' "${CONTRACT_DOC}" && grep -q '1800' "${CONTRACT_DOC}"; then
    pass "contract documents the bounded ARGOCD_SYNC_TIMEOUT range"
  else
    fail "contract does not document the bounded ARGOCD_SYNC_TIMEOUT range"
  fi

  if grep -qi 'least-privilege\|least privilege' "${CONTRACT_DOC}" \
    && grep -qi 'wildcard' "${CONTRACT_DOC}" \
    && grep -qi 'allowlist' "${CONTRACT_DOC}"; then
    pass "contract documents the least-privilege AppProject allowlist (no wildcards)"
  else
    fail "contract does not document the least-privilege AppProject allowlist"
  fi

  if grep -q 'ClusterIssuer' "${CONTRACT_DOC}" && grep -q 'HelmChartConfig' "${CONTRACT_DOC}"; then
    pass "contract names the explicitly allowed resource kinds"
  else
    fail "contract does not name the explicitly allowed resource kinds"
  fi

  if grep -qi 'sha-256' "${CONTRACT_DOC}" && grep -qi 'pin' "${CONTRACT_DOC}"; then
    pass "contract documents the committed upstream version/SHA-256 pin"
  else
    fail "contract does not document the committed upstream version/SHA-256 pin"
  fi

  if grep -qi 'not operator-overridable' "${CONTRACT_DOC}" && grep -q 'sha256sum' "${CONTRACT_DOC}"; then
    pass "contract documents the removed manifest URL override and the pin-refresh procedure"
  else
    fail "contract does not document the removed manifest URL override / pin-refresh procedure"
  fi
fi

for doc in "${CONTRACT_DOC}" "${ARGO_README}" "${CM_README}" "${CLUSTER_README}"; do
  [[ -f "${doc}" ]] || continue
  if grep -q 'SMOKE_KEEP_RESOURCES' "${doc}"; then
    fail "${doc#"${ROOT_DIR}/"} still advertises the removed keep-resources bypass"
  else
    pass "${doc#"${ROOT_DIR}/"} does not advertise a keep-resources bypass"
  fi
done

if [[ -f "${ARGO_README}" ]]; then
  if grep -qi 'push' "${ARGO_README}" && grep -qi 'reachab' "${ARGO_README}"; then
    pass "Argo CD addon README documents the pushed/reachable revision prerequisite"
  else
    fail "Argo CD addon README does not document the pushed/reachable revision prerequisite"
  fi

  if grep -q 'ARGO_INSTALL_URL' "${ARGO_README}"; then
    fail "Argo CD addon README still advertises the removed manifest URL override"
  else
    pass "Argo CD addon README does not advertise a manifest URL override"
  fi

  if grep -q 'ARGO_PINNED_MANIFEST_SHA256' "${ARGO_README}" && grep -q 'sha256sum' "${ARGO_README}"; then
    pass "Argo CD addon README documents the committed digest pin and pin-refresh step"
  else
    fail "Argo CD addon README does not document the committed digest pin"
  fi

  if grep -q 'ARGOCD_SYNC_TIMEOUT' "${ARGO_README}" && grep -q '1800' "${ARGO_README}"; then
    pass "Argo CD addon README documents the bounded ARGOCD_SYNC_TIMEOUT range"
  else
    fail "Argo CD addon README does not document the bounded ARGOCD_SYNC_TIMEOUT range"
  fi
fi

if [[ -f "${CM_README}" ]]; then
  if grep -q 'CM_PINNED_MANIFEST_SHA256' "${CM_README}" && grep -q 'sha256sum' "${CM_README}"; then
    pass "cert-manager addon README documents the committed digest pin and pin-refresh step"
  else
    fail "cert-manager addon README does not document the committed digest pin"
  fi
fi

# --- Secret hygiene ---
# Key names are allowed; literal values are not.
if grep -REn 'api-token:[[:space:]]+[^[:space:]"]' "${CLUSTER_DIR}/addons" "${CLUSTER_DIR}/manifests" >/dev/null 2>&1; then
  fail "possible plaintext secret value committed under platform/cluster"
else
  pass "no plaintext api-token value found under platform/cluster"
fi

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH04 platform services GitOps contract satisfied"
