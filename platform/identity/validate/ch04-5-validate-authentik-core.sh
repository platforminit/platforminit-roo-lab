#!/usr/bin/env bash
set -euo pipefail

ns="${NAMESPACE:-identity}"
base_domain="${BASE_DOMAIN:-sysadminhomelab.hu}"
expected_owner="${NAMESPACE_OWNER:-platforminit}"
expected_chart_version="${AUTHENTIK_CHART_VERSION:-}"

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

assert_pinned_image() {
  local check="$1"
  local image="$2"
  [[ -n "$image" ]] || fail "IMAGE_PIN" "${check} has no container image"

  case "$image" in
    *":latest") fail "IMAGE_PIN" "${check} uses floating tag: ${image}" ;;
    *"@sha256:"*)
      pass "IMAGE_PIN" "${check} pinned by digest: ${image}"
      return 0
      ;;
  esac

  local tail="${image##*/}"
  [[ "$tail" == *:* ]] || fail "IMAGE_PIN" "${check} image is untagged (implicit latest): ${image}"
  local tag="${tail##*:}"
  [[ -n "$tag" ]] || fail "IMAGE_PIN" "${check} image has an empty tag: ${image}"

  if [[ -n "$expected_chart_version" ]]; then
    [[ "$tag" == "$expected_chart_version" ]] \
      || fail "IMAGE_PIN" "${check} tag ${tag} does not match pinned chart ${expected_chart_version}"
  fi

  pass "IMAGE_PIN" "${check} pinned to tag ${tag}"
}

# ---------------------------------------------------------------------------
# Repo-local ordering regression guard (static, no cluster access).
#
# P-CH04.5-T02: the fail-safe secret and namespace preflight must finish before
# any mutable host, Helm or Kubernetes step in the deploy script. This parses
# the deploy script's main() so a future edit cannot silently reintroduce the
# "mutate before preflight" hazard.
# ---------------------------------------------------------------------------
validator_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
deploy_script="${DEPLOY_SCRIPT:-${validator_dir}/../scripts/ch04-5-deploy-authentik-core.sh}"

assert_preflight_ordering() {
  local script="$1"
  [[ -f "$script" ]] || fail "PREFLIGHT_ORDER" "deploy script not found: ${script}"

  local body code_body
  body="$(sed -n '/^main() {/,/^}/p' "$script")"
  [[ -n "$body" ]] || fail "PREFLIGHT_ORDER" "could not extract main() from ${script}"
  # Comment lines are dropped so prose cannot satisfy or trip a token check.
  code_body="$(printf '%s\n' "$body" | grep -v '^[[:space:]]*#' || true)"

  line_of() {
    printf '%s\n' "$code_body" | awk -v fn="$1" '{ for (i = 1; i <= NF; i++) if ($i == fn) { print NR; exit } }'
  }

  local secret_line namespace_line last_preflight
  secret_line="$(line_of preflight_secret_envs)"
  namespace_line="$(line_of preflight_namespace_ownership)"
  [[ -n "$secret_line" ]] || fail "PREFLIGHT_ORDER" "main() never calls preflight_secret_envs"
  [[ -n "$namespace_line" ]] || fail "PREFLIGHT_ORDER" "main() never calls preflight_namespace_ownership"

  last_preflight="$secret_line"
  if [[ "$namespace_line" -gt "$last_preflight" ]]; then
    last_preflight="$namespace_line"
  fi

  local step step_line
  for step in ensure_runtime_deps ensure_helm install_repos ensure_namespace \
              apply_secrets deploy_authentik configure_authentik_public_host \
              render_apply_ingress wait_for_rollouts; do
    step_line="$(line_of "$step")"
    [[ -n "$step_line" ]] || continue
    [[ "$step_line" -gt "$last_preflight" ]] \
      || fail "PREFLIGHT_ORDER" "main() calls ${step} (line ${step_line}) before the fail-safe preflight (line ${last_preflight})"
  done

  local pre_segment mutable
  pre_segment="$(printf '%s\n' "$code_body" | head -n "$last_preflight")"
  for mutable in 'apt-get' 'helm repo' 'kubectl create' 'kubectl apply' \
                 'kubectl label' 'kubectl patch' 'kubectl set' 'kubectl delete' \
                 'kubectl rollout' 'helm upgrade' 'helm install'; do
    if printf '%s\n' "$pre_segment" | grep -F -q -- "$mutable"; then
      fail "PREFLIGHT_ORDER" "mutable command '${mutable}' appears before the fail-safe preflight in main()"
    fi
  done

  pass "PREFLIGHT_ORDER" "secret and namespace preflight precede all mutable steps in ${script}"
}

assert_preflight_ordering "$deploy_script"

kubectl get ns "$ns" >/dev/null 2>&1 && pass "NAMESPACE" "${ns} namespace exists" || fail "NAMESPACE" "missing ${ns} namespace"

owner_label="$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
[[ "$owner_label" == "$expected_owner" ]] \
  && pass "NAMESPACE_OWNERSHIP" "${ns} owned by ${expected_owner}" \
  || fail "NAMESPACE_OWNERSHIP" "expected app.kubernetes.io/part-of=${expected_owner}, got ${owner_label:-none}"

kubectl -n "$ns" get secret authentik-core >/dev/null 2>&1 && pass "CORE_SECRET" "authentik core secret exists" || fail "CORE_SECRET" "missing authentik-core secret"
kubectl -n "$ns" get secret authentik-postgresql-credentials >/dev/null 2>&1 && pass "POSTGRES_SECRET" "postgresql credentials secret exists" || fail "POSTGRES_SECRET" "missing authentik-postgresql-credentials secret"
kubectl -n "$ns" get secret authentik-bootstrap >/dev/null 2>&1 && pass "BOOTSTRAP_SECRET" "bootstrap secret exists" || fail "BOOTSTRAP_SECRET" "missing authentik-bootstrap secret"

kubectl -n "$ns" get deploy authentik-server >/dev/null 2>&1 && pass "SERVER_DEPLOYMENT" "authentik-server deployment exists" || fail "SERVER_DEPLOYMENT" "missing authentik-server deployment"
kubectl -n "$ns" get deploy authentik-worker >/dev/null 2>&1 && pass "WORKER_DEPLOYMENT" "authentik-worker deployment exists" || fail "WORKER_DEPLOYMENT" "missing authentik-worker deployment"
kubectl -n "$ns" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && pass "SERVER_ROLLOUT" "authentik-server rollout is healthy" || fail "SERVER_ROLLOUT" "authentik-server rollout not healthy"
kubectl -n "$ns" rollout status deploy/authentik-worker --timeout=10s >/dev/null 2>&1 && pass "WORKER_ROLLOUT" "authentik-worker rollout is healthy" || fail "WORKER_ROLLOUT" "authentik-worker rollout not healthy"

for workload in authentik-server authentik-worker; do
  images="$(kubectl -n "$ns" get deploy "$workload" -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null || true)"
  [[ -n "${images//[[:space:]]/}" ]] || fail "IMAGE_PIN" "no container images found on deployment/${workload}"
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    assert_pinned_image "deployment/${workload}" "$image"
  done <<< "$images"
done

kubectl -n "$ns" get svc authentik-server >/dev/null 2>&1 && pass "SERVER_SERVICE" "authentik-server service exists" || fail "SERVER_SERVICE" "missing authentik-server service"
kubectl -n "$ns" get ingress authentik >/dev/null 2>&1 && pass "INGRESS" "authentik ingress exists" || fail "INGRESS" "missing authentik ingress"
kubectl -n "$ns" get certificate authentik-tls >/dev/null 2>&1 && pass "CERTIFICATE" "authentik certificate exists" || fail "CERTIFICATE" "missing authentik certificate"

host="auth.${base_domain}"
actual_host="$(kubectl -n "$ns" get ingress authentik -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
[[ "$actual_host" == "$host" ]] && pass "INGRESS_HOST" "ingress host is ${host}" || fail "INGRESS_HOST" "expected ${host}, got ${actual_host:-empty}"

ready_pods="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if (a[1]==a[2]) c++} END {print c+0}')"
if [[ "${ready_pods}" -ge 2 ]]; then
  pass "PODS_READY" "${ready_pods} pods report all containers ready"
else
  fail "PODS_READY" "expected at least 2 ready pods, got ${ready_pods}"
fi

cert_ready="$(kubectl -n "$ns" get certificate authentik-tls -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
if [[ "$cert_ready" == "True" ]]; then
  pass "TLS_READY" "authentik certificate is Ready"
else
  warn "TLS_READY" "certificate not Ready yet; DNS/ACME may still be converging"
fi
