#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - Argo CD bootstrap (idempotent, one-time control-plane install)
#
# Bootstrap phase only:
#   - installs Argo CD (pinned version)
#   - configures ingress mode (server.insecure=true)
#   - waits for the Argo CD control plane
#   - registers the self-management Application (argocd-self)
#
# After this step Argo CD owns the platform services: the AppProject and the
# platform-services ApplicationSet are reconciled from
# platform/cluster/manifests/argocd, and every platform service is deployed by
# Argo CD instead of manual kubectl.
#
# Fresh-cluster ordering: argocd-self runs in Argo CD's built-in `default`
# project. The `platform-services` AppProject it reconciles lives inside the
# source directory argocd-self owns, so that AppProject cannot be a prerequisite
# of the Application that creates it. Nothing else is bootstrapped imperatively
# in the default path.
#
# GitOps source inputs (see addons/argocd/README.md):
#   PLATFORMINIT_GITOPS_REPO_URL         default: the lab repository (roo-lab)
#   PLATFORMINIT_GITOPS_TARGET_REVISION  default: dev
#
# The committed Application/ApplicationSet defaults must match these values;
# validate/ch04-validate-platform-services-gitops-contract.sh enforces that
# invariant. Overriding them performs a pre-promotion rehearsal: the Argo CD
# manifests are rendered with the requested source, applied once, and automated
# self-management sync is disabled for that session so the bootstrap does not
# fight the committed default (which points at the promoted revision).
#
# Reachability contract: Argo CD fetches its source from the remote repository,
# never from the local workspace, so a rehearsal revision must already be pushed
# before it means anything. Any override is therefore probed with
# `git ls-remote` before the first cluster mutation and the bootstrap aborts if
# the revision is absent remotely. A local-only branch can never be mistaken for
# reconciliation evidence. Private repositories additionally need an Argo CD
# repository registration and git credentials on this host (see
# addons/argocd/README.md); credentials are never embedded in the repository URL
# and are never echoed by this script.
#
# Install integrity (security review finding 2): the Argo CD install manifest is
# fetched over HTTPS from one fixed origin and must match the SHA-256 pinned in
# this script before a single object is applied. The arbitrary ARGO_INSTALL_URL
# override is gone: it is no longer part of the accepted path. ARGO_VERSION may
# still be set, but only to a semantic tag that has a committed pin; an unpinned
# version is refused instead of installed unverified (see addons/argocd/README.md).
############################################

ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGO_VERSION="${ARGO_VERSION:-v2.10.7}"
ARGOCD_ROLLOUT_TIMEOUT="${ARGOCD_ROLLOUT_TIMEOUT:-600s}"
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-300}"
# Operator bounds for ARGOCD_SYNC_TIMEOUT (default 300s); enforced by the
# input-validation block below before the value reaches Bash arithmetic.
ARGOCD_SYNC_TIMEOUT_MIN=30
ARGOCD_SYNC_TIMEOUT_MAX=1800
ARGO_DOWNLOAD_TIMEOUT="${ARGO_DOWNLOAD_TIMEOUT:-120}"

# Committed upstream pin: version and digest are the integrity boundary and must
# be updated together. The digest is the SHA-256 of
# <origin>/<version>/manifests/install.yaml.
ARGO_PINNED_VERSION="v2.10.7"
ARGO_PINNED_MANIFEST_SHA256="0a1f9a6fb32909608384f9a8beb3502f80b895255416b827b2c287e1731d7450"
# Fixed HTTPS origin. This is a constant, not an input: arbitrary manifest URLs
# are not accepted from the environment.
ARGO_INSTALL_ORIGIN="https://raw.githubusercontent.com/argoproj/argo-cd"

# GitOps source defaults, mirrored in manifests/argocd/*.yaml.
GITOPS_COMMITTED_REPO_URL="https://github.com/platforminit/platforminit-roo-lab.git"
GITOPS_COMMITTED_TARGET_REVISION="dev"
GITOPS_STABLE_REPO_URL="https://github.com/platforminit/platforminit-platform.git"
GITOPS_ALLOWED_REPOS=(
  "${GITOPS_COMMITTED_REPO_URL}"
  "${GITOPS_STABLE_REPO_URL}"
)

GITOPS_REPO_URL="${PLATFORMINIT_GITOPS_REPO_URL:-${GITOPS_COMMITTED_REPO_URL}}"
GITOPS_TARGET_REVISION="${PLATFORMINIT_GITOPS_TARGET_REVISION:-${GITOPS_COMMITTED_TARGET_REVISION}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/../../manifests/argocd"
SELF_APPLICATION_FILE="${MANIFEST_DIR}/application-argocd-self.yaml"
APP_PROJECT_FILE="${MANIFEST_DIR}/appproject-platform-services.yaml"
APP_SET_FILE="${MANIFEST_DIR}/applicationset-platform-services.yaml"
RENDER_DIR=""
WORK_DIR=""
INSTALL_MANIFEST_FILE=""

log()  { echo "[CH04][argocd][$(date -u +%FT%TZ)] $*"; }
warn() { echo "[CH04][argocd][$(date -u +%FT%TZ)][WARN] $*" >&2; }
die()  { echo "[CH04][argocd][FATAL] $*" >&2; exit 1; }

############################################
# Input validation (security review finding 1)
#
# ARGOCD_SYNC_TIMEOUT is operator-supplied and the wait helpers evaluate it
# inside Bash arithmetic ($((SECONDS + ARGOCD_SYNC_TIMEOUT))). Bash recursively
# evaluates array subscripts and command substitutions there, so an unvalidated
# value such as 'x[$(cmd)]' would execute a command in this root-run script, and
# plain nonnumeric input would abort only after Argo CD had already been
# installed. The value is therefore proven to be a bounded base-10 integer
# before the first arithmetic use and before the first cluster call:
#   - digits only, with a bounded length, so no metacharacter survives;
#   - normalized with 10#, so a leading zero is not read as octal;
#   - range-checked against ARGOCD_SYNC_TIMEOUT_MIN/MAX (30-1800s).
# Only the validated value is ever used; the raw input is never evaluated.
############################################
if [[ ! "${ARGOCD_SYNC_TIMEOUT}" =~ ^[0-9]{1,9}$ ]]; then
  die "ARGOCD_SYNC_TIMEOUT must be a base-10 integer number of seconds (got '${ARGOCD_SYNC_TIMEOUT}'). Nothing was evaluated and no cluster call was made."
fi
# 10# forces base 10, so '0300' means 300 seconds and never an octal value.
ARGOCD_SYNC_TIMEOUT=$((10#${ARGOCD_SYNC_TIMEOUT}))
if (( ARGOCD_SYNC_TIMEOUT < ARGOCD_SYNC_TIMEOUT_MIN || ARGOCD_SYNC_TIMEOUT > ARGOCD_SYNC_TIMEOUT_MAX )); then
  die "ARGOCD_SYNC_TIMEOUT=${ARGOCD_SYNC_TIMEOUT}s is outside the allowed range ${ARGOCD_SYNC_TIMEOUT_MIN}-${ARGOCD_SYNC_TIMEOUT_MAX}s (default 300s). Nothing was evaluated and no cluster call was made."
fi

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"
}

cleanup() {
  local dir
  for dir in "${RENDER_DIR}" "${WORK_DIR}"; do
    if [[ -n "${dir}" && "${dir}" == /tmp/* && -d "${dir}" ]]; then
      rm -rf "${dir}"
    fi
  done
}

validate_gitops_source() {
  local url="$1" revision="$2" allowed

  [[ -n "${url}" ]] || die "PLATFORMINIT_GITOPS_REPO_URL must not be empty."
  [[ -n "${revision}" ]] || die "PLATFORMINIT_GITOPS_TARGET_REVISION must not be empty."
  [[ "${url}" =~ ^https://[A-Za-z0-9._:/@+-]+$ ]] || die "Unsupported repoURL: '${url}'"
  [[ "${revision}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Unsupported targetRevision: '${revision}'"
  # The URL itself is never echoed here: a userinfo section would leak a secret.
  [[ "${url}" != *"@"* ]] || die "Do not embed credentials in PLATFORMINIT_GITOPS_REPO_URL. Register Argo CD repository credentials separately (see addons/argocd/README.md); embedded userinfo leaks tokens into logs and manifests."

  if [[ "${url}" == "${GITOPS_STABLE_REPO_URL}" && "${PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE:-}" != "true" ]]; then
    die "Refusing the stable repository (${GITOPS_STABLE_REPO_URL}) as GitOps source. Set PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true only in the promoted stable repository."
  fi

  for allowed in "${GITOPS_ALLOWED_REPOS[@]}"; do
    [[ "${url}" == "${allowed}" ]] && return 0
  done

  die "repoURL '${url}' is not an allowed PlatformInit GitOps repository (${GITOPS_ALLOWED_REPOS[*]})."
}

# Proves that the selected revision is fetchable by Argo CD from the remote
# repository. Probe output is intentionally discarded: repository URLs,
# credential helpers and git error text may carry sensitive material.
verify_gitops_source_reachable() {
  local url="$1" revision="$2"

  need git

  log "Verifying GitOps source reachability (remote fetch by Argo CD): ${url}@${revision}"
  if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads "${url}" "${revision}" >/dev/null 2>&1; then
    die "Revision '${revision}' does not exist in ${url}. Argo CD fetches from the remote repository, not from this workspace. Push the revision first (git push origin ${revision}); for a private repository register Argo CD repository credentials (see addons/argocd/README.md) and make them available to git on this host. A local-only branch is never reconciliation evidence."
  fi
  log "GitOps source reachable: refs/heads/${revision} exists in ${url}"
}

validate_version_syntax() {
  local version="$1" label="$2"

  [[ -n "${version}" ]] || die "${label} must not be empty."
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "${label} '${version}' is not a supported upstream tag (expected vMAJOR.MINOR.PATCH, e.g. v2.10.7)."
}

# Prints the committed SHA-256 for a pinned upstream version, or aborts.
pinned_install_sha256() {
  local version="$1"

  if [[ "${version}" == "${ARGO_PINNED_VERSION}" ]]; then
    printf '%s' "${ARGO_PINNED_MANIFEST_SHA256}"
    return 0
  fi

  die "Version '${version}' has no committed SHA-256 pin. Refusing to install unverified upstream YAML. Verify the release digest and add it to ARGO_PINNED_VERSION/ARGO_PINNED_MANIFEST_SHA256 in this script (see addons/argocd/README.md) instead of overriding ARGO_VERSION."
}

# Downloads the pinned install manifest into temporary storage and refuses to
# continue unless its SHA-256 matches the committed pin. Only the verified local
# file is ever applied.
download_verified_install_manifest() {
  local url="$1" expected_sha256="$2" destination="$3" rc=0 actual_sha256=""

  [[ "${url}" =~ ^https://raw\.githubusercontent\.com/argoproj/argo-cd/v[0-9]+\.[0-9]+\.[0-9]+/manifests/install\.yaml$ ]] \
    || die "Refusing unexpected install manifest URL (HTTPS host/path allowlist): ${url}"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] \
    || die "Committed digest for version '${ARGO_VERSION}' is not a valid SHA-256 value."

  log "Downloading Argo CD ${ARGO_VERSION} install manifest for digest verification..."
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --max-time "${ARGO_DOWNLOAD_TIMEOUT}" \
    --output "${destination}" "${url}" || rc=$?
  [[ "${rc}" -eq 0 ]] || die "Download failed (curl exit ${rc}) for the pinned install manifest. Check HTTPS access to the upstream release and retry."

  [[ -s "${destination}" ]] || die "Downloaded install manifest is empty; refusing to apply it."

  actual_sha256="$(sha256sum "${destination}" | awk '{print $1}')"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    die "SHA-256 mismatch for ${url}: expected ${expected_sha256}, got ${actual_sha256}. Refusing to apply unverified YAML; update the committed pin only after reviewing the upstream change."
  fi

  log "Install manifest digest verified (sha256=${actual_sha256})"
}

render_gitops_manifest() {
  local src="$1" dst="$2"
  sed -E \
    -e "s|^([[:space:]]*repoURL:).*$|\1 ${GITOPS_REPO_URL}|" \
    -e "s|^([[:space:]]*targetRevision:).*$|\1 ${GITOPS_TARGET_REVISION}|" \
    "${src}" >"${dst}"
}

# Prints the last observed sync status; returns non-zero when the timeout expired.
# ARGOCD_SYNC_TIMEOUT is not raw input here: the input-validation block above has
# already proven it is a bounded, digit-only base-10 integer, so the arithmetic
# below cannot evaluate anything inherited from the environment.
wait_for_application_synced() {
  local name="$1" deadline=$((SECONDS + ARGOCD_SYNC_TIMEOUT)) status=""
  while ((SECONDS < deadline)); do
    status="$(kubectl -n "${ARGOCD_NS}" get application "${name}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    if [[ "${status}" == "Synced" ]]; then
      printf '%s' "${status}"
      return 0
    fi
    sleep 5
  done
  printf '%s' "${status}"
  return 1
}

wait_for_object() {
  local kind="$1" name="$2" deadline=$((SECONDS + ARGOCD_SYNC_TIMEOUT))
  while ((SECONDS < deadline)); do
    if kubectl -n "${ARGOCD_NS}" get "${kind}" "${name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)."
need kubectl
need curl
need sha256sum
need awk
trap cleanup EXIT

if [[ "${PLATFORMINIT_ALLOW_LIVE_ARGOCD_BOOTSTRAP:-}" != "true" ]]; then
  die "Refusing live bootstrap. Set PLATFORMINIT_ALLOW_LIVE_ARGOCD_BOOTSTRAP=true to acknowledge the upstream manifest install (the manifest is digest-verified before it is applied)."
fi

for manifest in "${SELF_APPLICATION_FILE}" "${APP_PROJECT_FILE}" "${APP_SET_FILE}"; do
  [[ -f "${manifest}" ]] || die "Argo CD GitOps manifest not found: ${manifest}"
done

# Upstream install integrity: version syntax and the committed digest pin are
# resolved before the first cluster call, and the manifest is downloaded and
# verified before the first cluster mutation.
validate_version_syntax "${ARGO_VERSION}" "ARGO_VERSION"
ARGO_MANIFEST_SHA256="$(pinned_install_sha256 "${ARGO_VERSION}")"
ARGO_MANIFEST_URL="${ARGO_INSTALL_ORIGIN}/${ARGO_VERSION}/manifests/install.yaml"

validate_gitops_source "${GITOPS_REPO_URL}" "${GITOPS_TARGET_REVISION}"

if ! grep -qF -- "${GITOPS_REPO_URL}" "${APP_PROJECT_FILE}"; then
  die "AppProject platform-services sourceRepos does not allow ${GITOPS_REPO_URL}."
fi

OVERRIDE_ACTIVE=false
if [[ "${GITOPS_REPO_URL}" != "${GITOPS_COMMITTED_REPO_URL}" \
  || "${GITOPS_TARGET_REVISION}" != "${GITOPS_COMMITTED_TARGET_REVISION}" ]]; then
  OVERRIDE_ACTIVE=true
fi

# The committed default revision is a published branch. An override may name any
# revision, so its remote existence is verified before any cluster mutation.
if [[ "${OVERRIDE_ACTIVE}" == "true" ]]; then
  verify_gitops_source_reachable "${GITOPS_REPO_URL}" "${GITOPS_TARGET_REVISION}"
fi

log "GitOps source: ${GITOPS_REPO_URL}@${GITOPS_TARGET_REVISION}"
log "Committed default: ${GITOPS_COMMITTED_REPO_URL}@${GITOPS_COMMITTED_TARGET_REVISION}"

WORK_DIR="$(mktemp -d)"
INSTALL_MANIFEST_FILE="${WORK_DIR}/argocd-install.yaml"
download_verified_install_manifest "${ARGO_MANIFEST_URL}" "${ARGO_MANIFEST_SHA256}" "${INSTALL_MANIFEST_FILE}"

log "Ensure namespace ${ARGOCD_NS}..."
kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Install/upgrade Argo CD ${ARGO_VERSION} from the verified manifest (idempotent, server-side, sha256=${ARGO_MANIFEST_SHA256})..."
kubectl apply --server-side=true -n "${ARGOCD_NS}" -f "${INSTALL_MANIFEST_FILE}"

CURRENT_INSECURE="$(kubectl -n "${ARGOCD_NS}" get configmap argocd-cmd-params-cm \
  -o jsonpath='{.data.server\.insecure}' 2>/dev/null || true)"
if [[ "${CURRENT_INSECURE}" == "true" ]]; then
  log "Ingress mode already configured (server.insecure=true)"
else
  log "Configure ingress mode (server.insecure=true) and restart argocd-server..."
  kubectl -n "${ARGOCD_NS}" patch configmap argocd-cmd-params-cm \
    --type merge -p '{"data":{"server.insecure":"true"}}' >/dev/null
  kubectl -n "${ARGOCD_NS}" rollout restart deploy/argocd-server >/dev/null
fi

log "Wait for Argo CD control plane..."
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-server --timeout="${ARGOCD_ROLLOUT_TIMEOUT}"
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-repo-server --timeout="${ARGOCD_ROLLOUT_TIMEOUT}"
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-applicationset-controller --timeout="${ARGOCD_ROLLOUT_TIMEOUT}"
kubectl -n "${ARGOCD_NS}" rollout status statefulset/argocd-application-controller --timeout="${ARGOCD_ROLLOUT_TIMEOUT}"

if [[ "${OVERRIDE_ACTIVE}" == "true" ]]; then
  ############################################
  # Pre-promotion rehearsal: the requested revision is not the committed
  # default, so the Argo CD manifests are rendered with the requested source
  # and applied once. Automated self-management sync is disabled for the
  # session, otherwise Argo CD would immediately reconcile argocd-self (and
  # therefore the AppProject/ApplicationSet) back to the committed default.
  ############################################
  RENDER_DIR="$(mktemp -d)"

  log "[rehearsal] Rendering Argo CD GitOps manifests (${GITOPS_REPO_URL}@${GITOPS_TARGET_REVISION})..."
  render_gitops_manifest "${APP_PROJECT_FILE}" "${RENDER_DIR}/appproject-platform-services.yaml"
  render_gitops_manifest "${APP_SET_FILE}" "${RENDER_DIR}/applicationset-platform-services.yaml"
  render_gitops_manifest "${SELF_APPLICATION_FILE}" "${RENDER_DIR}/application-argocd-self.yaml"

  log "[rehearsal] Applying rendered AppProject + ApplicationSet (one-time bootstrap registration)..."
  kubectl apply -f "${RENDER_DIR}/appproject-platform-services.yaml"
  kubectl apply -f "${RENDER_DIR}/applicationset-platform-services.yaml"

  log "[rehearsal] Applying rendered argocd-self Application..."
  kubectl apply -f "${RENDER_DIR}/application-argocd-self.yaml"

  log "[rehearsal] Disabling automated self-management sync for this session..."
  kubectl -n "${ARGOCD_NS}" patch application argocd-self \
    --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null

  if ! wait_for_object appproject platform-services; then
    die "[rehearsal] AppProject platform-services not present after ${ARGOCD_SYNC_TIMEOUT}s."
  fi
  if ! wait_for_object applicationset platform-services; then
    die "[rehearsal] ApplicationSet platform-services not present after ${ARGOCD_SYNC_TIMEOUT}s."
  fi

  log "[rehearsal] Argo CD GitOps manifests registered from ${GITOPS_REPO_URL}@${GITOPS_TARGET_REVISION}"
  warn "[rehearsal] Automated self-management sync is disabled until the committed default is promoted. Re-run without PLATFORMINIT_GITOPS_* overrides after merging this change into ${GITOPS_COMMITTED_TARGET_REVISION}."
else
  log "Register self-management Application (argocd-self)..."
  kubectl apply -f "${SELF_APPLICATION_FILE}"

  log "Wait for argocd-self to reach Synced (timeout ${ARGOCD_SYNC_TIMEOUT}s)..."
  if ! SYNC_STATUS="$(wait_for_application_synced argocd-self)"; then
    die "argocd-self did not reach Synced (last status: '${SYNC_STATUS:-unknown}'). The committed source ${GITOPS_COMMITTED_REPO_URL}@${GITOPS_COMMITTED_TARGET_REVISION} must actually contain platform/cluster/manifests/argocd, so promote the batch branch before a default bootstrap. Inspect: kubectl -n ${ARGOCD_NS} describe application argocd-self"
  fi

  log "Argo CD bootstrap complete (version=${ARGO_VERSION}, argocd-self=${SYNC_STATUS})"
fi

log "Platform services are now reconciled by Argo CD via the platform-services ApplicationSet."
log "Committed GitOps source requirement: the revision referenced above must contain platform/cluster/manifests/argocd (promote the batch branch into ${GITOPS_COMMITTED_TARGET_REVISION})."
