#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH04.5][AUTHENTIK_CORE][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Bounded input contract (P-CH04.5-T02)
#
# Every input that influences this deployment is either a pinned default in
# this file or an explicitly validated override. Secret *values* are never
# logged; only secret env *names* ever appear in output.
# ---------------------------------------------------------------------------
DEPLOY_MODE="${DEPLOY_MODE:-baseline}"
ISSUER_MODE="${ISSUER_MODE:-staging}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
NAMESPACE="${NAMESPACE:-identity}"
NAMESPACE_OWNER="${NAMESPACE_OWNER:-platforminit}"
ALLOW_NAMESPACE_ADOPTION="${ALLOW_NAMESPACE_ADOPTION:-false}"
PREFLIGHT_ONLY="${PREFLIGHT_ONLY:-false}"
AUTHENTIK_CHART_VERSION="${AUTHENTIK_CHART_VERSION:-2026.2.2}"
AUTHENTIK_IMAGE_REPOSITORY="${AUTHENTIK_IMAGE_REPOSITORY:-ghcr.io/goauthentik/server}"
AUTHENTIK_IMAGE_TAG="${AUTHENTIK_IMAGE_TAG:-}"
AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-admin@${BASE_DOMAIN}}"
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"

# Secret env values that must be present before any mutation happens.
REQUIRED_SECRET_ENVS=(AUTHENTIK_SECRET_KEY AUTHENTIK_POSTGRESQL_PASSWORD AUTHENTIK_BOOTSTRAP_PASSWORD)
VALUES_FILE="${REPO_ROOT}/values/authentik-values.yaml.tpl"
RESOLVED_IMAGE_TAG=""
TMP_DIRS=()

case "${DEPLOY_MODE}" in
  baseline|reconcile) ;;
  *) die "DEPLOY_MODE must be baseline or reconcile, got: ${DEPLOY_MODE}" ;;
esac

case "${ISSUER_MODE}" in
  staging|prod) ;;
  *) die "ISSUER_MODE must be staging or prod, got: ${ISSUER_MODE}" ;;
esac

CLUSTER_ISSUER="letsencrypt-${ISSUER_MODE}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

cleanup_tmp_dirs() {
  local dir
  for dir in "${TMP_DIRS[@]:-}"; do
    [[ -n "$dir" ]] || continue
    rm -rf -- "$dir"
  done
}
trap cleanup_tmp_dirs EXIT

require_secret_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || die "Missing required secret/env: ${name}"
  [[ "$value" != *$'\n'* ]] || die "Secret/env ${name} must not contain newlines"
}

preflight_inputs() {
  # Exact chart pin only: ranges, floating selectors and empty values are rejected.
  [[ "${AUTHENTIK_CHART_VERSION}" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]] \
    || die "AUTHENTIK_CHART_VERSION must be an exact pinned chart version (for example 2026.2.2), got: ${AUTHENTIK_CHART_VERSION}"

  if [[ -n "${AUTHENTIK_IMAGE_TAG}" ]]; then
    [[ "${AUTHENTIK_IMAGE_TAG}" != "latest" ]] || die "AUTHENTIK_IMAGE_TAG must not be 'latest'"
    [[ "${AUTHENTIK_IMAGE_TAG}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
      || die "AUTHENTIK_IMAGE_TAG must be an explicit tag, got: ${AUTHENTIK_IMAGE_TAG}"
  fi

  [[ "${AUTHENTIK_IMAGE_REPOSITORY}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] \
    || die "AUTHENTIK_IMAGE_REPOSITORY is not a valid image repository: ${AUTHENTIK_IMAGE_REPOSITORY}"
  [[ "${NAMESPACE}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "NAMESPACE must be a valid DNS-1123 label, got: ${NAMESPACE}"
  [[ "${NAMESPACE_OWNER}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] \
    || die "NAMESPACE_OWNER must be a valid label value, got: ${NAMESPACE_OWNER}"
  [[ "${BASE_DOMAIN}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] \
    || die "BASE_DOMAIN must be a hostname, got: ${BASE_DOMAIN}"
  [[ "${AUTHENTIK_BOOTSTRAP_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "AUTHENTIK_BOOTSTRAP_EMAIL must look like an email address, got: ${AUTHENTIK_BOOTSTRAP_EMAIL}"
  [[ "${ALLOW_NAMESPACE_ADOPTION}" =~ ^(true|false)$ ]] \
    || die "ALLOW_NAMESPACE_ADOPTION must be true or false, got: ${ALLOW_NAMESPACE_ADOPTION}"
  [[ "${PREFLIGHT_ONLY}" =~ ^(true|false)$ ]] \
    || die "PREFLIGHT_ONLY must be true or false, got: ${PREFLIGHT_ONLY}"
  [[ -f "${VALUES_FILE}" ]] || die "Missing values file: ${VALUES_FILE}"

  log "Input contract OK: chart=${AUTHENTIK_CHART_VERSION} namespace=${NAMESPACE} owner=${NAMESPACE_OWNER} issuer=${CLUSTER_ISSUER} deploy_mode=${DEPLOY_MODE} base_domain=${BASE_DOMAIN} preflight_only=${PREFLIGHT_ONLY}"
}

preflight_secret_envs() {
  # Fail-safe secret preflight. Presence and shape only: values are read from
  # the environment, never printed, and never written anywhere but the
  # Kubernetes Secret at apply time.
  local name
  for name in "${REQUIRED_SECRET_ENVS[@]}"; do
    require_secret_env "$name"
  done

  log "Secret preflight OK: required secret env names present (${REQUIRED_SECRET_ENVS[*]}); values are never logged"
}

preflight_namespace_ownership() {
  # Read-only ownership check. The namespace is never labelled or created here.
  # This is a fail-safe gate: a namespace that cannot be *read* (unreachable or
  # unauthorized API) is never silently treated as "does not exist", because
  # that would authorise namespace creation instead of aborting.
  local owner probe
  if ! owner="$(kubectl get ns "${NAMESPACE}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)"; then
    probe="$(kubectl get ns "${NAMESPACE}" 2>&1 || true)"
    if [[ "${probe}" == *NotFound* || "${probe}" == *"not found"* ]]; then
      log "Namespace preflight: ${NAMESPACE} does not exist and will be created"
      return 0
    fi
    die "Namespace preflight: cannot read namespace ${NAMESPACE}: ${probe}"
  fi

  if [[ -z "${owner}" ]]; then
    [[ "${ALLOW_NAMESPACE_ADOPTION}" == "true" ]] \
      || die "Namespace ${NAMESPACE} exists without an app.kubernetes.io/part-of label; set ALLOW_NAMESPACE_ADOPTION=true to adopt it explicitly"
    log "Namespace preflight: adopting unlabeled namespace ${NAMESPACE} (ALLOW_NAMESPACE_ADOPTION=true)"
    return 0
  fi

  [[ "${owner}" == "${NAMESPACE_OWNER}" ]] \
    || die "Namespace ${NAMESPACE} is owned by '${owner}', expected '${NAMESPACE_OWNER}'; refusing to deploy into a foreign namespace"

  log "Namespace preflight: ownership OK (${NAMESPACE} -> ${owner})"
}

assert_image_reference_pinned() {
  local image="$1"
  [[ -n "${image}" ]] || die "Empty image reference in rendered chart"

  case "${image}" in
    *":latest") die "Floating image tag ':latest' is not allowed: ${image}" ;;
    *"@sha256:"*) return 0 ;;
  esac

  local tail="${image##*/}"
  [[ "${tail}" == *:* ]] || die "Untagged image reference (implicit latest) is not allowed: ${image}"
  [[ -n "${tail##*:}" ]] || die "Empty image tag is not allowed: ${image}"
}

ensure_runtime_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates gnupg rsync openssl >/dev/null
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
}

ensure_cluster_ready() {
  need kubectl
  [ -f "${KUBECONFIG}" ] || die "Missing kubeconfig: ${KUBECONFIG}"
  kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1 || die "kubectl cannot access cluster via ${KUBECONFIG}"
}

ensure_namespace() {
  if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl create namespace "${NAMESPACE}"
  fi
  kubectl label ns "${NAMESPACE}" app.kubernetes.io/part-of="${NAMESPACE_OWNER}" --overwrite >/dev/null
}

resolve_bootstrap_token() {
  if [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    return 0
  fi

  if kubectl -n "${NAMESPACE}" get secret authentik-bootstrap >/dev/null 2>&1; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(kubectl -n "${NAMESPACE}" get secret authentik-bootstrap -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' 2>/dev/null | base64 -d || true)"
  fi

  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
  fi
}

apply_secrets() {
  require_secret_env AUTHENTIK_SECRET_KEY
  require_secret_env AUTHENTIK_POSTGRESQL_PASSWORD
  require_secret_env AUTHENTIK_BOOTSTRAP_PASSWORD
  resolve_bootstrap_token

  kubectl -n "${NAMESPACE}" create secret generic authentik-core \
    --from-literal=secret-key="${AUTHENTIK_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "${NAMESPACE}" create secret generic authentik-postgresql-credentials \
    --from-literal=password="${AUTHENTIK_POSTGRESQL_PASSWORD}" \
    --from-literal=postgres-password="${AUTHENTIK_POSTGRESQL_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "${NAMESPACE}" create secret generic authentik-bootstrap \
    --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL}" \
    --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="${AUTHENTIK_BOOTSTRAP_PASSWORD}" \
    --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

install_repos() {
  # Idempotent: --force-update replaces an existing repo entry instead of failing.
  helm repo add --force-update authentik https://charts.goauthentik.io >/dev/null
  helm repo update >/dev/null
}

resolve_pinned_image_tag() {
  local app_version
  app_version="$(helm show chart authentik/authentik --version "${AUTHENTIK_CHART_VERSION}" \
    | awk '$1 == "appVersion:" { gsub(/"/, "", $2); print $2; exit }')"

  [[ -n "${app_version}" ]] || die "Could not resolve appVersion for authentik chart ${AUTHENTIK_CHART_VERSION}"
  [[ "${app_version}" != "latest" ]] || die "Chart ${AUTHENTIK_CHART_VERSION} resolves to a floating appVersion"
  [[ -z "${AUTHENTIK_IMAGE_TAG}" || "${AUTHENTIK_IMAGE_TAG}" == "${app_version}" ]] \
    || die "AUTHENTIK_IMAGE_TAG=${AUTHENTIK_IMAGE_TAG} does not match the pinned chart ${AUTHENTIK_CHART_VERSION} appVersion=${app_version}"

  RESOLVED_IMAGE_TAG="${app_version}"
  log "Pinned chart inputs: chart=${AUTHENTIK_CHART_VERSION} appVersion=${RESOLVED_IMAGE_TAG} repository=${AUTHENTIK_IMAGE_REPOSITORY}"
}

preflight_rendered_images() {
  # Renders the exact chart/values pair that will be installed and rejects any
  # floating (:latest / untagged) image reference before cluster mutation.
  local rendered images image
  rendered="$(helm template authentik authentik/authentik \
    --namespace "${NAMESPACE}" \
    --version "${AUTHENTIK_CHART_VERSION}" \
    -f "${VALUES_FILE}")"

  images="$(printf '%s\n' "${rendered}" \
    | sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*image:[[:space:]]*//p' \
    | tr -d "\"'" \
    | sed 's/[[:space:]]*$//' \
    | sort -u)"

  [[ -n "${images}" ]] || die "Rendered chart ${AUTHENTIK_CHART_VERSION} contains no image references; refusing to deploy"

  while IFS= read -r image; do
    [[ -n "${image}" ]] || continue
    assert_image_reference_pinned "${image}"
    log "Rendered image is pinned: ${image}"
  done <<< "${images}"

  grep -q ":${RESOLVED_IMAGE_TAG}$" <<< "${images}" \
    || die "Rendered chart does not reference the pinned tag ${RESOLVED_IMAGE_TAG}"
}

verify_deployed_images() {
  local workload images image
  for workload in deployment/authentik-server deployment/authentik-worker; do
    images="$(kubectl -n "${NAMESPACE}" get "${workload}" -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}')"
    [[ -n "${images}" ]] || die "No container images found on ${workload}"

    while IFS= read -r image; do
      [[ -n "${image}" ]] || continue
      assert_image_reference_pinned "${image}"
      [[ "${image}" == *":${RESOLVED_IMAGE_TAG}" || "${image}" == *"@sha256:"* ]] \
        || die "${workload} runs image ${image}, expected the pinned tag ${RESOLVED_IMAGE_TAG}"
      log "Deployed image verified: ${workload} -> ${image}"
    done <<< "${images}"
  done
}

deploy_authentik() {
  log "Deploying Authentik chart ${AUTHENTIK_CHART_VERSION} into namespace ${NAMESPACE}"
  # Same chart pin and same values file as preflight_rendered_images, so the
  # asserted images are the images that get installed.
  helm upgrade --install authentik authentik/authentik \
    --namespace "${NAMESPACE}" \
    --version "${AUTHENTIK_CHART_VERSION}" \
    -f "${VALUES_FILE}" \
    --wait --timeout 20m
}


configure_authentik_public_host() {
  local public_host="https://auth.${BASE_DOMAIN}"
  log "Configuring Authentik public host for embedded outpost: ${public_host}"
  kubectl -n "${NAMESPACE}" set env deployment/authentik-server \
    AUTHENTIK_HOST="${public_host}" \
    AUTHENTIK_HOST_BROWSER="${public_host}" >/dev/null
  kubectl -n "${NAMESPACE}" set env deployment/authentik-worker \
    AUTHENTIK_HOST="${public_host}" \
    AUTHENTIK_HOST_BROWSER="${public_host}" >/dev/null
}

render_apply_ingress() {
  local tmp_dir=""
  tmp_dir="$(mktemp -d)"
  TMP_DIRS+=("${tmp_dir}")

  # Quoted heredoc + environment variables keeps operator input out of the
  # generated Python source. Cleanup runs from the EXIT trap.
  BASE_DOMAIN="${BASE_DOMAIN}" CLUSTER_ISSUER="${CLUSTER_ISSUER}" REPO_ROOT="${REPO_ROOT}" OUT_DIR="${tmp_dir}" \
  python3 - <<'PY'
import os
from pathlib import Path

base_domain = os.environ["BASE_DOMAIN"]
cluster_issuer = os.environ["CLUSTER_ISSUER"]
repo = Path(os.environ["REPO_ROOT"])
out = Path(os.environ["OUT_DIR"])

for name in ["authentik-certificate.yaml", "authentik-ingress.yaml"]:
    text = (repo / "ingress" / name).read_text()
    text = text.replace("__BASE_DOMAIN__", base_domain).replace("__CLUSTER_ISSUER__", cluster_issuer)
    (out / name).write_text(text)
PY

  kubectl apply -f "${tmp_dir}/authentik-certificate.yaml"
  kubectl apply -f "${tmp_dir}/authentik-ingress.yaml"
}

wait_for_rollouts() {
  log "Waiting for Authentik rollouts"
  kubectl -n "${NAMESPACE}" rollout status statefulset/authentik-postgresql --timeout=600s || true
  kubectl -n "${NAMESPACE}" rollout status deployment/authentik-server --timeout=600s
  kubectl -n "${NAMESPACE}" rollout status deployment/authentik-worker --timeout=600s
}

main() {
  # Phase 1 - fail-safe preflight. Strictly read-only: no apt-get, no helm
  # install, no helm repo add/update and no kubectl mutation runs before the
  # secret and namespace ownership gates have passed. If either gate fails, the
  # host and the cluster are left exactly as they were found.
  preflight_inputs
  preflight_secret_envs
  ensure_cluster_ready
  preflight_namespace_ownership

  # Phase 2 - bounded preparation and image-pin preflight. These steps may
  # mutate host tooling and local Helm configuration, but never the cluster,
  # and only after phase 1 has passed.
  ensure_runtime_deps
  ensure_helm
  install_repos
  resolve_pinned_image_tag
  preflight_rendered_images

  if [[ "${PREFLIGHT_ONLY}" == "true" ]]; then
    log "PREFLIGHT_ONLY=true: input, secret and namespace preflight passed and no cluster mutation was performed"
    exit 0
  fi

  # Phase 3 - cluster mutation. Every step below is idempotent and safe to re-run.
  ensure_namespace
  apply_secrets
  deploy_authentik
  verify_deployed_images
  configure_authentik_public_host
  render_apply_ingress
  wait_for_rollouts
  log "CH04.5 Authentik core deploy completed with deploy_mode=${DEPLOY_MODE} issuer=${CLUSTER_ISSUER} chart=${AUTHENTIK_CHART_VERSION} image_tag=${RESOLVED_IMAGE_TAG} url=https://auth.${BASE_DOMAIN}"
  log "Idempotent re-run contract: same inputs and same chart pin converge on the same release, secrets, ingress and images."
}

main "$@"
