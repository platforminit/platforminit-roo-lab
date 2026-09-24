#!/usr/bin/env bash
set -euo pipefail
# CH05 Argo CD registration and GitOps source contract validator (P-CH05-T02)
#
# What it proves:
#   1. the operations-stack registration exists in the argocd namespace;
#   2. the live Application source (repoURL and targetRevision) equals the CH05
#      stable/rehearsal source contract for the selected mode, and a rehearsal
#      registration that is actually syncing the stable repository fails;
#   3. the Application has exactly one source and stays inside the operations
#      AppProject, and that AppProject allows only the bounded PlatformInit
#      repository allowlist (no wildcard, no implicit source switching).
#
# Modes:
#   default                            - read-only assertions against the live cluster.
#   CH05_GITOPS_SOURCE_HARNESS_DIR=DIR - repository-only harness mode: the live
#       values are read from plain files in DIR instead of the cluster, so the
#       negative controls can be proven without any cluster access:
#         application.repoURL
#         application.targetRevision
#         application.project
#         application.sources          (optional; "[]" or empty means single-source)
#         appproject.sourceRepos       (one repository URL per line)
#       Harness mode proves rule enforcement only. It is never evidence that a
#       specific cluster is correct; the runtime mode is the release gate.
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
PROJECT_NAME="${PROJECT_NAME:-operations}"

# Mirrors platform/observability/scripts/ch05-register-operations-stack.sh and the
# CH04 contract in platform/cluster/addons/argocd/bootstrap-argocd.sh: both
# repositories share the same file layout, platforminit-platform is the stable
# source of truth and platforminit-roo-lab is the rehearsal mirror.
GITOPS_STABLE_REPO_URL="https://github.com/platforminit/platforminit-platform.git"
GITOPS_REHEARSAL_REPO_URL="https://github.com/platforminit/platforminit-roo-lab.git"
GITOPS_ALLOWED_REPOS=("${GITOPS_REHEARSAL_REPO_URL}" "${GITOPS_STABLE_REPO_URL}")
GITOPS_STABLE_REVISION_DEFAULT="dev"

GITOPS_MODE="${CH05_GITOPS_SOURCE_MODE:-}"
if [[ -z "${GITOPS_MODE}" ]]; then
  if [[ "${PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE:-}" == "true" ]]; then
    GITOPS_MODE="stable"
  else
    GITOPS_MODE="rehearsal"
  fi
fi
case "${GITOPS_MODE}" in
  rehearsal|stable) ;;
  *)
    die "Invalid CH05_GITOPS_SOURCE_MODE='${GITOPS_MODE}'. Use rehearsal or stable; CH05 never guesses the GitOps source."
    ;;
esac
if [[ "${GITOPS_MODE}" == "rehearsal" && "${PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE:-}" == "true" ]]; then
  die "Contradictory GitOps source expectation: CH05_GITOPS_SOURCE_MODE=rehearsal with PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true. Unset the promotion flag or select stable mode explicitly."
fi

if [[ "${GITOPS_MODE}" == "stable" ]]; then
  EXPECTED_REPO_URL="${GITOPS_STABLE_REPO_URL}"
  if [[ "${PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE:-}" != "true" ]]; then
    die "Refusing to validate a stable source expectation without the promotion flag: set PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true only in the promoted stable repository, or validate the rehearsal mirror instead."
  fi
  EXPECTED_TARGET_REVISION="${TARGET_REVISION:-${GITOPS_STABLE_REVISION_DEFAULT}}"
  if [[ "${EXPECTED_TARGET_REVISION}" =~ ^[0-9a-f]{7,39}$ ]]; then
    die "Refusing the abbreviated revision '${EXPECTED_TARGET_REVISION}' as a stable source expectation: an abbreviated commit SHA is the rehearsal artifact revision, never a promoted stable revision. Validate the promoted branch or the full 40-character commit SHA, or validate the rehearsal mirror instead."
  fi
else
  EXPECTED_REPO_URL="${GITOPS_REHEARSAL_REPO_URL}"
  EXPECTED_TARGET_REVISION="${TARGET_REVISION:-}"
  [[ -n "${EXPECTED_TARGET_REVISION}" ]] || die "CH05 rehearsal validation requires the pinned revision: set TARGET_REVISION to the artifact commit SHA. Without it the expected source is not deterministic, so the registration cannot be certified."
  if [[ ! "${EXPECTED_TARGET_REVISION}" =~ ^[0-9a-f]{7,40}$ && "${CH05_GITOPS_ALLOW_BRANCH_REHEARSAL_REVISION:-}" != "true" ]]; then
    die "Refusing the rehearsal targetRevision '${EXPECTED_TARGET_REVISION}': a rehearsal source must be pinned to a commit SHA. For a deliberate branch rehearsal set CH05_GITOPS_ALLOW_BRANCH_REHEARSAL_REVISION=true."
  fi
fi

HARNESS_DIR="${CH05_GITOPS_SOURCE_HARNESS_DIR:-}"
if [[ -n "${HARNESS_DIR}" ]]; then
  [[ -d "${HARNESS_DIR}" ]] || die "CH05_GITOPS_SOURCE_HARNESS_DIR='${HARNESS_DIR}' is not a directory."
  for harness_input in application.repoURL application.targetRevision application.project appproject.sourceRepos; do
    [[ -f "${HARNESS_DIR}/${harness_input}" ]] || die "harness input missing: ${HARNESS_DIR}/${harness_input}"
  done
  LIVE_REPO_URL="$(cat "${HARNESS_DIR}/application.repoURL")"
  LIVE_TARGET_REVISION="$(cat "${HARNESS_DIR}/application.targetRevision")"
  LIVE_PROJECT="$(cat "${HARNESS_DIR}/application.project")"
  LIVE_MULTI_SOURCES=""
  if [[ -f "${HARNESS_DIR}/application.sources" ]]; then
    LIVE_MULTI_SOURCES="$(cat "${HARNESS_DIR}/application.sources")"
  fi
  LIVE_SOURCE_REPOS="$(cat "${HARNESS_DIR}/appproject.sourceRepos")"
  log "Harness mode: validating the CH05 registration contract from ${HARNESS_DIR} without cluster access"
else
  need kubectl
  kubectl -n "${ARGOCD_NAMESPACE}" get appproject.argoproj.io "${PROJECT_NAME}" >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" get application.argoproj.io "${APP_NAME}" >/dev/null
  LIVE_REPO_URL="$(kubectl -n "${ARGOCD_NAMESPACE}" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.source.repoURL}')"
  LIVE_TARGET_REVISION="$(kubectl -n "${ARGOCD_NAMESPACE}" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.source.targetRevision}')"
  LIVE_PROJECT="$(kubectl -n "${ARGOCD_NAMESPACE}" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.project}')"
  # A single-source Application has no spec.sources list; jsonpath prints nothing
  # for the missing field, which is the expected contract state.
  LIVE_MULTI_SOURCES="$(kubectl -n "${ARGOCD_NAMESPACE}" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.sources}' 2>/dev/null || true)"
  LIVE_SOURCE_REPOS="$(kubectl -n "${ARGOCD_NAMESPACE}" get appproject.argoproj.io "${PROJECT_NAME}" -o jsonpath='{range .spec.sourceRepos[*]}{.}{"\n"}{end}')"
fi

source_allowed() {
  local candidate="$1" allowed
  for allowed in "${GITOPS_ALLOWED_REPOS[@]}"; do
    if [[ "${candidate}" == "${allowed}" ]]; then
      return 0
    fi
  done
  return 1
}

if ! source_allowed "${LIVE_REPO_URL}"; then
  die "CH05 registration source '${LIVE_REPO_URL}' is outside the bounded PlatformInit allowlist (${GITOPS_ALLOWED_REPOS[*]})."
fi
if [[ "${LIVE_REPO_URL}" != "${EXPECTED_REPO_URL}" ]]; then
  if [[ "${GITOPS_MODE}" == "rehearsal" && "${LIVE_REPO_URL}" == "${GITOPS_STABLE_REPO_URL}" ]]; then
    die "CH05 rehearsal registration is syncing the stable source (${GITOPS_STABLE_REPO_URL}) instead of the rehearsal mirror (${GITOPS_REHEARSAL_REPO_URL}). The roo-lab rehearsal must never reconcile the promoted stable repository: re-register with CH05_GITOPS_SOURCE_MODE=rehearsal and TARGET_REVISION=<artifact commit>."
  fi
  die "CH05 registration source does not match the contract for mode=${GITOPS_MODE}: live repoURL='${LIVE_REPO_URL}' but the contract requires '${EXPECTED_REPO_URL}'."
fi
if [[ "${LIVE_TARGET_REVISION}" != "${EXPECTED_TARGET_REVISION}" ]]; then
  die "CH05 registration revision does not match the contract for mode=${GITOPS_MODE}: live targetRevision='${LIVE_TARGET_REVISION}' but the contract requires '${EXPECTED_TARGET_REVISION}'."
fi
if [[ -n "${LIVE_MULTI_SOURCES}" && "${LIVE_MULTI_SOURCES}" != "[]" ]]; then
  die "CH05 Application ${APP_NAME} declares additional spec.sources (${LIVE_MULTI_SOURCES}). Exactly one source is allowed so an extra repository can never be synced alongside the contract source."
fi
if [[ "${LIVE_PROJECT}" != "${PROJECT_NAME}" ]]; then
  die "CH05 Application ${APP_NAME} runs in AppProject '${LIVE_PROJECT}' instead of '${PROJECT_NAME}'; the bounded ${PROJECT_NAME} source allowlist must stay in force."
fi

[[ -n "${LIVE_SOURCE_REPOS}" ]] || die "AppProject ${PROJECT_NAME} declares an empty sourceRepos list; the CH05 contract requires the bounded PlatformInit repository allowlist."
project_expectation_present="false"
while IFS= read -r project_source; do
  [[ -n "${project_source}" ]] || continue
  if [[ "${project_source}" == *"*"* ]]; then
    die "AppProject ${PROJECT_NAME} allows the wildcard source '${project_source}'. Source allowlisting must stay bounded to ${GITOPS_ALLOWED_REPOS[*]}."
  fi
  if ! source_allowed "${project_source}"; then
    die "AppProject ${PROJECT_NAME} allows the source '${project_source}', which is outside the bounded PlatformInit allowlist (${GITOPS_ALLOWED_REPOS[*]})."
  fi
  if [[ "${project_source}" == "${EXPECTED_REPO_URL}" ]]; then
    project_expectation_present="true"
  fi
done <<< "${LIVE_SOURCE_REPOS}"
if [[ "${project_expectation_present}" != "true" ]]; then
  die "AppProject ${PROJECT_NAME} does not allow the contract source '${EXPECTED_REPO_URL}' for mode=${GITOPS_MODE}."
fi

log "PASS: operations-stack Argo CD registration exists"
log "PASS: source contract mode=${GITOPS_MODE} repoURL=${EXPECTED_REPO_URL} targetRevision=${EXPECTED_TARGET_REVISION} matches the live Application"
log "PASS: ${APP_NAME} is single-source and stays inside AppProject ${PROJECT_NAME}"
log "PASS: AppProject ${PROJECT_NAME} source allowlist stays bounded to ${GITOPS_ALLOWED_REPOS[*]}"
echo "PASS: operations-stack Argo CD registration exists"
