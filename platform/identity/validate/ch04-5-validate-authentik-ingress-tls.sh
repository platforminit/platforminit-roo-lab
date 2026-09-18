#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# CH04.5 - Authentik ingress and TLS contract validation (repository-only)
#
# Task: P-CH04.5-T03. Contract statement:
#   platform/identity/docs/ch04-5-authentik-ingress-tls-contract.md
#
# Static, deterministic and idempotent. It never touches a cluster, DNS,
# Cloudflare, cert-manager, GitHub or a Kubernetes Secret. Every finding is
# aggregated before a non-zero exit so one run reports the whole contract
# surface.
#
# Enforced:
#   1. hostname / Ingress / Certificate / TLS ownership are one consistent set
#   2. single TLS ownership: exactly one repository-wide Ingress route owner
#      for the host, one certificate-minted secret, same namespace as the
#      workload, cluster-scoped Cloudflare DNS-01 ClusterIssuer, no
#      ingress-shim duplicate, no cross-namespace TLS secret reuse
#   3. identity-model bootstrap is decoupled from ingress/TLS reconciliation
#   4. the contract document and the ownership inventory stay consistent
#############################################################################

PASS=0
WARN=0
FAIL=0
MISSING=0

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-ingress-tls] $*"; }
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-ingress-tls][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

INGRESS_FILE="${ROOT_DIR}/platform/identity/ingress/authentik-ingress.yaml"
CERT_FILE="${ROOT_DIR}/platform/identity/ingress/authentik-certificate.yaml"
DEPLOY_SCRIPT="${ROOT_DIR}/platform/identity/scripts/ch04-5-deploy-authentik-core.sh"
BOOTSTRAP_SCRIPT="${ROOT_DIR}/platform/identity/scripts/ch04-5-bootstrap-identity-model.sh"
CONTRACT_DOC="${ROOT_DIR}/platform/identity/docs/ch04-5-authentik-ingress-tls-contract.md"
INVENTORY_DOC="${ROOT_DIR}/platform/identity/docs/ch04-5-identity-ownership-inventory.md"

EXPECTED_HOST_PLACEHOLDER="auth.__BASE_DOMAIN__"
EXPECTED_TLS_SECRET="authentik-tls"
EXPECTED_INGRESS_NAME="authentik"
EXPECTED_NAMESPACE="identity"
EXPECTED_SERVICE="authentik-server"
ISSUER_NAMES=("letsencrypt-staging" "letsencrypt-prod")

# Every literal spelling that resolves to the Authentik host: the template
# placeholder, the rendered base domain the deploy script defaults to, and the
# abstract documentation form.
AUTH_HOST_ANGLE='auth.<PLATFORM_BASE_DOMAIN>'
RENDERED_BASE_DOMAIN=""
if [[ -f "$DEPLOY_SCRIPT" ]]; then
  RENDERED_BASE_DOMAIN="$(sed -nE 's/^BASE_DOMAIN="\$\{BASE_DOMAIN:-([^}]*)\}".*/\1/p' "$DEPLOY_SCRIPT" | head -n1 || true)"
fi
[[ -n "$RENDERED_BASE_DOMAIN" ]] || RENDERED_BASE_DOMAIN="sysadminhomelab.hu"
AUTH_HOST_RENDERED="auth.${RENDERED_BASE_DOMAIN}"

# Directories pruned from every repository-wide manifest scan: VCS metadata,
# vendored/generated content, local secret material and controller-owned task
# state. Scans stay inside ROOT_DIR and are deterministic.
REPO_SCAN_PRUNE_DIRS=(
  .git
  .local_secrets
  .mypy_cache
  .pytest_cache
  .venv
  __pycache__
  artifacts
  build
  coverage
  dist
  node_modules
  out
  reports/generated
  tasks/active
  venv
)

rel() { printf '%s' "${1#"${ROOT_DIR}/"}"; }

summary_exit() {
  log "CH04.5 ingress/TLS contract validation summary: pass=${PASS} warn=${WARN} fail=${FAIL}"
  if (( FAIL > 0 )); then
    echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-ingress-tls][FAIL] contract violations: ${FAIL}" >&2
    exit 1
  fi
  log "PASS: CH04.5 Authentik ingress and TLS contract is consistent (repository-only, no cluster access)"
}

# First value of a zero-indented top-level YAML key.
top_scalar() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -m1 -E "^${key}:[[:space:]]*" "$file" 2>/dev/null \
    | sed -E "s/^${key}:[[:space:]]*//" \
    | tr -d "\"'" \
    | sed -E 's/[[:space:]]+$//' || true
}

# First metadata.<key> value (metadata block only, so spec/status keys cannot
# satisfy the check).
metadata_scalar() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v want="$key" '
    /^metadata:[[:space:]]*$/ { in_meta = 1; next }
    in_meta && /^[^[:space:]]/ { in_meta = 0 }
    in_meta {
      pattern = "^[[:space:]]+" want ":[[:space:]]*"
      if ($0 ~ pattern) {
        line = $0
        sub(pattern, "", line)
        gsub(/["'"'"']/, "", line)
        sub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$file"
}

# First indented "<key>: <value>" scalar in a file (quotes stripped).
first_indented_scalar() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep -m1 -E "^[[:space:]]+${key}:[[:space:]]*" "$file" 2>/dev/null \
    | sed -E "s/^[[:space:]]+${key}:[[:space:]]*//" \
    | tr -d "\"'" \
    | sed -E 's/[[:space:]]+$//' || true
}

# Shell code with comments removed and backslash continuations joined, so a
# token or a kubectl invocation cannot hide behind a comment or a line break.
script_code() {
  local file="$1"
  sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' -e ':a' -e '/\\$/{N; s/\\\n//; ta}' "$file"
}

assert_no_tokens() {
  local label="$1" file="$2" pattern="$3"
  local hits
  hits="$(script_code "$file" | grep -nEi -- "$pattern" || true)"
  if [[ -z "$hits" ]]; then
    pass "${label}: no route/TLS coupling tokens in $(rel "$file")"
  else
    fail "${label}: route/TLS coupling in $(rel "$file"): $(printf '%s' "$hits" | head -n3 | tr '\n' ';')"
  fi
}

# Every kubectl *invocation* in the script must be read-only. A bare command-name
# reference (for example `need kubectl`) is not an invocation and is ignored by
# requiring whitespace after the binary name.
assert_readonly_kubectl() {
  local label="$1" file="$2" code segments segment count=0
  code="$(script_code "$file")"
  if ! printf '%s' "$code" | grep -qF 'kubectl'; then
    fail "${label}: no kubectl usage found in $(rel "$file"); expected read-only cluster access"
    return 0
  fi
  segments="$(printf '%s' "$code" | grep -oE 'kubectl[[:space:]][^;&|]*' || true)"
  if [[ -z "$segments" ]]; then
    fail "${label}: no kubectl invocation could be parsed in $(rel "$file")"
    return 0
  fi
  while IFS= read -r segment; do
    [[ -n "$segment" ]] || continue
    count=$((count + 1))
    if printf '%s' "$segment" | grep -Eq '(^|[[:space:]])(get|rollout[[:space:]]+status|port-forward)([[:space:]]|$)'; then
      continue
    fi
    fail "${label}: non-read-only kubectl invocation in $(rel "$file"): ${segment}"
  done <<< "$segments"
  pass "${label}: all ${count} kubectl invocation(s) in $(rel "$file") are read-only"
}

# "<name>\t<cloudflare-dns01|other-solver>" per committed ClusterIssuer document.
clusterissuer_pairs() {
  local dir="$1" file
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    awk '
      function emit() {
        if (kind == "ClusterIssuer" && name != "") {
          printf "%s\t%s\n", name, (dns01 && cloudflare) ? "cloudflare-dns01" : "other-solver"
        }
      }
      /^---[[:space:]]*$/ { emit(); kind = ""; name = ""; in_meta = 0; dns01 = 0; cloudflare = 0; next }
      { line = $0; sub(/[[:space:]]+#.*$/, "", line) }
      line ~ /^[[:space:]]*kind:[[:space:]]*/ {
        v = line
        sub(/^[[:space:]]*kind:[[:space:]]*/, "", v)
        gsub(/["'"'"']/, "", v)
        kind = v
        next
      }
      line ~ /^metadata:[[:space:]]*$/ { in_meta = 1; next }
      in_meta && line ~ /^[[:space:]]*name:[[:space:]]*/ {
        v = line
        sub(/^[[:space:]]*name:[[:space:]]*/, "", v)
        gsub(/["'"'"']/, "", v)
        sub(/[[:space:]]+$/, "", v)
        if (name == "") { name = v; in_meta = 0 }
        next
      }
      line ~ /^[[:space:]]*-?[[:space:]]*dns01:[[:space:]]*$/ { dns01 = 1 }
      line ~ /^[[:space:]]*-?[[:space:]]*cloudflare:[[:space:]]*$/ { cloudflare = 1 }
      END { emit() }
    ' "$file"
  done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
}

# Deterministic, ROOT_DIR-bounded list of manifest files in the repository
# working tree (generated/vendored/task-state directories pruned).
repo_manifest_files() {
  local conds=(-false) dir
  for dir in "${REPO_SCAN_PRUNE_DIRS[@]}"; do
    conds+=(-o -path "${ROOT_DIR}/${dir}")
  done
  find "${ROOT_DIR}" \( "${conds[@]}" \) -prune -o -type f \
    \( -name '*.yaml' -o -name '*.yml' -o -name '*.tpl' \) -print 2>/dev/null \
    | LC_ALL=C sort
}

# Every <kind> document in the repository working tree, one tab-separated
# record per document:
#   <path>\t<apiVersion>\t<metadata.name>\t<spec secretName>
# With require_host=1 only documents that claim the Authentik host in a
# host:/hosts: position are reported, so a second committed route for the same
# host cannot hide behind a different resource name, label set or directory.
route_owner_docs() {
  local kind_target="$1" require_host="$2" file rel_file
  while IFS= read -r file; do
    rel_file="$(rel "$file")"
    awk -v file_rel="$rel_file" -v target="$kind_target" -v need_host="$require_host" \
        -v host_ph="$EXPECTED_HOST_PLACEHOLDER" -v host_rendered="$AUTH_HOST_RENDERED" \
        -v host_angle="$AUTH_HOST_ANGLE" '
      function scalar(s) {
        sub(/^[[:space:]]+/, "", s)
        sub(/^-+[[:space:]]*/, "", s)
        sub(/^host[[:space:]]*:[[:space:]]*/, "", s)
        sub(/^secretName[[:space:]]*:[[:space:]]*/, "", s)
        gsub(/["'"'"']/, "", s)
        sub(/[[:space:]]+$/, "", s)
        return s
      }
      function flush() {
        if (kind == target && (need_host == 0 || host_seen == 1)) {
          printf "%s\t%s\t%s\t%s\n", file_rel, (api == "" ? "-" : api), (name == "" ? "-" : name), (secret == "" ? "-" : secret)
        }
        api = ""; kind = ""; name = ""; secret = ""; host_seen = 0; in_meta = 0
      }
      /^---[[:space:]]*$/ { flush(); next }
      {
        line = $0
        sub(/[[:space:]]+#.*$/, "", line)
      }
      line ~ /^[[:space:]]*apiVersion[[:space:]]*:/ {
        if (api == "") {
          value = line
          sub(/^[[:space:]]*apiVersion[[:space:]]*:[[:space:]]*/, "", value)
          api = scalar(value)
        }
        next
      }
      line ~ /^[[:space:]]*kind[[:space:]]*:/ {
        if (kind == "") {
          value = line
          sub(/^[[:space:]]*kind[[:space:]]*:[[:space:]]*/, "", value)
          kind = scalar(value)
        }
        next
      }
      line ~ /^metadata[[:space:]]*:[[:space:]]*$/ { in_meta = 1; next }
      in_meta == 1 && line ~ /^[^[:space:]]/ { in_meta = 0 }
      in_meta == 1 && line ~ /^[[:space:]]+name[[:space:]]*:/ {
        if (name == "") {
          value = line
          sub(/^[[:space:]]+name[[:space:]]*:[[:space:]]*/, "", value)
          name = scalar(value)
        }
        next
      }
      line ~ /^[[:space:]]+secretName[[:space:]]*:/ {
        if (secret == "") {
          value = line
          sub(/^[[:space:]]+secretName[[:space:]]*:[[:space:]]*/, "", value)
          secret = scalar(value)
        }
        next
      }
      {
        value = scalar(line)
        if (value == host_ph || value == host_rendered || value == host_angle) { host_seen = 1 }
      }
      END { flush() }
    ' "$file"
  done < <(repo_manifest_files)
}

count_records() {
  local value="$1"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    printf '0'
  else
    printf '%s\n' "$value" | LC_ALL=C grep -c '[^[:space:]]'
  fi
}

records_paths() {
  printf '%s\n' "$1" | awk -F'\t' 'NF { print $1 }'
}

# ---------------------------------------------------------------------------
# 1. Contract artifacts
# ---------------------------------------------------------------------------
for artifact in "$INGRESS_FILE" "$CERT_FILE" "$DEPLOY_SCRIPT" "$BOOTSTRAP_SCRIPT" "$CONTRACT_DOC" "$INVENTORY_DOC"; do
  if [[ -f "$artifact" ]]; then
    pass "artifact present: $(rel "$artifact")"
  else
    MISSING=$((MISSING + 1))
    fail "artifact missing: $(rel "$artifact")"
  fi
done
if (( MISSING > 0 )); then
  log "Required contract artifacts are incomplete; skipping structural checks"
  summary_exit
fi

# ---------------------------------------------------------------------------
# 2. Ingress resource (hostname, class, entrypoint, backend, TLS reference)
# ---------------------------------------------------------------------------
[[ "$(top_scalar "$INGRESS_FILE" kind)" == "Ingress" ]] \
  && pass "INGRESS_KIND: kind is Ingress" \
  || fail "INGRESS_KIND: expected kind Ingress in $(rel "$INGRESS_FILE")"

[[ "$(top_scalar "$INGRESS_FILE" apiVersion)" == "networking.k8s.io/v1" ]] \
  && pass "INGRESS_API: apiVersion is networking.k8s.io/v1" \
  || fail "INGRESS_API: expected networking.k8s.io/v1 in $(rel "$INGRESS_FILE")"

[[ "$(metadata_scalar "$INGRESS_FILE" name)" == "$EXPECTED_INGRESS_NAME" ]] \
  && pass "INGRESS_NAME: name is ${EXPECTED_INGRESS_NAME}" \
  || fail "INGRESS_NAME: expected ${EXPECTED_INGRESS_NAME}, got $(metadata_scalar "$INGRESS_FILE" name)"

[[ "$(metadata_scalar "$INGRESS_FILE" namespace)" == "$EXPECTED_NAMESPACE" ]] \
  && pass "INGRESS_NAMESPACE: namespace is ${EXPECTED_NAMESPACE}" \
  || fail "INGRESS_NAMESPACE: expected ${EXPECTED_NAMESPACE}, got $(metadata_scalar "$INGRESS_FILE" namespace)"

grep -qE '^[[:space:]]*ingressClassName:[[:space:]]*traefik[[:space:]]*$' "$INGRESS_FILE" \
  && pass "INGRESS_CLASS: ingressClassName is traefik" \
  || fail "INGRESS_CLASS: ingressClassName traefik not declared in $(rel "$INGRESS_FILE")"

grep -qE '^[[:space:]]*-?[[:space:]]*host:[[:space:]]*auth\.__BASE_DOMAIN__[[:space:]]*$' "$INGRESS_FILE" \
  && pass "INGRESS_HOST: rule host is ${EXPECTED_HOST_PLACEHOLDER}" \
  || fail "INGRESS_HOST: rule host ${EXPECTED_HOST_PLACEHOLDER} not declared in $(rel "$INGRESS_FILE")"

grep -qE '^[[:space:]]*-[[:space:]]*auth\.__BASE_DOMAIN__[[:space:]]*$' "$INGRESS_FILE" \
  && pass "INGRESS_TLS_HOSTS: TLS host list carries ${EXPECTED_HOST_PLACEHOLDER}" \
  || fail "INGRESS_TLS_HOSTS: TLS host list does not carry ${EXPECTED_HOST_PLACEHOLDER}"

grep -q 'traefik.ingress.kubernetes.io/router.entrypoints' "$INGRESS_FILE" \
  && grep -q 'websecure' "$INGRESS_FILE" \
  && pass "INGRESS_ENTRYPOINT: Traefik websecure entrypoint is declared" \
  || fail "INGRESS_ENTRYPOINT: Traefik websecure entrypoint annotation is missing"

grep -qE "^[[:space:]]*name:[[:space:]]*${EXPECTED_SERVICE}[[:space:]]*$" "$INGRESS_FILE" \
  && grep -qE '^[[:space:]]*number:[[:space:]]*80[[:space:]]*$' "$INGRESS_FILE" \
  && pass "INGRESS_BACKEND: backend is ${EXPECTED_SERVICE}:80" \
  || fail "INGRESS_BACKEND: expected backend ${EXPECTED_SERVICE}:80 in $(rel "$INGRESS_FILE")"

grep -qF 'secretName: '"${EXPECTED_TLS_SECRET}" "$INGRESS_FILE" \
  && pass "INGRESS_TLS_SECRET: tls.secretName is ${EXPECTED_TLS_SECRET}" \
  || fail "INGRESS_TLS_SECRET: tls.secretName ${EXPECTED_TLS_SECRET} not declared in $(rel "$INGRESS_FILE")"

tls_blocks="$(grep -cE '^[[:space:]]*-[[:space:]]*hosts:[[:space:]]*$' "$INGRESS_FILE" || true)"
[[ "${tls_blocks:-0}" == "1" ]] \
  && pass "INGRESS_TLS_BLOCKS: exactly one TLS block is declared" \
  || fail "INGRESS_TLS_BLOCKS: expected exactly one tls block, got ${tls_blocks:-0}"

if grep -qF 'cert-manager.io/' "$INGRESS_FILE"; then
  fail "INGRESS_NO_SHIM: ingress-shim annotation found in $(rel "$INGRESS_FILE"); TLS ownership must stay with the Certificate"
else
  pass "INGRESS_NO_SHIM: no cert-manager.io/* ingress-shim annotation (single TLS owner)"
fi

# ---------------------------------------------------------------------------
# 3. Certificate resource (issuer authority, DNS name, secret)
# ---------------------------------------------------------------------------
[[ "$(top_scalar "$CERT_FILE" kind)" == "Certificate" ]] \
  && pass "CERT_KIND: kind is Certificate" \
  || fail "CERT_KIND: expected kind Certificate in $(rel "$CERT_FILE")"

[[ "$(top_scalar "$CERT_FILE" apiVersion)" == "cert-manager.io/v1" ]] \
  && pass "CERT_API: apiVersion is cert-manager.io/v1" \
  || fail "CERT_API: expected cert-manager.io/v1 in $(rel "$CERT_FILE")"

[[ "$(metadata_scalar "$CERT_FILE" name)" == "$EXPECTED_TLS_SECRET" ]] \
  && pass "CERT_NAME: name is ${EXPECTED_TLS_SECRET}" \
  || fail "CERT_NAME: expected ${EXPECTED_TLS_SECRET}, got $(metadata_scalar "$CERT_FILE" name)"

[[ "$(metadata_scalar "$CERT_FILE" namespace)" == "$EXPECTED_NAMESPACE" ]] \
  && pass "CERT_NAMESPACE: namespace is ${EXPECTED_NAMESPACE}" \
  || fail "CERT_NAMESPACE: expected ${EXPECTED_NAMESPACE}, got $(metadata_scalar "$CERT_FILE" namespace)"

grep -qF 'secretName: '"${EXPECTED_TLS_SECRET}" "$CERT_FILE" \
  && pass "CERT_SECRET: secretName is ${EXPECTED_TLS_SECRET}" \
  || fail "CERT_SECRET: secretName ${EXPECTED_TLS_SECRET} not declared in $(rel "$CERT_FILE")"

grep -qE '^[[:space:]]*kind:[[:space:]]*ClusterIssuer[[:space:]]*$' "$CERT_FILE" \
  && pass "CERT_ISSUER_KIND: issuerRef is cluster-scoped (ClusterIssuer)" \
  || fail "CERT_ISSUER_KIND: issuerRef.kind ClusterIssuer not declared; a namespaced Issuer would change TLS ownership"

grep -qF 'name: __CLUSTER_ISSUER__' "$CERT_FILE" \
  && pass "CERT_ISSUER_NAME: issuer name stays the reviewed __CLUSTER_ISSUER__ placeholder" \
  || fail "CERT_ISSUER_NAME: expected issuerRef name __CLUSTER_ISSUER__ in $(rel "$CERT_FILE")"

grep -qE '^[[:space:]]*-[[:space:]]*auth\.__BASE_DOMAIN__[[:space:]]*$' "$CERT_FILE" \
  && pass "CERT_DNSNAMES: dnsNames carries ${EXPECTED_HOST_PLACEHOLDER}" \
  || fail "CERT_DNSNAMES: dnsNames does not carry ${EXPECTED_HOST_PLACEHOLDER}"

if grep -qE '^[[:space:]]*solvers:[[:space:]]*$' "$CERT_FILE"; then
  fail "CERT_NO_SOLVERS: solver config must live on the ClusterIssuer, not in $(rel "$CERT_FILE")"
else
  pass "CERT_NO_SOLVERS: no inlined solver config (issuer policy stays on the ClusterIssuer)"
fi

# ---------------------------------------------------------------------------
# 4. Single TLS ownership across the two manifests
# ---------------------------------------------------------------------------
ingress_secret="$(first_indented_scalar "$INGRESS_FILE" secretName)"
cert_secret="$(first_indented_scalar "$CERT_FILE" secretName)"
[[ -n "$ingress_secret" && "$ingress_secret" == "$cert_secret" ]] \
  && pass "TLS_SECRET_MATCH: Ingress and Certificate share the single secret ${ingress_secret}" \
  || fail "TLS_SECRET_MATCH: Ingress secret '${ingress_secret}' != Certificate secret '${cert_secret}'"

ingress_ns="$(metadata_scalar "$INGRESS_FILE" namespace)"
cert_ns="$(metadata_scalar "$CERT_FILE" namespace)"
workload_ns="$(grep -m1 -E '^NAMESPACE=' "$DEPLOY_SCRIPT" | sed -E 's/^NAMESPACE="\$\{NAMESPACE:-([^}]*)\}"$/\1/' || true)"
[[ -n "$ingress_ns" && "$ingress_ns" == "$cert_ns" && "$ingress_ns" == "$workload_ns" ]] \
  && pass "TLS_SAME_NAMESPACE: Ingress, Certificate and workload namespace are all '${ingress_ns}'" \
  || fail "TLS_SAME_NAMESPACE: ingress='${ingress_ns}' certificate='${cert_ns}' workload-default='${workload_ns}' must be one namespace"

if grep -rIn --include='*.yaml' --include='*.yml' --include='*.tpl' --exclude-dir=.git \
     -E '^[[:space:]]*apiTokenSecretRef:|cloudflare-api-token-secret' "${ROOT_DIR}/platform/identity" >/dev/null 2>&1; then
  fail "NO_DNS01_CREDENTIAL_IN_IDENTITY: Cloudflare DNS-01 credential is referenced from platform/identity/**"
else
  pass "NO_DNS01_CREDENTIAL_IN_IDENTITY: DNS-01 credential stays outside platform/identity/**"
fi

unexpected_tls_refs=""
while IFS= read -r file; do
  rel_file="$(rel "$file")"
  case "$rel_file" in
    platform/identity/ingress/authentik-ingress.yaml|platform/identity/ingress/authentik-certificate.yaml) ;;
    *) unexpected_tls_refs="${unexpected_tls_refs} ${rel_file}" ;;
  esac
done < <(grep -rlF --include='*.yaml' --include='*.yml' --include='*.tpl' \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv \
    'authentik-tls' "$ROOT_DIR" 2>/dev/null || true)
if [[ -z "${unexpected_tls_refs// /}" ]]; then
  pass "TLS_SECRET_NO_CROSS_NAMESPACE: '${EXPECTED_TLS_SECRET}' appears only in the two identity ingress manifests"
else
  fail "TLS_SECRET_NO_CROSS_NAMESPACE: '${EXPECTED_TLS_SECRET}' referenced outside the identity ingress manifests:${unexpected_tls_refs}"
fi

# ---------------------------------------------------------------------------
# 4b. Exactly one repository-wide Ingress route owner for the Authentik host
#
# Section 2 rule 1 states that the host is served by exactly one Ingress.
# Validating only the canonical manifest would not notice a second committed
# route for the same host, so every manifest in the repository working tree is
# scanned: the canonical file must be the single owner, and a competing object
# that claims the same host, or the same TLS secret for that host, fails.
# ---------------------------------------------------------------------------
ingress_owners="$(route_owner_docs Ingress 1)"
cert_host_owners="$(route_owner_docs Certificate 1)"
canonical_ingress_rel="$(rel "$INGRESS_FILE")"
canonical_cert_rel="$(rel "$CERT_FILE")"

ingress_owner_count="$(count_records "$ingress_owners")"
if [[ "$ingress_owner_count" == "1" ]]; then
  pass "INGRESS_SINGLE_OWNER: exactly one committed Ingress serves ${EXPECTED_HOST_PLACEHOLDER}"
else
  fail "INGRESS_SINGLE_OWNER: expected exactly one Ingress serving ${EXPECTED_HOST_PLACEHOLDER}, found ${ingress_owner_count}: $(records_paths "$ingress_owners" | tr '\n' ' ')"
fi

if records_paths "$ingress_owners" | grep -qxF "$canonical_ingress_rel"; then
  pass "INGRESS_OWNER_CANONICAL: the single host owner is ${canonical_ingress_rel}"
else
  fail "INGRESS_OWNER_CANONICAL: repository scan did not resolve ${canonical_ingress_rel} as an owner of ${EXPECTED_HOST_PLACEHOLDER}; the assertion would be vacuous"
fi

non_v1_owners="$(printf '%s\n' "$ingress_owners" | awk -F'\t' 'NF && $2 != "networking.k8s.io/v1" { print $1 " (" $2 ")" }')"
if (( ingress_owner_count >= 1 )) && [[ -z "${non_v1_owners//[[:space:]]/}" ]]; then
  pass "INGRESS_OWNER_API: every Ingress owner of the host uses networking.k8s.io/v1"
else
  fail "INGRESS_OWNER_API: Ingress owner(s) of ${EXPECTED_HOST_PLACEHOLDER} are not all networking.k8s.io/v1: ${non_v1_owners//$'\n'/ }"
fi

owner_tls_mismatch="$(printf '%s\n' "$ingress_owners" | awk -F'\t' -v want="$EXPECTED_TLS_SECRET" 'NF && $4 != want { print $1 " (tls.secretName=" $4 ")" }')"
if (( ingress_owner_count >= 1 )) && [[ -z "${owner_tls_mismatch//[[:space:]]/}" ]]; then
  pass "INGRESS_OWNER_TLS_SECRET: the host owner declares tls.secretName ${EXPECTED_TLS_SECRET}"
else
  fail "INGRESS_OWNER_TLS_SECRET: host owner(s) without tls.secretName ${EXPECTED_TLS_SECRET}: ${owner_tls_mismatch//$'\n'/ } (owners: $(records_paths "$ingress_owners" | tr '\n' ' '))"
fi

cert_owner_count="$(count_records "$cert_host_owners")"
if [[ "$cert_owner_count" == "1" ]] && records_paths "$cert_host_owners" | grep -qxF "$canonical_cert_rel"; then
  pass "CERT_SINGLE_OWNER: ${canonical_cert_rel} is the single Certificate covering ${EXPECTED_HOST_PLACEHOLDER}"
else
  fail "CERT_SINGLE_OWNER: expected ${canonical_cert_rel} to be the only Certificate covering ${EXPECTED_HOST_PLACEHOLDER}, found ${cert_owner_count}: $(records_paths "$cert_host_owners" | tr '\n' ' ')"
fi

stray_tls_owner_docs="$(printf '%s\n' "$ingress_owners" "$cert_host_owners" \
  | awk -F'\t' -v canon_ingress="$canonical_ingress_rel" -v canon_cert="$canonical_cert_rel" \
      'NF && $1 != canon_ingress && $1 != canon_cert { print $1 }' | LC_ALL=C sort -u)"
if (( ingress_owner_count >= 1 )) && [[ -z "${stray_tls_owner_docs//[[:space:]]/}" ]]; then
  pass "TLS_SECRET_SINGLE_OWNER: only ${canonical_ingress_rel} and ${canonical_cert_rel} claim the host and its TLS secret"
else
  fail "TLS_SECRET_SINGLE_OWNER: competing route/TLS owner(s) for ${EXPECTED_HOST_PLACEHOLDER}: ${stray_tls_owner_docs//$'\n'/ }"
fi

declared_issuers="$(clusterissuer_pairs "${ROOT_DIR}/platform" | awk -F'\t' '$2 == "cloudflare-dns01" { print $1 }' | sort -u)"
for issuer in "${ISSUER_NAMES[@]}"; do
  if printf '%s\n' "$declared_issuers" | grep -qxF "$issuer"; then
    pass "ISSUER_AUTHORITY: committed ClusterIssuer ${issuer} uses a Cloudflare DNS-01 solver"
  else
    fail "ISSUER_AUTHORITY: no committed ClusterIssuer ${issuer} with a Cloudflare DNS-01 solver found under platform/"
  fi
done

letsencrypt_not_dns01="$(clusterissuer_pairs "${ROOT_DIR}/platform" \
  | awk -F'\t' '$1 ~ /^letsencrypt-/ && $2 != "cloudflare-dns01" { print $1 }' | sort -u || true)"
if [[ -z "${letsencrypt_not_dns01// /}" ]]; then
  pass "ISSUER_DNS01_ONLY: every letsencrypt-* ClusterIssuer uses Cloudflare DNS-01"
else
  fail "ISSUER_DNS01_ONLY: letsencrypt-* ClusterIssuer without Cloudflare DNS-01: ${letsencrypt_not_dns01}"
fi

if grep -qE 'minVersion|tls-[a-z0-9.-]+:[[:space:]]' "$INGRESS_FILE"; then
  pass "TLS_HARDENING: the Ingress declares an explicit TLS option"
else
  warn "TLS_HARDENING: no explicit TLS option on the Ingress; TLS parameters are inherited from the Traefik exposure contract"
fi

# ---------------------------------------------------------------------------
# 5. Deploy script: renderer and issuer selection
# ---------------------------------------------------------------------------
if grep -qF 'ISSUER_MODE="${ISSUER_MODE:-staging}"' "$DEPLOY_SCRIPT"; then
  pass "DEPLOY_ISSUER_DEFAULT: ISSUER_MODE default is staging"
else
  fail "DEPLOY_ISSUER_DEFAULT: ISSUER_MODE default staging not declared in $(rel "$DEPLOY_SCRIPT")"
fi

if grep -qF 'ISSUER_MODE must be staging or prod' "$DEPLOY_SCRIPT"; then
  pass "DEPLOY_ISSUER_ENUM: ISSUER_MODE is enumerated (staging|prod)"
else
  fail "DEPLOY_ISSUER_ENUM: ISSUER_MODE enumeration is missing; an unbounded issuer mode breaks the TLS contract"
fi

if grep -qF 'CLUSTER_ISSUER="letsencrypt-${ISSUER_MODE}"' "$DEPLOY_SCRIPT"; then
  pass "DEPLOY_ISSUER_NAME: CLUSTER_ISSUER is letsencrypt-\${ISSUER_MODE}"
else
  fail "DEPLOY_ISSUER_NAME: expected CLUSTER_ISSUER=\"letsencrypt-\${ISSUER_MODE}\" in $(rel "$DEPLOY_SCRIPT")"
fi

if grep -qF '__BASE_DOMAIN__' "$DEPLOY_SCRIPT" && grep -qF '__CLUSTER_ISSUER__' "$DEPLOY_SCRIPT"; then
  pass "DEPLOY_RENDER_PLACEHOLDERS: both template placeholders are substituted at render time"
else
  fail "DEPLOY_RENDER_PLACEHOLDERS: __BASE_DOMAIN__ and __CLUSTER_ISSUER__ substitution is incomplete"
fi

if grep -qF 'authentik-certificate.yaml' "$DEPLOY_SCRIPT" \
   && grep -qF 'authentik-ingress.yaml' "$DEPLOY_SCRIPT" \
   && grep -qF '"ingress"' "$DEPLOY_SCRIPT"; then
  pass "DEPLOY_RENDER_SOURCES: both ingress/ manifests are rendered by the deploy script"
else
  fail "DEPLOY_RENDER_SOURCES: the deploy script does not render both ingress/ manifests"
fi

cert_apply_line="$(grep -nF 'kubectl apply -f "${tmp_dir}/authentik-certificate.yaml"' "$DEPLOY_SCRIPT" | head -n1 | cut -d: -f1 || true)"
ingress_apply_line="$(grep -nF 'kubectl apply -f "${tmp_dir}/authentik-ingress.yaml"' "$DEPLOY_SCRIPT" | head -n1 | cut -d: -f1 || true)"
if [[ -n "$cert_apply_line" && -n "$ingress_apply_line" && "$cert_apply_line" -lt "$ingress_apply_line" ]]; then
  pass "DEPLOY_APPLY_ORDER: certificate is applied before the ingress"
else
  fail "DEPLOY_APPLY_ORDER: expected certificate (line ${cert_apply_line:-none}) applied before ingress (line ${ingress_apply_line:-none})"
fi

# ---------------------------------------------------------------------------
# 6. Identity-model bootstrap is decoupled from ingress/TLS reconciliation
# ---------------------------------------------------------------------------
assert_no_tokens "BOOTSTRAP_NO_ROUTE_TLS" "$BOOTSTRAP_SCRIPT" \
  'ingress|certificate|cert-manager|clusterissuer|secretname|dns01|cloudflare|websecure|\btls\b'
assert_readonly_kubectl "BOOTSTRAP_READONLY" "$BOOTSTRAP_SCRIPT"

if script_code "$DEPLOY_SCRIPT" | grep -qEi 'bootstrap-identity-model|/api/v3/core/(groups|users)|ensure_group|bootstrap_memberships'; then
  fail "DEPLOY_NO_IDENTITY_MODEL: deploy script couples ingress/TLS reconciliation to the identity-model bootstrap"
else
  pass "DEPLOY_NO_IDENTITY_MODEL: deploy script performs no identity-model reconciliation"
fi

bootstrap_main="$(sed -n '/^main() {/,/^}/p' "$BOOTSTRAP_SCRIPT" | grep -v '^[[:space:]]*#')"
if printf '%s\n' "$bootstrap_main" | grep -qE '(^|[[:space:]])bootstrap_identity_model([[:space:]]|$)'; then
  pass "BOOTSTRAP_ENTRYPOINT: bootstrap main() reconciles the identity model"
else
  fail "BOOTSTRAP_ENTRYPOINT: bootstrap main() does not call bootstrap_identity_model in $(rel "$BOOTSTRAP_SCRIPT")"
fi

if printf '%s\n' "$bootstrap_main" | grep -qEi 'ingress|certificate|cert-manager|clusterissuer|\btls\b|render_apply'; then
  fail "BOOTSTRAP_MAIN_NO_ROUTE_STEPS: bootstrap main() calls a route/TLS step"
else
  pass "BOOTSTRAP_MAIN_NO_ROUTE_STEPS: bootstrap main() has no route/TLS step"
fi

# ---------------------------------------------------------------------------
# 7. Document and ownership consistency
# ---------------------------------------------------------------------------
required_doc_strings=(
  'auth.<PLATFORM_BASE_DOMAIN>'
  'platform/identity/ingress/authentik-ingress.yaml'
  'platform/identity/ingress/authentik-certificate.yaml'
  'platform/identity/scripts/ch04-5-bootstrap-identity-model.sh'
  'platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh'
  'authentik-tls'
  'ClusterIssuer'
  'DNS-01'
  'same namespace'
  'decoupl'
  'CH04.6'
  'any other committed manifest in this repository'
)
missing_doc_strings=""
for needle in "${required_doc_strings[@]}"; do
  grep -qiF -- "$needle" "$CONTRACT_DOC" || missing_doc_strings="${missing_doc_strings} '${needle}'"
done
if [[ -z "${missing_doc_strings// /}" ]]; then
  pass "CONTRACT_DOC_CONTENT: the contract document states hostname, Ingress, Certificate, TLS ownership and decoupling"
else
  fail "CONTRACT_DOC_CONTENT: contract document is missing:${missing_doc_strings}"
fi

if grep -qF 'Authentik public route and TLS' "$INVENTORY_DOC" \
   && grep -qF 'CH04.6' "$INVENTORY_DOC" \
   && grep -qF 'CH04.5' "$INVENTORY_DOC"; then
  pass "INVENTORY_CONSISTENCY: ownership inventory still attributes the route/TLS to CH04.5 and Argo CD SSO to CH04.6"
else
  fail "INVENTORY_CONSISTENCY: ownership inventory no longer matches the ingress/TLS ownership contract"
fi

# ---------------------------------------------------------------------------
# 8. No secret material in the identity tree
#
# The scan pattern itself lives in this file, so this validator is excluded from
# the scan to keep it from matching its own pattern text.
# ---------------------------------------------------------------------------
if grep -rIlE --exclude="$(basename "${BASH_SOURCE[0]}")" \
     'BEGIN [A-Z ]*PRIVATE KEY|BEGIN CERTIFICATE' "${ROOT_DIR}/platform/identity" >/dev/null 2>&1; then
  fail "NO_SECRET_MATERIAL: private key or certificate material found under platform/identity/**"
else
  pass "NO_SECRET_MATERIAL: no private key or certificate material under platform/identity/**"
fi

summary_exit
