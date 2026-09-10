#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - cert-manager bootstrap (idempotent)
#
# Bootstrap phase only:
#   - installs cert-manager (pinned version) from the upstream manifest
#   - waits for the control plane
#   - syncs the Cloudflare DNS-01 API token secret (value never logged)
#
# The ClusterIssuer objects are GitOps-owned: they are reconciled by Argo CD
# from platform/cluster/addons/cert-manager via the platform-services
# ApplicationSet. Do NOT kubectl-apply issuers here.
#
# Supply-chain integrity (security review finding 2):
#   - the manifest URL is NOT operator-overridable: it is built from a fixed
#     HTTPS origin plus a version tag, and the final URL is matched against a
#     strict host/path allowlist before the download starts
#   - the version must be a supported semantic tag AND must have a committed
#     SHA-256 pin in this script; an unpinned version is refused instead of
#     installed unverified
#   - the manifest is downloaded to temporary storage, its SHA-256 is compared
#     against the committed pin, and only the verified local file is applied
#   - README.md documents the pin-refresh procedure
############################################

CM_NS="${CM_NS:-cert-manager}"
CM_VERSION="${CM_VERSION:-v1.14.5}"
CM_TIMEOUT="${CM_TIMEOUT:-600s}"
CM_DOWNLOAD_TIMEOUT="${CM_DOWNLOAD_TIMEOUT:-120}"
CF_SECRET_NAME="${CF_SECRET_NAME:-cloudflare-api-token-secret}"

# Committed upstream pin: version and digest are the integrity boundary and must
# be updated together. The digest is the SHA-256 of the release asset
# <origin>/<version>/cert-manager.yaml.
CM_PINNED_VERSION="v1.14.5"
CM_PINNED_MANIFEST_SHA256="cbe0b7817ac560559d6de61fc07aa8a8c14d7d9e37dace4e1f1da743464c3107"
# Fixed HTTPS origin. This is a constant, not an input: arbitrary manifest URLs
# were removed from the accepted path by the security fix batch.
CM_MANIFEST_ORIGIN="https://github.com/cert-manager/cert-manager/releases/download"

WORK_DIR=""
MANIFEST_FILE=""

log() { echo "[CH04][cert-manager][$(date -u +%FT%TZ)] $*"; }
die() { echo "[CH04][cert-manager][FATAL] $*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"
}

cleanup() {
  if [[ -n "${WORK_DIR}" && "${WORK_DIR}" == /tmp/* && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

validate_version_syntax() {
  local version="$1" label="$2"

  [[ -n "${version}" ]] || die "${label} must not be empty."
  [[ "${version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "${label} '${version}' is not a supported upstream tag (expected vMAJOR.MINOR.PATCH, e.g. v1.14.5)."
}

# Prints the committed SHA-256 for a pinned version, or aborts.
pinned_manifest_sha256() {
  local version="$1"

  if [[ "${version}" == "${CM_PINNED_VERSION}" ]]; then
    printf '%s' "${CM_PINNED_MANIFEST_SHA256}"
    return 0
  fi

  die "Version '${version}' has no committed SHA-256 pin. Refusing to install unverified upstream YAML. Verify the release digest and add it to CM_PINNED_VERSION/CM_PINNED_MANIFEST_SHA256 in this script (see README.md) instead of overriding CM_VERSION."
}

# Downloads the pinned manifest into temporary storage and refuses to continue
# unless its SHA-256 matches the committed pin.
download_verified_manifest() {
  local url="$1" expected_sha256="$2" destination="$3" rc=0 actual_sha256=""

  [[ "${url}" =~ ^https://github\.com/cert-manager/cert-manager/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/cert-manager\.yaml$ ]] \
    || die "Refusing unexpected manifest URL (HTTPS host/path allowlist): ${url}"
  [[ "${expected_sha256}" =~ ^[0-9a-f]{64}$ ]] \
    || die "Committed digest for version '${CM_VERSION}' is not a valid SHA-256 value."

  log "Downloading cert-manager ${CM_VERSION} manifest for digest verification..."
  curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --max-time "${CM_DOWNLOAD_TIMEOUT}" \
    --output "${destination}" "${url}" || rc=$?
  [[ "${rc}" -eq 0 ]] || die "Download failed (curl exit ${rc}) for the pinned manifest. Check HTTPS access to the upstream release and retry."

  [[ -s "${destination}" ]] || die "Downloaded manifest is empty; refusing to apply it."

  actual_sha256="$(sha256sum "${destination}" | awk '{print $1}')"
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    die "SHA-256 mismatch for ${url}: expected ${expected_sha256}, got ${actual_sha256}. Refusing to apply unverified YAML; update the committed pin only after reviewing the upstream change."
  fi

  log "Manifest digest verified (sha256=${actual_sha256})"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)."
need kubectl
need curl
need sha256sum
need awk
trap cleanup EXIT

if [[ "${PLATFORMINIT_ALLOW_LIVE_CERT_MANAGER_INSTALL:-}" != "true" ]]; then
  die "Refusing live install. Set PLATFORMINIT_ALLOW_LIVE_CERT_MANAGER_INSTALL=true to acknowledge the upstream manifest install (the manifest is digest-verified before it is applied)."
fi

# Input validation and integrity checks happen before the first cluster call.
validate_version_syntax "${CM_VERSION}" "CM_VERSION"
CM_MANIFEST_SHA256="$(pinned_manifest_sha256 "${CM_VERSION}")"
CM_MANIFEST_URL="${CM_MANIFEST_ORIGIN}/${CM_VERSION}/cert-manager.yaml"

WORK_DIR="$(mktemp -d)"
MANIFEST_FILE="${WORK_DIR}/cert-manager.yaml"
download_verified_manifest "${CM_MANIFEST_URL}" "${CM_MANIFEST_SHA256}" "${MANIFEST_FILE}"

log "Applying verified cert-manager ${CM_VERSION} manifest (idempotent, server-side)..."
kubectl apply --server-side=true -f "${MANIFEST_FILE}"

log "Waiting for cert-manager control plane..."
kubectl -n "${CM_NS}" rollout status deploy/cert-manager --timeout="${CM_TIMEOUT}"
kubectl -n "${CM_NS}" rollout status deploy/cert-manager-webhook --timeout="${CM_TIMEOUT}"
kubectl -n "${CM_NS}" rollout status deploy/cert-manager-cainjector --timeout="${CM_TIMEOUT}"

if [[ -n "${CF_API_TOKEN:-}" ]]; then
  log "Syncing secret ${CF_SECRET_NAME} in namespace ${CM_NS} from CF_API_TOKEN"
  kubectl -n "${CM_NS}" create secret generic "${CF_SECRET_NAME}" \
    --from-literal=api-token="${CF_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Secret synced (value not printed)"
else
  log "CF_API_TOKEN not set: skipping secret sync. Create ${CF_SECRET_NAME} manually before expecting DNS-01 issuance."
fi

log "cert-manager bootstrap complete (version=${CM_VERSION}, sha256=${CM_MANIFEST_SHA256})"
log "ClusterIssuers are reconciled by Argo CD (platform-services ApplicationSet)."
