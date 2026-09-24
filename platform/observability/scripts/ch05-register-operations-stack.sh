#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

############################################
# CH05 stable/rehearsal GitOps source contract (P-CH05-T02)
#
# Both PlatformInit repositories share the same file layout:
#   * GITOPS_STABLE_REPO_URL    - stable source of truth. A promoted revision and
#     an explicit promotion flag are required before CH05 may sync from it.
#   * GITOPS_REHEARSAL_REPO_URL - rehearsal mirror used by the disposable
#     roo-lab workflow rehearsal.
#
# The CH05 Argo CD source is never selected implicitly and never switched
# silently:
#   * CH05_GITOPS_SOURCE_MODE (rehearsal|stable) selects the repository. In the
#     promoted stable repository PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true
#     selects stable mode without a second variable, exactly like the CH04 Argo CD
#     bootstrap contract in platform/cluster/addons/argocd/bootstrap-argocd.sh;
#     an explicit mode always wins and a contradictory combination is fatal.
#   * TARGET_REVISION selects the revision. A rehearsal registration must be
#     pinned to a commit SHA (a floating branch rehearsal needs the explicit
#     CH05_GITOPS_ALLOW_BRANCH_REHEARSAL_REVISION=true opt-in), and a stable
#     registration defaults to GITOPS_STABLE_REVISION_DEFAULT, the promoted
#     branch that the first CH05 generation already used for the stable
#     repository.
#   * PLATFORM_REPO_URL may confirm the mode but can never redirect it, and any
#     repository outside GITOPS_ALLOWED_REPOS is refused before the first
#     cluster call, so a supplied value cannot start an implicit source switch.
#
# The resolved contract is asserted against the live Application after apply, so
# a registration that did not land the contract source fails immediately instead
# of syncing an unintended repository.
############################################
GITOPS_STABLE_REPO_URL="https://github.com/platforminit/platforminit-platform.git"
GITOPS_REHEARSAL_REPO_URL="https://github.com/platforminit/platforminit-roo-lab.git"
GITOPS_ALLOWED_REPOS=("${GITOPS_REHEARSAL_REPO_URL}" "${GITOPS_STABLE_REPO_URL}")
GITOPS_STABLE_REVISION_DEFAULT="dev"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
OPERATIONS_NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-prod}"
# The Application name is the ownership-of-record identity of the CH05 runtime and
# is fixed by argocd/operations-stack-application.yaml.tpl; it is intentionally not
# overridable, so a rename can never register a second CH05 runtime.
APP_NAME="operations-stack"
APP_PROJECT="operations"
APP_TEMPLATE_REL="argocd/operations-stack-application.yaml.tpl"
APP_PROJECT_REL="argocd/operations-project.yaml"

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
    die "Invalid CH05_GITOPS_SOURCE_MODE='${GITOPS_MODE}'. Use rehearsal (roo-lab mirror, pinned commit) or stable (promoted source of truth, requires PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true)."
    ;;
esac
if [[ "${GITOPS_MODE}" == "rehearsal" && "${PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE:-}" == "true" ]]; then
  die "Contradictory GitOps source request: CH05_GITOPS_SOURCE_MODE=rehearsal with PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true. Unset the promotion flag or select stable mode explicitly; CH05 never guesses between the stable source and the rehearsal mirror."
fi

if [[ "${GITOPS_MODE}" == "stable" ]]; then
  GITOPS_EXPECTED_REPO_URL="${GITOPS_STABLE_REPO_URL}"
  if [[ "${PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE:-}" != "true" ]]; then
    die "Refusing the stable source (${GITOPS_STABLE_REPO_URL}) for CH05. Set PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE=true only in the promoted stable repository, or register the rehearsal mirror with CH05_GITOPS_SOURCE_MODE=rehearsal and a pinned commit."
  fi
  TARGET_REVISION="${TARGET_REVISION:-${GITOPS_STABLE_REVISION_DEFAULT}}"
  if [[ "${TARGET_REVISION}" =~ ^[0-9a-f]{7,39}$ ]]; then
    die "Refusing the abbreviated revision '${TARGET_REVISION}' as a stable source revision: an abbreviated commit SHA is the rehearsal artifact revision, never a promoted stable revision, so syncing it from ${GITOPS_STABLE_REPO_URL} would mix the two sources. Use the promoted branch or the full 40-character commit SHA."
  fi
else
  GITOPS_EXPECTED_REPO_URL="${GITOPS_REHEARSAL_REPO_URL}"
  TARGET_REVISION="${TARGET_REVISION:-}"
  [[ -n "${TARGET_REVISION}" ]] || die "CH05 rehearsal registration requires a pinned revision: set TARGET_REVISION to the artifact commit SHA (workflow input target_revision; its default is the 00 - Build Platform Artifacts commit). CH05 never falls back to a floating branch in rehearsal mode."
  if [[ ! "${TARGET_REVISION}" =~ ^[0-9a-f]{7,40}$ && "${CH05_GITOPS_ALLOW_BRANCH_REHEARSAL_REVISION:-}" != "true" ]]; then
    die "Refusing rehearsal targetRevision '${TARGET_REVISION}': a rehearsal source must be pinned to a commit SHA so the synced revision stays deterministic. For a deliberate branch rehearsal set CH05_GITOPS_ALLOW_BRANCH_REHEARSAL_REVISION=true."
  fi
fi
[[ "${TARGET_REVISION}" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Unsupported targetRevision: '${TARGET_REVISION}'"

PLATFORM_REPO_URL="${PLATFORM_REPO_URL:-${GITOPS_EXPECTED_REPO_URL}}"
if [[ "${PLATFORM_REPO_URL}" != "${GITOPS_EXPECTED_REPO_URL}" ]]; then
  die "Refusing an implicit GitOps source switch: CH05_GITOPS_SOURCE_MODE=${GITOPS_MODE} selects ${GITOPS_EXPECTED_REPO_URL}, but PLATFORM_REPO_URL=${PLATFORM_REPO_URL} was supplied. Align the value, or select the mode that matches it explicitly."
fi
[[ "${PLATFORM_REPO_URL}" =~ ^https://[A-Za-z0-9._:/@+-]+$ ]] || die "Unsupported repoURL: '${PLATFORM_REPO_URL}'"
[[ "${PLATFORM_REPO_URL}" != *"@"* ]] || die "Do not embed credentials in PLATFORM_REPO_URL. Register Argo CD repository credentials separately; embedded userinfo would leak tokens into the rendered manifest and into this log."
GITOPS_REPO_ALLOWED="false"
for allowed in "${GITOPS_ALLOWED_REPOS[@]}"; do
  if [[ "${PLATFORM_REPO_URL}" == "${allowed}" ]]; then
    GITOPS_REPO_ALLOWED="true"
  fi
done
if [[ "${GITOPS_REPO_ALLOWED}" != "true" ]]; then
  die "repoURL '${PLATFORM_REPO_URL}' is not an allowed PlatformInit GitOps repository (${GITOPS_ALLOWED_REPOS[*]})."
fi
log "CH05 GitOps source contract resolved: mode=${GITOPS_MODE} repoURL=${PLATFORM_REPO_URL} targetRevision=${TARGET_REVISION}"

export KUBECONFIG
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || die "Missing Argo CD namespace: $ARGOCD_NAMESPACE. Run CH04 first."
[[ -n "$BASE_DOMAIN" ]] || die "Missing BASE_DOMAIN. Set the PLATFORM_BASE_DOMAIN secret or workflow input; do not hardcode domains in CH05."
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
sed -e "s#__REPO_URL__#${PLATFORM_REPO_URL}#g" \
    -e "s#__TARGET_REVISION__#${TARGET_REVISION}#g" \
    -e "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
    -e "s#__TLS_ISSUER__#${TLS_ISSUER}#g" \
    "$REPO_ROOT/${APP_TEMPLATE_REL}" > "$WORKDIR/operations-stack-application.yaml"
log "Applying Operations AppProject (bounded source allowlist: ${GITOPS_ALLOWED_REPOS[*]})"
kubectl apply -f "$REPO_ROOT/${APP_PROJECT_REL}"
log "Registering Argo CD Application ${APP_NAME} source=${PLATFORM_REPO_URL} targetRevision=${TARGET_REVISION} mode=${GITOPS_MODE}"
kubectl apply -f "$WORKDIR/operations-stack-application.yaml"
# CH05 must not auto-sync before 05.1 prerequisite secrets exist.
# Keep the Application registered and OutOfSync until 05.2 explicitly requests a sync.
# Use JSON patch first because older generated Applications may already carry spec.syncPolicy.automated.
kubectl -n "$ARGOCD_NAMESPACE" patch application.argoproj.io "$APP_NAME" \
  --type json \
  -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1 || true
kubectl -n "$ARGOCD_NAMESPACE" patch application.argoproj.io "$APP_NAME" \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true

# Post-apply assertion of the source contract (read-only, idempotent): the live
# Application must carry exactly the resolved source, so a silent switch to another
# repository, another revision, a second source or another AppProject fails here.
observed_repo="$(kubectl -n "$ARGOCD_NAMESPACE" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.source.repoURL}')"
observed_revision="$(kubectl -n "$ARGOCD_NAMESPACE" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.source.targetRevision}')"
observed_project="$(kubectl -n "$ARGOCD_NAMESPACE" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.project}')"
# A single-source Application has no spec.sources list; jsonpath prints nothing for
# the missing field, which is the expected contract state.
observed_sources="$(kubectl -n "$ARGOCD_NAMESPACE" get "application.argoproj.io/${APP_NAME}" -o jsonpath='{.spec.sources}' 2>/dev/null || true)"
[[ "${observed_repo}" == "${PLATFORM_REPO_URL}" ]] || die "Registered Application ${APP_NAME} repoURL='${observed_repo}' does not match the CH05 source contract '${PLATFORM_REPO_URL}' (mode=${GITOPS_MODE})."
[[ "${observed_revision}" == "${TARGET_REVISION}" ]] || die "Registered Application ${APP_NAME} targetRevision='${observed_revision}' does not match the CH05 source contract '${TARGET_REVISION}' (mode=${GITOPS_MODE})."
[[ "${observed_project}" == "${APP_PROJECT}" ]] || die "Registered Application ${APP_NAME} runs in AppProject '${observed_project}' instead of '${APP_PROJECT}'; the bounded source allowlist of the ${APP_PROJECT} AppProject must stay in force."
if [[ -n "${observed_sources}" && "${observed_sources}" != "[]" ]]; then
  die "Registered Application ${APP_NAME} declares additional spec.sources (${observed_sources}). CH05 allows exactly one source so an extra repository can never be synced alongside the contract source."
fi
log "Operations stack registered under Argo CD ownership; automated sync disabled by design"
log "Source contract verified on the live Application: project=${observed_project} repoURL=${observed_repo} targetRevision=${observed_revision}"
kubectl -n "$ARGOCD_NAMESPACE" get app "$APP_NAME" -o wide || true
