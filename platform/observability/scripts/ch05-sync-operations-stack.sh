#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
OPERATIONS_NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
APP_NAME="${APP_NAME:-operations-stack}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
TARGET_REVISION="${TARGET_REVISION:-}"
export KUBECONFIG
need kubectl
need python3
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" >/dev/null || die "Missing Argo CD app: $APP_NAME. Run 05 - Register Operations Stack first."

log "Checking CH05 Checkmk prerequisite secrets before Argo CD sync"
missing=0
for secret in checkmk-admin checkmk-sso; do
  if ! kubectl -n "$OPERATIONS_NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
    echo "MISSING: ${OPERATIONS_NAMESPACE}/${secret}" >&2
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || die "Checkmk prerequisite secrets are missing. Run 05.1 - Reconcile Operations Prerequisites before 05.2."

if [[ -z "$TARGET_REVISION" ]]; then
  TARGET_REVISION="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.spec.source.targetRevision}')"
fi
patch_file="$(mktemp)"
trap 'rm -f "$patch_file"' EXIT
log "Updating $APP_NAME source targetRevision=${TARGET_REVISION}"
python3 -c 'import json,sys; print(json.dumps({"spec":{"source":{"targetRevision":sys.argv[1]}}}))' "$TARGET_REVISION" > "$patch_file"
kubectl -n "$ARGOCD_NAMESPACE" patch application.argoproj.io "$APP_NAME" --type merge --patch-file "$patch_file" >/dev/null
log "Requesting explicit Argo CD sync for $APP_NAME revision=${TARGET_REVISION}"
kubectl -n "$ARGOCD_NAMESPACE" annotate application.argoproj.io "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
python3 -c 'import json,sys; print(json.dumps({"operation":{"sync":{"revision":sys.argv[1],"prune":True,"syncOptions":["CreateNamespace=true","PruneLast=true"]}}}))' "$TARGET_REVISION" > "$patch_file"
if ! kubectl -n "$ARGOCD_NAMESPACE" patch application.argoproj.io "$APP_NAME" --type merge --patch-file "$patch_file" >/dev/null; then
  log "Sync operation patch was rejected, probably because another operation is already running; continuing to observe status"
fi

start="$(date +%s)"
last_diag=0
while true; do
  sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  phase="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  message="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
  log "Argo CD status: sync=${sync_status:-unknown} health=${health_status:-unknown} phase=${phase:-none} message=${message:-none}"
  if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
    log "Checkmk operations stack is synced and healthy"
    break
  fi
  now="$(date +%s)"
  if (( now - last_diag > 60 )); then
    last_diag="$now"
    kubectl -n "$OPERATIONS_NAMESPACE" get pods,svc,ingressroute,pvc 2>/dev/null || true
    kubectl -n "$OPERATIONS_NAMESPACE" get events --sort-by=.lastTimestamp | tail -30 || true
    kubectl -n "$OPERATIONS_NAMESPACE" get pods --no-headers 2>/dev/null | awk '$2 !~ /^2\/2$/ || $3 != "Running" {print $1}' | while read -r pod; do
      [ -n "$pod" ] || continue
      echo "--- diagnostics for pod/${pod} ---"
      kubectl -n "$OPERATIONS_NAMESPACE" describe pod "$pod" | tail -120 || true
      kubectl -n "$OPERATIONS_NAMESPACE" logs "$pod" --all-containers --tail=120 || true
    done
  fi
  if (( now - start > TIMEOUT_SECONDS )); then
    kubectl -n "$ARGOCD_NAMESPACE" describe application.argoproj.io "$APP_NAME" || true
    kubectl -n "$OPERATIONS_NAMESPACE" get pods,svc,ingressroute,pvc || true
    kubectl -n "$OPERATIONS_NAMESPACE" get events --sort-by=.lastTimestamp | tail -80 || true
    die "Timed out waiting for Argo CD Checkmk operations stack to become Synced/Healthy"
  fi
  sleep 15
done
kubectl -n "$OPERATIONS_NAMESPACE" get pods,svc,ingressroute,pvc
