#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# CH04.6 - Argo CD SSO contract validator (single focused validator)
#
# Task: P-CH04.6-T01 (Authentik OIDC provider/application contract audit).
#
# It asserts the CH04.6 Argo CD SSO contract in five groups:
#   A. cluster SSO material: rollouts, argocd-secret keys, argocd-cm url
#   B. the Dex-backed connector contract in argocd-cm (issuer, clientID,
#      secret *reference*, groups claim, scopes) and the absence of the direct
#      oidc.config path
#   C. the Argo CD RBAC contract in argocd-rbac-cm (admin group, scopes)
#   D. the Authentik OIDC provider/application contract, including the strict
#      redirect URI allow-list and its completeness (the live redirect_uris
#      collection must contain exactly the three contract entries, so an extra,
#      duplicate, non-strict or unexpected-type entry fails closed even when the
#      reconciliation writer was not the last writer). Every URL comparison uses
#      one canonical normalizer: scheme and host/authority are case-insensitive,
#      path/query/fragment stay case-sensitive, and a trailing slash is not a
#      different target. The block also asserts the scope mappings, the
#      provider/application link and the single-provider/single-application rule
#      that proves no parallel OIDC path exists
#   E. the ambiguous secret-reference checks: the dex client secret key and the
#      stable session key are present, and the legacy direct-OIDC key is absent
#   F. CH04.5 ownership preservation and the deterministic, non-broadening Argo CD
#      group-to-role mapping: the consumed group carries the CH04.5 managed
#      ownership stamps (managed_by, contract_version, owner_chapter, scope,
#      consumer_chapter) with an allowed consumer chapter, and argocd-rbac-cm
#      carries exactly one group binding, the expected admin mapping, the
#      read-only default policy and a groups scope. Missing stamps, a foreign
#      owner and any extra/widened admin binding fail closed
#
# Secret handling: this validator asserts secret *key presence* and non-secret
# identifiers only. It never prints, hashes or logs a secret value, and the
# Authentik client secret is only probed for presence.
#
# Read-only: kubectl get and Authentik GET requests only. No mutation, no
# infrastructure workflow, no GitHub/DNS/Cloudflare access.
#
# Invocation contract (stable; used by workflow "04.6 - Enable Argo CD SSO"):
#   bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
#   bash platform/identity/validate/ch04-6-validate-argocd-sso.sh --static
# Environment: BASE_DOMAIN, ARGOCD_NAMESPACE, IDENTITY_NAMESPACE,
#   ARGOCD_OIDC_PROVIDER_SLUG, ARGOCD_ADMIN_GROUP,
#   AUTHENTIK_ARGOCD_ADMIN_USERNAME, AUTHENTIK_BASE_URL and optionally
#   AUTHENTIK_BOOTSTRAP_TOKEN (read from the identity namespace when unset).
# Exit status: 0 when every check is PASS or WARN, 1 on the first FAIL.
#
# Modes:
#   (default / --live) live read-only contract validation: kubectl get and
#     Authentik GET requests only.
#   --static repository-only, non-mutating, no kubectl, no network. It proves
#     the ownership-preservation, mapping-determinism and
#     repeat-reconciliation invariants offline: the reconciler writes no group
#     object, asserts and re-verifies the CH04.5 ownership stamps, renders the
#     argocd-rbac-cm mapping deterministically, and the extracted admin-group
#     binding gate accepts/rejects the same inputs identically on a repeat run.
#     It exists because the live path can only be observed on a healthy host.
#############################################################################

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

# ---------------------------------------------------------------------------
# Invocation modes
# ---------------------------------------------------------------------------
STATIC_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --static) STATIC_MODE=1 ;;
    --live) STATIC_MODE=0 ;;
    *) echo "FAIL | ARGS | unsupported argument: $1 (supported: --static, --live)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# --static mode (defined before the live checks so it can exit before the first
# kubectl call): repository-only, non-mutating, no cluster and no network.
# ---------------------------------------------------------------------------
STATIC_FAILURES=0
STATIC_CONTROLS=0
STATIC_TMP_DIR=""
STATIC_GATE_BEGIN="# >>> CH04.6 admin-group binding gate >>>"
STATIC_GATE_END="# <<< CH04.6 admin-group binding gate <<<"
STATIC_EXPECTED_MANAGED_BY="ch04-5-bootstrap-identity-model"
STATIC_EXPECTED_OWNER_CHAPTER="CH04.5"
STATIC_ALLOWED_CONSUMER_CHAPTERS="platform CH04.6"
STATIC_DEFAULT_GROUP="PlatformInit Admins"

static_pass() { echo "PASS | $1 | $2"; STATIC_CONTROLS=$((STATIC_CONTROLS + 1)); }
static_warn() { echo "WARN | $1 | $2"; STATIC_CONTROLS=$((STATIC_CONTROLS + 1)); }
static_fail() {
  echo "FAIL | $1 | $2"
  STATIC_CONTROLS=$((STATIC_CONTROLS + 1))
  STATIC_FAILURES=$((STATIC_FAILURES + 1))
}

static_self_path() { printf '%s\n' "${BASH_SOURCE[0]}"; }
static_identity_dir() { cd -- "$(dirname -- "$(static_self_path)")/.." && pwd; }
static_code_only() { grep -vE '^[[:space:]]*#' "$1" || true; }

static_cleanup() {
  if [[ -n "${STATIC_TMP_DIR}" && -d "${STATIC_TMP_DIR}" ]]; then
    rm -rf "${STATIC_TMP_DIR}"
  fi
}

run_static_validation() {
  trap static_cleanup EXIT

  local identity_dir reconciler rbac_template taxonomy gate_py
  local code="" missing="" problems="" token="" group_writes=""
  identity_dir="$(static_identity_dir)"
  reconciler="${identity_dir}/scripts/ch04-6-enable-argocd-sso.sh"
  rbac_template="${identity_dir}/integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl"
  taxonomy="${identity_dir}/groups/platforminit-groups.yaml"
  STATIC_TMP_DIR="$(mktemp -d)"
  gate_py="${STATIC_TMP_DIR}/admin-group-binding-gate.py"

  echo "static mode: repository-only CH04.6 ownership-preservation and mapping-determinism validation"

  # --- S1. repository inputs ------------------------------------------------
  for path in "${reconciler}" "${rbac_template}" "${taxonomy}"; do
    [[ -f "${path}" ]] || missing="${missing} ${path}"
  done
  if [[ -z "${missing}" ]]; then
    static_pass "STATIC_INPUTS" "the reconciler, the argocd-rbac-cm template and the CH04.5 taxonomy are present"
  else
    static_fail "STATIC_INPUTS" "missing repository input(s):${missing}"
    return 1
  fi

  # --- S2. syntax ----------------------------------------------------------
  if bash -n "${reconciler}" 2>/dev/null; then
    static_pass "STATIC_RECONCILER_SYNTAX" "bash -n passes on the reconciler"
  else
    static_fail "STATIC_RECONCILER_SYNTAX" "bash -n fails on the reconciler"
  fi
  if bash -n "$(static_self_path)" 2>/dev/null; then
    static_pass "STATIC_VALIDATOR_SYNTAX" "bash -n passes on this validator"
  else
    static_fail "STATIC_VALIDATOR_SYNTAX" "bash -n fails on this validator"
  fi

  code="$(static_code_only "${reconciler}")"

  # --- S3. the reconciler writes no group object ---------------------------
  group_writes="$(printf '%s\n' "${code}" | grep -nE 'request\("(POST|PATCH|PUT|DELETE)"[^)]*core/groups' || true)"
  if [[ -z "${group_writes}" ]]; then
    static_pass "STATIC_NO_GROUP_WRITE" "the reconciler issues no group create/update/delete call, so CH04.5 ownership attributes cannot be written by CH04.6"
  else
    static_fail "STATIC_NO_GROUP_WRITE" "mutating group call(s) found in the reconciler: ${group_writes}"
  fi

  if printf '%s\n' "${code}" | grep -qF 'first_by_field("/api/v3/core/groups/", "name", name)'; then
    static_pass "STATIC_GROUP_LOOKUP_EXACT_NAME" "the consumed group is resolved by exact-name lookup only"
  else
    static_fail "STATIC_GROUP_LOOKUP_EXACT_NAME" "the reconciler no longer resolves the admin group by exact-name lookup"
  fi

  # --- S4. ownership stamp assertion --------------------------------------
  for token in 'REQUIRED_OWNERSHIP_STAMPS' 'platforminit_managed_by' 'platforminit_contract_version' \
      'platforminit_owner_chapter' 'platforminit_scope' 'platforminit_consumer_chapter' \
      'ch04-5-bootstrap-identity-model'; do
    printf '%s\n' "${code}" | grep -qF "${token}" || problems="${problems} ${token}"
  done
  if [[ -z "${problems}" ]]; then
    static_pass "STATIC_OWNERSHIP_STAMP_ASSERTION" "the reconciler asserts the CH04.5 managed ownership stamps and the CH04.5 reconciler name before binding the group"
  else
    static_fail "STATIC_OWNERSHIP_STAMP_ASSERTION" "missing ownership assertion token(s):${problems}"
    problems=""
  fi

  # --- S5. ownership preservation proof -----------------------------------
  for token in 'def group_attributes(group_pk)' 'def assert_group_ownership_preserved(' \
      'argocd_admin_group_ownership' 'ownership attributes preserved on group'; do
    printf '%s\n' "${code}" | grep -qF "${token}" || problems="${problems} ${token}"
  done
  if [[ -z "${problems}" ]]; then
    static_pass "STATIC_OWNERSHIP_PRESERVATION_PROOF" "the reconciler snapshots the CH04.5 attribute bag and re-verifies it after the membership convergence"
  else
    static_fail "STATIC_OWNERSHIP_PRESERVATION_PROOF" "missing preservation-proof token(s):${problems}"
    problems=""
  fi

  # --- S6. RBAC mapping read-back verification ----------------------------
  for token in 'verify_argocd_rbac_mapping()' 'ARGOCD_RBAC_DEFAULT_POLICY' 'ARGOCD_RBAC_ADMIN_ROLE'; do
    printf '%s\n' "${code}" | grep -qF "${token}" || problems="${problems} ${token}"
  done
  if [[ -z "${problems}" ]]; then
    static_pass "STATIC_RBAC_MAPPING_VERIFICATION" "the reconciler reads back the applied argocd-rbac-cm mapping, default policy and groups scope"
  else
    static_fail "STATIC_RBAC_MAPPING_VERIFICATION" "missing RBAC verification token(s):${problems}"
    problems=""
  fi

  # --- S7. repeat-reconciliation convergence ------------------------------
  for token in 'is already a member of' 'ARGOCD_CONFIG_CHANGED=0' \
      'config unchanged; skipping unnecessary rollout restart' 'assert_group_ownership_preserved('; do
    printf '%s\n' "${code}" | grep -qF "${token}" || problems="${problems} ${token}"
  done
  if [[ -z "${problems}" ]]; then
    static_pass "STATIC_REPEAT_RECONCILIATION_CONVERGENCE" "a repeat run short-circuits the membership, the unchanged config and the group state instead of rewriting them"
  else
    static_fail "STATIC_REPEAT_RECONCILIATION_CONVERGENCE" "missing convergence token(s):${problems}"
    problems=""
  fi

  # --- S8. the binding gate is extractable --------------------------------
  local begin_count end_count declared_default
  begin_count="$(grep -cF "${STATIC_GATE_BEGIN}" "${reconciler}" || true)"
  end_count="$(grep -cF "${STATIC_GATE_END}" "${reconciler}" || true)"
  if [[ "${begin_count}" == "1" && "${end_count}" == "1" ]]; then
    static_pass "STATIC_BINDING_GATE_MARKERS" "the admin-group binding gate body is marker-delimited exactly once, so it can be driven offline with fixtures"
  else
    static_fail "STATIC_BINDING_GATE_MARKERS" "expected exactly one gate marker pair (found begin=${begin_count}, end=${end_count})"
  fi

  # --- S9. the contract constants agree with the reconciler default --------
  declared_default="$(sed -nE 's/^ARGOCD_ADMIN_GROUP="\$\{ARGOCD_ADMIN_GROUP:-([^}]*)\}"$/\1/p' "${reconciler}" | head -1)"
  if [[ "${declared_default}" == "${STATIC_DEFAULT_GROUP}" ]]; then
    static_pass "STATIC_DEFAULT_GROUP_AGREES" "the offline fixtures use the reconciler's declared default admin group (${STATIC_DEFAULT_GROUP})"
  else
    static_fail "STATIC_DEFAULT_GROUP_AGREES" "the reconciler default admin group is '${declared_default:-<none>}' but the offline fixtures assert '${STATIC_DEFAULT_GROUP}'"
  fi

  # --- S10. the CH04.5 taxonomy agrees with the binding contract -----------
  if STATIC_TAXONOMY="${taxonomy}" STATIC_MANAGED_BY="${STATIC_EXPECTED_MANAGED_BY}" \
      STATIC_OWNER_CHAPTER="${STATIC_EXPECTED_OWNER_CHAPTER}" \
      STATIC_DEFAULT_GROUP="${STATIC_DEFAULT_GROUP}" \
      STATIC_ALLOWED_CONSUMERS="${STATIC_ALLOWED_CONSUMER_CHAPTERS}" \
      python3 - <<'PYTAXONOMY'
import json
import os
import sys

model = json.load(open(os.environ["STATIC_TAXONOMY"], encoding="utf-8"))
problems = []
management = model.get("management") or {}
if management.get("managed_by") != os.environ["STATIC_MANAGED_BY"]:
    problems.append(f"management.managed_by is {management.get('managed_by')!r}")
matches = [group for group in (model.get("groups") or [])
           if group.get("name") == os.environ["STATIC_DEFAULT_GROUP"]]
if len(matches) != 1:
    problems.append(f"default group {os.environ['STATIC_DEFAULT_GROUP']!r} matches {len(matches)} entries")
else:
    group = matches[0]
    if group.get("owner_chapter") != os.environ["STATIC_OWNER_CHAPTER"]:
        problems.append(f"default group owner_chapter is {group.get('owner_chapter')!r}")
    if group.get("is_superuser") is not False:
        problems.append("default group is declared as an Authentik superuser group")
    if str(group.get("consumer_chapter")) not in os.environ["STATIC_ALLOWED_CONSUMERS"].split():
        problems.append(f"default group consumer_chapter is {group.get('consumer_chapter')!r}")
if problems:
    print("; ".join(problems), file=sys.stderr)
    sys.exit(1)
print("taxonomy constants agree")
PYTAXONOMY
  then
    static_pass "STATIC_TAXONOMY_CONSTANTS_AGREE" "the CH04.5 taxonomy agrees with the binding contract (managed_by, non-superuser default group, allowed consumer chapter)"
  else
    static_fail "STATIC_TAXONOMY_CONSTANTS_AGREE" "the CH04.5 taxonomy disagrees with the binding contract constants"
  fi

  # --- S11. extract the binding gate and drive it with fixtures ------------
  awk -v begin="${STATIC_GATE_BEGIN}" -v end="${STATIC_GATE_END}" '
    index($0, begin) { capturing = 1; next }
    index($0, end)   { capturing = 0 }
    capturing        { print }
  ' "${reconciler}" > "${gate_py}"
  if [[ -s "${gate_py}" ]]; then
    static_pass "STATIC_BINDING_GATE_EXTRACTION" "the admin-group binding gate body was extracted from the reconciler ($(wc -l < "${gate_py}") lines)"
  else
    static_fail "STATIC_BINDING_GATE_EXTRACTION" "no gate body could be extracted between the gate markers"
    return 1
  fi

  # Mutated copies of the real taxonomy: each negative control must differ from
  # the unmutated file and must flip the verdict of the accepted fixture.
  local mut_managed_by="${STATIC_TMP_DIR}/taxonomy-managed-by.json"
  local mut_superuser="${STATIC_TMP_DIR}/taxonomy-superuser.json"
  local mut_consumer="${STATIC_TMP_DIR}/taxonomy-consumer.json"
  STATIC_TAXONOMY_SRC="${taxonomy}" STATIC_FIXTURE_DIR="${STATIC_TMP_DIR}" python3 - <<'PYMUT'
import json
import os

src = os.environ["STATIC_TAXONOMY_SRC"]
dst = os.environ["STATIC_FIXTURE_DIR"]
base = json.load(open(src, encoding="utf-8"))


def set_entry(model, key, value):
    entry = next(group for group in model["groups"] if group.get("name") == "ArgoCD Admins")
    entry[key] = value


def dump(name, mutate):
    model = json.loads(json.dumps(base))
    mutate(model)
    with open(os.path.join(dst, name), "w", encoding="utf-8") as handle:
        json.dump(model, handle)


dump("taxonomy-managed-by.json", lambda m: m["management"].__setitem__("managed_by", "some-other-reconciler"))
dump("taxonomy-superuser.json", lambda m: set_entry(m, "is_superuser", True))
dump("taxonomy-consumer.json", lambda m: set_entry(m, "consumer_chapter", "CH05"))
PYMUT

  local fixture_problems=""
  grep -q 'some-other-reconciler' "${mut_managed_by}" 2>/dev/null || fixture_problems="${fixture_problems} managed-by"
  grep -q '"is_superuser": true' "${mut_superuser}" 2>/dev/null || fixture_problems="${fixture_problems} superuser"
  grep -q 'CH05' "${mut_consumer}" 2>/dev/null || fixture_problems="${fixture_problems} consumer"
  if [[ -z "${fixture_problems}" ]]; then
    static_pass "STATIC_BINDING_GATE_FIXTURES_EFFECTIVE" "every mutated taxonomy fixture differs from the real taxonomy, and the paired accept/reject cases prove the mutation changes the verdict"
  else
    static_fail "STATIC_BINDING_GATE_FIXTURES_EFFECTIVE" "ineffective mutated fixture(s):${fixture_problems}"
  fi

  # Run each fixture twice: the two runs must return the same exit status and the
  # same output, so a repeat reconciliation reaches the same group-to-role decision.
  gate_case() {
    local case_name="$1" group_name="$2" tax_file="$3" expected_rc="$4" expect_output="$5"
    local rc_1 rc_2 out_1 out_2 err_1 err_2
    set +e
    ARGOCD_ADMIN_GROUP="${group_name}" ARGOCD_TAXONOMY_FILE="${tax_file}" \
      ARGOCD_TAXONOMY_MANAGED_BY_EXPECTED="${STATIC_EXPECTED_MANAGED_BY}" \
      ARGOCD_ADMIN_GROUP_ALLOWED_CONSUMER_CHAPTERS="${STATIC_ALLOWED_CONSUMER_CHAPTERS}" \
      ARGOCD_RBAC_ADMIN_ROLE="role:admin" \
      python3 "${gate_py}" > "${STATIC_TMP_DIR}/${case_name}.1.out" 2> "${STATIC_TMP_DIR}/${case_name}.1.err"
    rc_1=$?
    ARGOCD_ADMIN_GROUP="${group_name}" ARGOCD_TAXONOMY_FILE="${tax_file}" \
      ARGOCD_TAXONOMY_MANAGED_BY_EXPECTED="${STATIC_EXPECTED_MANAGED_BY}" \
      ARGOCD_ADMIN_GROUP_ALLOWED_CONSUMER_CHAPTERS="${STATIC_ALLOWED_CONSUMER_CHAPTERS}" \
      ARGOCD_RBAC_ADMIN_ROLE="role:admin" \
      python3 "${gate_py}" > "${STATIC_TMP_DIR}/${case_name}.2.out" 2> "${STATIC_TMP_DIR}/${case_name}.2.err"
    rc_2=$?
    set -e
    out_1="$(cat "${STATIC_TMP_DIR}/${case_name}.1.out")"
    out_2="$(cat "${STATIC_TMP_DIR}/${case_name}.2.out")"
    err_1="$(cat "${STATIC_TMP_DIR}/${case_name}.1.err")"
    err_2="$(cat "${STATIC_TMP_DIR}/${case_name}.2.err")"

    if [[ "${rc_1}" != "${expected_rc}" ]]; then
      static_fail "STATIC_GATE_${case_name}" "expected rc=${expected_rc} but the gate returned rc=${rc_1}: ${err_1:-<no stderr>}"
      return 0
    fi
    if [[ "${rc_1}" != "${rc_2}" || "${out_1}" != "${out_2}" || "${err_1}" != "${err_2}" ]]; then
      static_fail "STATIC_GATE_${case_name}" "the repeat run reached a different decision (rc ${rc_1} vs ${rc_2}), so the mapping is not deterministic"
      return 0
    fi
    if [[ -n "${expect_output}" && "${out_1}" != *"${expect_output}"* ]]; then
      static_fail "STATIC_GATE_${case_name}" "the accepted run did not emit the expected mapping: ${expect_output}"
      return 0
    fi
    static_pass "STATIC_GATE_${case_name}" "identical on both runs (rc=${rc_1})${expect_output:+; mapping emitted: ${expect_output}}"
  }

  gate_case "ACCEPT_DEFAULT_PLATFORM_GROUP" "PlatformInit Admins" "${taxonomy}" 0 "g, ${STATIC_DEFAULT_GROUP}, role:admin"
  gate_case "ACCEPT_ARGO_CD_ADMINS_GROUP" "ArgoCD Admins" "${taxonomy}" 0 "g, ArgoCD Admins, role:admin"
  gate_case "REJECT_SUPERUSER_GROUP" "Authentik Admins" "${taxonomy}" 1 ""
  gate_case "REJECT_FOREIGN_CONSUMER_GROUP" "PlatformInit Operations" "${taxonomy}" 1 ""
  gate_case "REJECT_UNDECLARED_GROUP" "PlatformInit Admins Extra" "${taxonomy}" 1 ""
  gate_case "REJECT_EMPTY_GROUP_NAME" "" "${taxonomy}" 1 ""
  gate_case "REJECT_TRAILING_WHITESPACE" "PlatformInit Admins " "${taxonomy}" 1 ""
  gate_case "REJECT_RBAC_INJECTION_COMMA" "PlatformInit Admins, role:admin" "${taxonomy}" 1 ""
  gate_case "REJECT_RBAC_INJECTION_NEWLINE" "$(printf 'PlatformInit Admins\nrole:admin')" "${taxonomy}" 1 ""
  gate_case "REJECT_MISSING_TAXONOMY_FILE" "PlatformInit Admins" "${STATIC_TMP_DIR}/absent-taxonomy.json" 1 ""
  gate_case "REJECT_UNAUTHORIZED_TAXONOMY_OWNER" "ArgoCD Admins" "${mut_managed_by}" 1 ""
  gate_case "REJECT_MUTATED_SUPERUSER_ENTRY" "ArgoCD Admins" "${mut_superuser}" 1 ""
  gate_case "REJECT_MUTATED_CONSUMER_ENTRY" "ArgoCD Admins" "${mut_consumer}" 1 ""

  # --- S12. deterministic RBAC render -------------------------------------
  static_render_rbac() { sed -e "s|__ARGOCD_ADMIN_GROUP__|$1|g" "${rbac_template}"; }
  static_render_rbac "${STATIC_DEFAULT_GROUP}" > "${STATIC_TMP_DIR}/rbac-1.yaml"
  static_render_rbac "${STATIC_DEFAULT_GROUP}" > "${STATIC_TMP_DIR}/rbac-2.yaml"
  if cmp -s "${STATIC_TMP_DIR}/rbac-1.yaml" "${STATIC_TMP_DIR}/rbac-2.yaml"; then
    static_pass "STATIC_RBAC_RENDER_DETERMINISTIC" "two renders of argocd-authentik-rbac-cm.yaml.tpl are byte-identical, so a repeat reconciliation renders the same mapping"
  else
    static_fail "STATIC_RBAC_RENDER_DETERMINISTIC" "two renders of argocd-authentik-rbac-cm.yaml.tpl differ"
  fi

  local mapping_count="" rendered_mapping="" placeholder_count=""
  mapping_count="$(grep -cE '^[[:space:]]*g,' "${STATIC_TMP_DIR}/rbac-1.yaml" || true)"
  rendered_mapping="$(grep -E '^[[:space:]]*g,' "${STATIC_TMP_DIR}/rbac-1.yaml" | sed -E 's/^[[:space:]]+//' | head -1 || true)"
  if [[ "${mapping_count}" == "1" && "${rendered_mapping}" == "g, ${STATIC_DEFAULT_GROUP}, role:admin" ]]; then
    static_pass "STATIC_RBAC_SINGLE_ADMIN_MAPPING" "the rendered RBAC object carries exactly one group binding and it is 'g, ${STATIC_DEFAULT_GROUP}, role:admin'"
  else
    static_fail "STATIC_RBAC_SINGLE_ADMIN_MAPPING" "expected exactly one binding 'g, ${STATIC_DEFAULT_GROUP}, role:admin' (found count=${mapping_count}, first='${rendered_mapping}')"
  fi

  placeholder_count="$(grep -cE '__[A-Z_]+__' "${STATIC_TMP_DIR}/rbac-1.yaml" || true)"
  if grep -q 'policy.default: role:readonly' "${STATIC_TMP_DIR}/rbac-1.yaml" && [[ "${placeholder_count}" == "0" ]]; then
    static_pass "STATIC_RBAC_TEMPLATE_CONTRACT" "the rendered RBAC template keeps policy.default: role:readonly and leaves no unsubstituted placeholder"
  else
    static_fail "STATIC_RBAC_TEMPLATE_CONTRACT" "the rendered RBAC template lost the read-only default policy or kept an unsubstituted placeholder (found ${placeholder_count})"
  fi

  # --- S13. prove --static performs no live access -------------------------
  local dispatch_line="" first_kubectl_line=""
  dispatch_line="$(grep -nF 'if [[ "${STATIC_MODE}" == "1" ]]; then' "$(static_self_path)" | head -1 | cut -d: -f1 || true)"
  first_kubectl_line="$(grep -nE '^[[:space:]]*kubectl ' "$(static_self_path)" | head -1 | cut -d: -f1 || true)"
  if [[ -n "${dispatch_line}" && -n "${first_kubectl_line}" && "${dispatch_line}" -lt "${first_kubectl_line}" ]]; then
    static_pass "STATIC_NO_LIVE_ACCESS" "the --static dispatch precedes the first kubectl call (line ${dispatch_line} < ${first_kubectl_line}), so --static performs no cluster or network access"
  else
    static_fail "STATIC_NO_LIVE_ACCESS" "could not prove that --static exits before the first kubectl call (dispatch=${dispatch_line:-unset}, first kubectl=${first_kubectl_line:-unset})"
  fi

  if [[ "${STATIC_FAILURES}" -eq 0 ]]; then
    echo "static validation: PASS (${STATIC_CONTROLS} controls, 0 failures)"
    return 0
  fi
  echo "static validation: FAIL (${STATIC_CONTROLS} controls, ${STATIC_FAILURES} failures)" >&2
  return 1
}

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
EXPECTED_PROVIDER_SLUG="${ARGOCD_OIDC_PROVIDER_SLUG:-argocd}"
EXPECTED_ADMIN_GROUP="${ARGOCD_ADMIN_GROUP:-PlatformInit Admins}"
EXPECTED_ADMIN_USERNAME="${AUTHENTIK_ARGOCD_ADMIN_USERNAME:-akadmin}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.${BASE_DOMAIN}}"

# --- Contract values, derived exactly like the reconciliation script --------
# The issuer is derived from the Authentik base URL and must equal the issuer the
# discovery document advertises; it is never a hardcoded host.
AUTHENTIK_ISSUER_BASE="${AUTHENTIK_BASE_URL%/}"
EXPECTED_ISSUER="${AUTHENTIK_ISSUER_BASE}/application/o/${EXPECTED_PROVIDER_SLUG}/"
EXPECTED_ARGOCD_URL="https://argocd.${BASE_DOMAIN}"
EXPECTED_PROVIDER_NAME="${ARGOCD_OIDC_PROVIDER_NAME:-Argo CD}"
EXPECTED_REDIRECT_URI="${EXPECTED_ARGOCD_URL}/api/dex/callback"
EXPECTED_CLI_CALLBACK_URI="https://localhost:8085/auth/callback"
EXPECTED_LOGOUT_URI="${EXPECTED_ARGOCD_URL}/logout"
EXPECTED_SCOPES="${ARGOCD_OIDC_SCOPES:-openid profile email groups}"

# --- CH04.5 ownership and group-to-role mapping contract constants ----------
# Mirrors the reconciler's binding contract. The --static mode cross-checks these
# constants against the CH04.5 taxonomy, so they cannot drift from the CH04.5
# model without failing this validator.
EXPECTED_MANAGED_BY="ch04-5-bootstrap-identity-model"
EXPECTED_OWNER_CHAPTER="CH04.5"
EXPECTED_CONSUMER_CHAPTERS="platform CH04.6"
EXPECTED_RBAC_ADMIN_ROLE="role:admin"
EXPECTED_RBAC_DEFAULT_POLICY="role:readonly"

if [[ "${STATIC_MODE}" == "1" ]]; then
  set +e
  run_static_validation
  static_status=$?
  set -e
  exit "${static_status}"
fi

kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && \
  pass "AUTHENTIK_ROLLOUT" "authentik-server rollout is healthy" || fail "AUTHENTIK_ROLLOUT" "authentik-server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc >/dev/null 2>&1 && \
  pass "ARGOCD_OIDC_SECRET" "argocd-authentik-oidc secret exists" || fail "ARGOCD_OIDC_SECRET" "missing argocd-authentik-oidc secret"

client_id_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null || true)"
client_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_SECRET}' 2>/dev/null || true)"
client_id_value="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)"
dex_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' 2>/dev/null || true)"
server_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2>/dev/null || true)"
legacy_oidc_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.oidc\.authentik\.clientSecret}' 2>/dev/null || true)"
[[ -n "${client_id_present}" && -n "${client_id_value}" ]] && pass "ARGOCD_CLIENT_ID" "client ID is stored in the Kubernetes secret argocd-authentik-oidc" || fail "ARGOCD_CLIENT_ID" "missing or unreadable client ID in argocd-authentik-oidc"
[[ -n "${client_secret_present}" ]] && pass "ARGOCD_CLIENT_SECRET" "client secret is stored in the Kubernetes secret argocd-authentik-oidc" || fail "ARGOCD_CLIENT_SECRET" "missing client secret"
[[ -n "${dex_secret_present}" ]] && pass "ARGOCD_DEX_SECRET_REFERENCE" "argocd-secret contains dex.authentik.clientSecret" || fail "ARGOCD_DEX_SECRET_REFERENCE" "missing argocd-secret Dex clientSecret key"
[[ -n "${server_secret_present}" ]] && pass "ARGOCD_SERVER_SECRETKEY" "argocd-secret contains stable server.secretkey" || fail "ARGOCD_SERVER_SECRETKEY" "missing argocd-secret server.secretkey"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-dex-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_DEX_ROLLOUT" "Argo CD Dex server rollout is healthy" || fail "ARGOCD_DEX_ROLLOUT" "Argo CD Dex server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_ROLLOUT" "Argo CD server rollout is healthy" || fail "ARGOCD_ROLLOUT" "Argo CD server rollout is not healthy"

config_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.dex\.config}' 2>/dev/null || true)"
direct_oidc_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null || true)"
argocd_public_url="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.url}' 2>/dev/null || true)"
rbac_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' 2>/dev/null || true)"
scopes_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.scopes}' 2>/dev/null || true)"

[[ "${argocd_public_url}" == "${EXPECTED_ARGOCD_URL}" ]] && \
  pass "ARGOCD_CM_URL" "argocd-cm data.url is ${EXPECTED_ARGOCD_URL}" || fail "ARGOCD_CM_URL" "argocd-cm data.url is not ${EXPECTED_ARGOCD_URL}"

[[ -z "${direct_oidc_text}" ]] && \
  pass "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is absent because CH04.6 uses Dex-backed SSO" || fail "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is still present"

echo "${config_text}" | grep -q 'name: Authentik' && \
  pass "ARGOCD_DEX_CONNECTOR_NAME" "Argo CD Dex connector is named Authentik" || fail "ARGOCD_DEX_CONNECTOR_NAME" "Dex connector missing Authentik name"

echo "${config_text}" | grep -q 'type: oidc' && \
  pass "ARGOCD_DEX_CONNECTOR_TYPE" "Argo CD Dex connector type is oidc" || fail "ARGOCD_DEX_CONNECTOR_TYPE" "Dex connector type is not oidc"

echo "${config_text}" | grep -qF "issuer: ${EXPECTED_ISSUER}" && \
  pass "ARGOCD_ISSUER" "Dex connector issuer is the discovered Authentik provider issuer ${EXPECTED_ISSUER}" || fail "ARGOCD_ISSUER" "Dex connector issuer does not match the expected Authentik provider issuer ${EXPECTED_ISSUER}"

echo "${config_text}" | grep -qF "clientID: ${client_id_value}" && \
  pass "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID matches stored client ID" || fail "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID mismatch"

echo "${config_text}" | grep -q 'clientSecret: \$dex.authentik.clientSecret' && \
  pass "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret uses the argocd-secret key reference, never an inlined value" || fail "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret reference mismatch"

echo "${config_text}" | grep -q 'insecureEnableGroups: true' && \
  pass "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector enables groups claim handling" || fail "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector missing insecureEnableGroups"

# Every contract scope must be requested by the connector. ARGOCD_GROUP_SCOPE is
# kept as the historical check code for the groups scope.
for scope in ${EXPECTED_SCOPES}; do
  if echo "${config_text}" | grep -qE "^[[:space:]]*-[[:space:]]*${scope}[[:space:]]*$"; then
    if [[ "${scope}" == "groups" ]]; then
      pass "ARGOCD_GROUP_SCOPE" "groups scope is requested by the Dex connector"
    else
      pass "ARGOCD_SCOPE_${scope^^}" "Dex connector requests the ${scope} scope"
    fi
  else
    if [[ "${scope}" == "groups" ]]; then
      fail "ARGOCD_GROUP_SCOPE" "the Dex connector does not request the groups scope"
    else
      fail "ARGOCD_SCOPE_${scope^^}" "the Dex connector does not request the ${scope} scope"
    fi
  fi
done

# The group-to-role mapping must stay deterministic and must not broaden Argo CD
# privilege: exactly one `g,` binding in argocd-rbac-cm, and it must be the single
# admin binding for the validated group. An extra admin binding for any other
# group is a FAIL, because it would grant platform administration the CH04.6
# contract does not map. Only non-secret group names and roles are printed.
rbac_group_lines="$(printf '%s\n' "${rbac_text}" | sed -E 's/[[:space:]]+$//' | grep -E '^g,' || true)"
rbac_admin_lines="$(printf '%s\n' "${rbac_group_lines}" | grep -E ",${EXPECTED_RBAC_ADMIN_ROLE}\$" || true)"
rbac_mapping_count="$(printf '%s\n' "${rbac_group_lines}" | grep -cE '^g,' || true)"

if [[ "${rbac_mapping_count}" == "1" && "${rbac_admin_lines}" == "g, ${EXPECTED_ADMIN_GROUP}, ${EXPECTED_RBAC_ADMIN_ROLE}" ]]; then
  pass "ARGOCD_RBAC_ADMIN_GROUP" "argocd-rbac-cm carries exactly one group binding and it is the expected admin mapping for the validated group"
else
  fail "ARGOCD_RBAC_ADMIN_GROUP" "argocd-rbac-cm must carry exactly one binding 'g, ${EXPECTED_ADMIN_GROUP}, ${EXPECTED_RBAC_ADMIN_ROLE}'; found ${rbac_mapping_count} group binding(s): ${rbac_group_lines:-<none>}"
fi

rbac_default_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.default}' 2>/dev/null || true)"
if [[ -z "${rbac_default_text}" || "${rbac_default_text}" == "${EXPECTED_RBAC_DEFAULT_POLICY}" ]]; then
  pass "ARGOCD_RBAC_DEFAULT_POLICY" "argocd-rbac-cm policy.default is ${EXPECTED_RBAC_DEFAULT_POLICY} (an unset key also means Argo CD's read-only default)"
else
  fail "ARGOCD_RBAC_DEFAULT_POLICY" "argocd-rbac-cm policy.default is '${rbac_default_text}', which is broader than '${EXPECTED_RBAC_DEFAULT_POLICY}'"
fi

echo "${scopes_text}" | grep -q 'groups' && \
  pass "ARGOCD_RBAC_SCOPES" "RBAC scopes include groups" || warn "ARGOCD_RBAC_SCOPES" "RBAC scopes do not include groups"

# The legacy direct-OIDC client secret key is reconciled away by CH04.6. It is
# inert here, so its presence is a warning: it must not become a third secret
# reference that implies a parallel direct-OIDC path.
if [[ -z "${legacy_oidc_secret_present}" ]]; then
  pass "ARGOCD_LEGACY_OIDC_SECRET_ABSENT" "argocd-secret carries exactly one OIDC client secret key (Dex-backed path only)"
else
  warn "ARGOCD_LEGACY_OIDC_SECRET_ABSENT" "argocd-secret still carries the legacy direct-OIDC key oidc.authentik.clientSecret; re-run the CH04.6 reconciliation to retire it"
fi

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  discovery_url="${EXPECTED_ISSUER}.well-known/openid-configuration"
  discovery_json="$(curl -fsSL --retry 3 --retry-delay 2 "${discovery_url}" 2>/dev/null || true)"
  if [[ -n "${discovery_json}" ]]; then
    DISCOVERY_JSON="${discovery_json}" python3 - <<'PYALGS' && \
      pass "AUTHENTIK_OIDC_SIGNING_ALG" "OIDC discovery does not advertise symmetric-only HS* signing" || \
      fail "AUTHENTIK_OIDC_SIGNING_ALG" "OIDC discovery appears to advertise symmetric-only HS* signing"
import json
import os
import sys

doc = json.loads(os.environ["DISCOVERY_JSON"])
algs = doc.get("id_token_signing_alg_values_supported", []) or []
if algs and all(str(alg).upper().startswith("HS") for alg in algs):
    print("symmetric-only algorithms:", ",".join(map(str, algs)), file=sys.stderr)
    sys.exit(1)
print("algorithms:", ",".join(map(str, algs)) or "not-advertised")
PYALGS

    DISCOVERY_JSON="${discovery_json}" EXPECTED_ISSUER="${EXPECTED_ISSUER}" python3 - <<'PYISSUER' && \
      pass "AUTHENTIK_OIDC_ISSUER_MATCH" "discovery issuer equals the provider issuer ${EXPECTED_ISSUER}" || \
      fail "AUTHENTIK_OIDC_ISSUER_MATCH" "discovery issuer does not equal the expected provider issuer ${EXPECTED_ISSUER}"
import json
import os
import sys

doc = json.loads(os.environ["DISCOVERY_JSON"])
issuer = str(doc.get("issuer", "")).rstrip("/")
expected = os.environ["EXPECTED_ISSUER"].rstrip("/")
if issuer != expected:
    print(f"discovery issuer {issuer!r} != expected {expected!r}", file=sys.stderr)
    sys.exit(1)
print("issuer:", issuer)
PYISSUER
  else
    warn "AUTHENTIK_OIDC_SIGNING_ALG" "skipped signing algorithm validation; discovery endpoint could not be fetched"
    warn "AUTHENTIK_OIDC_ISSUER_MATCH" "skipped discovery issuer validation; discovery endpoint could not be fetched"
  fi
fi

# ---------------------------------------------------------------------------
# Authentik provider/application contract (read-only API session)
#
# One session asserts the CH04.5 group consumption, the admin membership and the
# whole Argo CD provider/application contract. Findings aggregate: every check
# emits a PASS/FAIL/WARN line and the block exits non-zero when a contract check
# failed. No secret value is read or printed.
# ---------------------------------------------------------------------------
read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
  AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
fi

if [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] && command -v python3 >/dev/null 2>&1; then
  contract_output=""
  if ! contract_output="$(AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL}" \
      AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN}" \
      EXPECTED_ADMIN_GROUP="${EXPECTED_ADMIN_GROUP}" \
      EXPECTED_ADMIN_USERNAME="${EXPECTED_ADMIN_USERNAME}" \
      EXPECTED_CLIENT_ID="${client_id_value}" \
      EXPECTED_PROVIDER_NAME="${EXPECTED_PROVIDER_NAME}" \
      EXPECTED_PROVIDER_SLUG="${EXPECTED_PROVIDER_SLUG}" \
      EXPECTED_REDIRECT_URI="${EXPECTED_REDIRECT_URI}" \
      EXPECTED_CLI_CALLBACK_URI="${EXPECTED_CLI_CALLBACK_URI}" \
      EXPECTED_LOGOUT_URI="${EXPECTED_LOGOUT_URI}" \
      EXPECTED_SCOPES="${EXPECTED_SCOPES}" \
      EXPECTED_MANAGED_BY="${EXPECTED_MANAGED_BY}" \
      EXPECTED_OWNER_CHAPTER="${EXPECTED_OWNER_CHAPTER}" \
      EXPECTED_CONSUMER_CHAPTERS="${EXPECTED_CONSUMER_CHAPTERS}" \
      python3 - <<'PYCONTRACT'
import json
import os
import sys
import urllib.parse
import urllib.request

base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
group_name = os.environ["EXPECTED_ADMIN_GROUP"]
username = os.environ["EXPECTED_ADMIN_USERNAME"]
expected_client_id = os.environ.get("EXPECTED_CLIENT_ID", "")
provider_name = os.environ.get("EXPECTED_PROVIDER_NAME", "Argo CD")
provider_slug = os.environ.get("EXPECTED_PROVIDER_SLUG", "argocd")
expected_redirect = os.environ.get("EXPECTED_REDIRECT_URI", "")
expected_cli_callback = os.environ.get("EXPECTED_CLI_CALLBACK_URI", "")
expected_logout = os.environ.get("EXPECTED_LOGOUT_URI", "")
expected_scopes = [scope for scope in os.environ.get("EXPECTED_SCOPES", "").split() if scope]
expected_managed_by = os.environ.get("EXPECTED_MANAGED_BY", "")
expected_owner_chapter = os.environ.get("EXPECTED_OWNER_CHAPTER", "")
expected_consumer_chapters = [
    chapter
    for chapter in os.environ.get("EXPECTED_CONSUMER_CHAPTERS", "").split()
    if chapter
]
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
}

failures = []


def emit(status, check, detail):
    print(f"{status} | {check} | {detail}")


def expect(ok, check, detail_ok, detail_fail):
    if ok:
        emit("PASS", check, detail_ok)
    else:
        emit("FAIL", check, detail_fail)
        failures.append(check)


def expect_field(obj, key, expected, check, detail_ok, detail_fail):
    """Assert obj[key] == expected; WARN when the API does not expose the field."""
    if key not in obj:
        emit("WARN", check,
             f"the Authentik API response does not expose {key!r}; the contract value is asserted on the write path only")
        return
    expect(str(obj.get(key)) == str(expected), check, detail_ok, detail_fail)


def request(path):
    req = urllib.request.Request(f"{base_url}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def results(path):
    obj = request(path)
    if isinstance(obj, dict):
        return obj.get("results", [])
    if isinstance(obj, list):
        return obj
    return []


def exact(path, field, value):
    enc = urllib.parse.quote(value)
    for query in (f"{field}={enc}", f"search={enc}"):
        for item in results(f"{path}?{query}"):
            if item.get(field) == value:
                return item
    return None


def search_exact(path, field, value):
    enc = urllib.parse.quote(value)
    return [item for item in results(f"{path}?search={enc}") if item.get(field) == value]


def group_ids(raw):
    out = []
    for item in raw or []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict):
            val = item.get("pk") or item.get("id") or item.get("uuid")
            if val:
                out.append(val)
    return out


def canonical_url(value):
    """Canonicalize only the case-insensitive URL semantics.

    Scheme and host/authority are case-insensitive (RFC 3986), so a live entry
    written as `HTTPS://ARGOCD.<domain>/api/dex/callback` is the same redirect
    target as the lowercase contract value. Path, query and fragment stay
    byte-exact, because redirect paths are case-sensitive, and a trailing slash
    is still not a different target. This single helper is used by every URL
    comparison - the logout_uri field check, the per-entry strict matcher and
    the completeness comparison - so a casing difference can neither produce a
    false failure nor bypass a check.
    """
    raw = str(value or "").rstrip("/")
    parts = urllib.parse.urlsplit(raw)
    if not parts.scheme and not parts.netloc:
        # Relative, placeholder or regex-shaped value: nothing case-insensitive
        # to canonicalize, so the value is compared exactly as received.
        return raw
    return urllib.parse.urlunsplit((
        parts.scheme.lower(),
        parts.netloc.lower(),
        parts.path,
        parts.query,
        parts.fragment,
    ))


def same_url(left, right):
    return canonical_url(left) == canonical_url(right)


# --- A. CH04.5-owned admin group: consumed, never redefined ----------------
group = exact("/api/v3/core/groups/", "name", group_name)
expect(group is not None, "AUTHENTIK_ADMIN_GROUP_EXISTS",
       f"CH04.5-managed group {group_name!r} exists",
       f"CH04.5 group {group_name!r} is missing; run '04.5 - Deploy Identity Foundation' "
       "(scripts/ch04-5-bootstrap-identity-model.sh) first")

if group:
    expect(not group.get("is_superuser"), "AUTHENTIK_ADMIN_GROUP_NON_SUPERUSER",
           f"CH04.5 group {group_name!r} is not an Authentik superuser group",
           f"CH04.5 group {group_name!r} is an Authentik superuser group")
    expect(not group.get("parent"), "AUTHENTIK_ADMIN_GROUP_NO_PARENT",
           f"CH04.5 group {group_name!r} does not inherit from a parent group",
           f"CH04.5 group {group_name!r} inherits from parent group {group.get('parent')!r}")

    # CH04.5 managed ownership stamps. These are exactly the attributes the CH04.6
    # reconciliation must never clear or overwrite, so a missing or foreign-owned
    # stamp is blocking instead of a warning: binding an unstamped or foreign-owned
    # group to Argo CD role:admin would grant unreviewed platform administration.
    attributes = group.get("attributes")
    if not isinstance(attributes, dict):
        attributes = {}
    if not attributes:
        group_detail = request(f"/api/v3/core/groups/{group['pk']}/")
        detail_attributes = group_detail.get("attributes")
        if isinstance(detail_attributes, dict):
            attributes = detail_attributes

    expected_stamps = {
        "platforminit_managed_by": expected_managed_by,
        "platforminit_owner_chapter": expected_owner_chapter,
    }
    present_stamps = (
        "platforminit_contract_version",
        "platforminit_scope",
        "platforminit_consumer_chapter",
    )
    missing_stamps = sorted(
        key for key in list(expected_stamps) + list(present_stamps)
        if not str(attributes.get(key, "")).strip()
    )
    expect(not missing_stamps, "AUTHENTIK_ADMIN_GROUP_OWNERSHIP",
           "CH04.5 managed ownership stamps are present on the group",
           f"CH04.5 managed ownership stamps are missing from the group "
           f"({', '.join(missing_stamps)}); the CH04.6 reconciliation must never clear them, so re-run "
           "'04.5 - Deploy Identity Foundation' (scripts/ch04-5-bootstrap-identity-model.sh) to re-stamp "
           "the group")

    if not missing_stamps:
        mismatched_stamps = sorted(
            key for key, value in expected_stamps.items() if str(attributes.get(key)) != value
        )
        expect(not mismatched_stamps, "AUTHENTIK_ADMIN_GROUP_OWNERSHIP_VALUES",
               "the CH04.5 managed ownership stamps name the CH04.5 reconciler and the CH04.5 owner chapter",
               f"CH04.5 managed ownership stamp value mismatch ({', '.join(mismatched_stamps)}); the group is "
               "not the CH04.5-managed object this mapping is contracted to consume")

        stamped_consumer = str(attributes.get("platforminit_consumer_chapter"))
        expect(stamped_consumer in expected_consumer_chapters, "AUTHENTIK_ADMIN_GROUP_CONSUMER_SCOPE",
               f"the group is stamped for an allowed consumer chapter ({stamped_consumer!r})",
               f"the group is stamped with consumer chapter {stamped_consumer!r}, which is not one of "
               f"{expected_consumer_chapters}; mapping it to Argo CD role:admin would widen another "
               "consumer's group into platform administration")

# --- B. Argo CD admin membership -------------------------------------------
user = exact("/api/v3/core/users/", "username", username)
expect(user is not None, "AUTHENTIK_ARGOCD_ADMIN_USER",
       f"Authentik user {username} exists",
       f"Authentik user {username} is missing; set AUTHENTIK_ARGOCD_ADMIN_USERNAME if the bootstrap admin differs")
if user and group:
    user_detail = request(f"/api/v3/core/users/{user['pk']}/")
    expect(group["pk"] in group_ids(user_detail.get("groups", [])), "AUTHENTIK_ARGOCD_ADMIN_GROUP",
           f"{username} is a direct member of non-superuser {group_name}",
           f"{username} is not a direct member of {group_name}")

# --- C. Authentik OIDC provider contract -----------------------------------
provider = exact("/api/v3/providers/oauth2/", "name", provider_name)
expect(provider is not None, "AUTHENTIK_PROVIDER_EXISTS",
       f"Authentik OAuth2/OIDC provider {provider_name!r} exists",
       f"Authentik OAuth2/OIDC provider {provider_name!r} is missing; re-run the CH04.6 SSO reconciliation")

if provider:
    expect(len(search_exact("/api/v3/providers/oauth2/", "name", provider_name)) == 1,
           "AUTHENTIK_PROVIDER_UNIQUE",
           f"exactly one OAuth2/OIDC provider is named {provider_name!r}, so no parallel OIDC path exists",
           f"expected exactly one provider named {provider_name!r}")

    expect_field(provider, "client_type", "confidential", "AUTHENTIK_PROVIDER_CLIENT_TYPE",
                 "provider client_type is confidential",
                 f"provider client_type is {provider.get('client_type')!r}, expected 'confidential'")

    if "grant_types" in provider:
        grant_types = sorted(str(grant) for grant in (provider.get("grant_types") or []))
        expect("authorization_code" in grant_types, "AUTHENTIK_PROVIDER_GRANT_TYPES",
               f"provider grant_types include authorization_code ({grant_types})",
               f"provider grant_types do not include authorization_code ({grant_types})")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_GRANT_TYPES",
             "the Authentik API response does not expose 'grant_types'; the contract value is asserted on the write path only")

    expect_field(provider, "sub_mode", "hashed_user_id", "AUTHENTIK_PROVIDER_SUB_MODE",
                 "provider sub_mode is hashed_user_id",
                 f"provider sub_mode is {provider.get('sub_mode')!r}, expected 'hashed_user_id'")

    expect_field(provider, "issuer_mode", "per_provider", "AUTHENTIK_PROVIDER_ISSUER_MODE",
                 "provider issuer_mode is per_provider, so the issuer is provider-scoped",
                 f"provider issuer_mode is {provider.get('issuer_mode')!r}, expected 'per_provider'")

    expect_field(provider, "include_claims_in_id_token", True, "AUTHENTIK_PROVIDER_ID_TOKEN_CLAIMS",
                 "provider includes claims in the ID token, so the groups claim reaches Argo CD RBAC",
                 "provider does not include claims in the ID token")

    expect(bool(provider.get("signing_key")), "AUTHENTIK_PROVIDER_SIGNING_KEY",
           "provider pins an asymmetric signing key (JWKS-backed RS256 path for Argo CD/Dex)",
           "provider has no signing_key, so Argo CD/Dex has no asymmetric JWKS path "
           "(set AUTHENTIK_ARGOCD_SIGNING_KEY_NAME or let the reconciliation select a key)")

    # The client id is a non-secret identifier: it is compared with the value
    # stored in argocd/argocd-authentik-oidc. The client secret value is never
    # read; only its presence is probed.
    if expected_client_id:
        expect(str(provider.get("client_id")) == expected_client_id, "AUTHENTIK_PROVIDER_CLIENT_ID",
               "provider client_id matches the client id stored in argocd-authentik-oidc",
               "provider client_id does not match the client id stored in argocd-authentik-oidc")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_CLIENT_ID",
             "the argocd-authentik-oidc client id could not be read, so the provider client id could not be cross-checked")

    if "client_secret" in provider:
        expect(bool(provider.get("client_secret")), "AUTHENTIK_PROVIDER_CLIENT_SECRET_SET",
               "provider has a client secret configured (presence only; the value is never read or printed)",
               "provider has no client secret configured")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_CLIENT_SECRET_SET",
             "the Authentik API response does not expose 'client_secret'; secret-key ownership is asserted "
             "through the argocd-secret key checks instead")

    if "logout_uri" in provider:
        expect(same_url(provider.get("logout_uri"), expected_logout), "AUTHENTIK_PROVIDER_LOGOUT_URI",
               f"provider logout_uri is {expected_logout}",
               f"provider logout_uri is {provider.get('logout_uri')!r}, expected {expected_logout}")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_LOGOUT_URI",
             "the Authentik API response does not expose 'logout_uri'; the contract value is asserted on the write path only")

    expect_field(provider, "logout_method", "frontchannel", "AUTHENTIK_PROVIDER_LOGOUT_METHOD",
                 "provider logout_method is frontchannel",
                 f"provider logout_method is {provider.get('logout_method')!r}, expected 'frontchannel'")

    # Strict redirect allow-list, asserted in two steps: every expected entry must
    # be present with matching_mode `strict`, and the complete live redirect_uris
    # collection must contain nothing else. The second step is the completeness
    # boundary: an extra wildcard/prefix/regex entry, a duplicate, a non-strict
    # matching mode or an unexpected redirect_uri_type fails closed, so an
    # already-drifted provider cannot pass merely because the reconciliation
    # writer normally replaces the list. The redirect URI list is the contract's
    # anti-open-redirect boundary (runbook: "no wildcard, prefix or regex
    # matching").
    redirect_uris = provider.get("redirect_uris") or []
    expected_redirect_targets = (
        (expected_redirect, "authorization"),
        (expected_cli_callback, "authorization"),
        (expected_logout, "logout"),
    )

    # Both redirect comparisons below (the per-entry matcher and the
    # completeness comparison) normalize through the single module-level
    # `canonical_url()` helper, so they cannot disagree about scheme/host casing
    # or a trailing slash, and neither can be bypassed by casing.
    def redirect_tuple(entry):
        """Normalize one API entry into the comparable (url, type, mode) tuple."""
        if not isinstance(entry, dict):
            return (f"<malformed entry: {type(entry).__name__}>", "", "")
        return (
            canonical_url(entry.get("url")),
            str(entry.get("redirect_uri_type", "")),
            str(entry.get("matching_mode", "")),
        )

    def render_redirect(entry_tuple):
        url, uri_type, matching_mode = entry_tuple
        return (f"(url={url!r}, redirect_uri_type={uri_type!r}, "
                f"matching_mode={matching_mode!r})")

    def render_redirect_list(entries, limit=5):
        rendered = ", ".join(entries[:limit])
        if len(entries) > limit:
            rendered += f", ... (+{len(entries) - limit} more)"
        return rendered

    expected_redirect_tuples = [
        (canonical_url(url), uri_type, "strict")
        for url, uri_type in expected_redirect_targets
    ]
    actual_redirect_tuples = [redirect_tuple(entry) for entry in redirect_uris]

    def strict_entry_registered(url, uri_type):
        return (canonical_url(url), uri_type, "strict") in actual_redirect_tuples

    expect(strict_entry_registered(expected_redirect, "authorization"), "AUTHENTIK_PROVIDER_REDIRECT_URI",
           f"strict authorization redirect URI {expected_redirect} is registered",
           f"the strict authorization redirect URI {expected_redirect} is not registered")
    expect(strict_entry_registered(expected_cli_callback, "authorization"), "AUTHENTIK_PROVIDER_CLI_CALLBACK_URI",
           f"strict Argo CD CLI callback URI {expected_cli_callback} is registered",
           f"the strict Argo CD CLI callback URI {expected_cli_callback} is not registered")
    expect(strict_entry_registered(expected_logout, "logout"), "AUTHENTIK_PROVIDER_LOGOUT_REDIRECT_URI",
           f"strict logout redirect URI {expected_logout} is registered",
           f"the strict logout redirect URI {expected_logout} is not registered")

    # Completeness of the collection: exactly the expected strict tuples, once
    # each. Only non-secret contract values are rendered in the detail.
    expected_rendered_redirects = sorted(render_redirect(item) for item in expected_redirect_tuples)
    actual_rendered_redirects = sorted(render_redirect(item) for item in actual_redirect_tuples)
    extra_redirects = sorted(set(actual_rendered_redirects) - set(expected_rendered_redirects))
    missing_redirects = sorted(set(expected_rendered_redirects) - set(actual_rendered_redirects))
    duplicate_redirects = sorted(
        {item for item in actual_rendered_redirects if actual_rendered_redirects.count(item) > 1}
    )
    non_strict_redirects = sorted(
        render_redirect(item) for item in actual_redirect_tuples if item[2] != "strict"
    )
    unexpected_type_redirects = sorted(
        render_redirect(item) for item in actual_redirect_tuples
        if item[1] not in ("authorization", "logout")
    )

    if not (extra_redirects or missing_redirects or duplicate_redirects
            or non_strict_redirects or unexpected_type_redirects):
        emit("PASS", "AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST",
             f"the provider redirect_uris allow-list is exactly the three strict contract entries "
             f"({len(actual_redirect_tuples)} entries; no extra, duplicate, non-strict or unexpected-type entry)")
    else:
        reasons = []
        if extra_redirects:
            reasons.append(f"unexpected extra entries: {render_redirect_list(extra_redirects)}")
        if missing_redirects:
            reasons.append(f"missing expected entries: {render_redirect_list(missing_redirects)}")
        if duplicate_redirects:
            reasons.append(f"duplicate entries: {render_redirect_list(duplicate_redirects)}")
        if non_strict_redirects:
            reasons.append(
                "entries whose matching_mode is not 'strict': "
                f"{render_redirect_list(non_strict_redirects)}"
            )
        if unexpected_type_redirects:
            reasons.append(
                "entries with an unexpected redirect_uri_type: "
                f"{render_redirect_list(unexpected_type_redirects)}"
            )
        emit("FAIL", "AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST",
             "the provider redirect_uris allow-list is not exactly the three strict contract entries; "
             + "; ".join(reasons))
        failures.append("AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST")

    mapped_pks = [str(item.get("pk") if isinstance(item, dict) else item)
                  for item in (provider.get("property_mappings") or [])]
    scope_index = {}
    for item in results("/api/v3/propertymappings/provider/scope/?page_size=200"):
        scope_index[str(item.get("pk"))] = item

    def scope_mapped(scope):
        # Mirrors the reconciliation rule: match the scope_name, or the mapping
        # name that authenticates the default openid/profile/email mappings.
        for pk in mapped_pks:
            item = scope_index.get(pk) or {}
            if str(item.get("scope_name", "")) == scope \
                    or f"'{scope}'" in str(item.get("name", "")).lower():
                return True
        return False

    for scope in expected_scopes:
        expect(scope_mapped(scope), f"AUTHENTIK_PROVIDER_SCOPE_{scope.upper()}",
               f"provider maps a {scope} scope mapping",
               f"provider has no {scope} scope mapping")

# --- D. Authentik application contract -------------------------------------
app = exact("/api/v3/core/applications/", "slug", provider_slug)
expect(app is not None, "AUTHENTIK_APPLICATION_EXISTS",
       f"Authentik application slug {provider_slug!r} exists",
       f"Authentik application slug {provider_slug!r} is missing; re-run the CH04.6 SSO reconciliation")

if app:
    expect(len(search_exact("/api/v3/core/applications/", "slug", provider_slug)) == 1,
           "AUTHENTIK_APPLICATION_UNIQUE",
           f"exactly one application has slug {provider_slug!r}, so no parallel application path exists",
           f"expected exactly one application with slug {provider_slug!r}")

if app and provider:
    linked = app.get("provider")
    linked_pk = linked.get("pk") if isinstance(linked, dict) else linked
    expect(str(linked_pk) == str(provider.get("pk")), "AUTHENTIK_APPLICATION_PROVIDER_LINK",
           "application provider link resolves to the single asserted Argo CD OIDC provider",
           "application provider link does not resolve to the asserted Argo CD OIDC provider")

if failures:
    print(f"contract failures ({len(failures)}): {', '.join(sorted(set(failures)))}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYCONTRACT
)"; then
    printf '%s\n' "${contract_output}" >&2
    fail "AUTHENTIK_ARGOCD_OIDC_CONTRACT" "Authentik Argo CD OIDC provider/application contract validation failed"
  fi
  printf '%s\n' "${contract_output}"
else
  warn "AUTHENTIK_ARGOCD_OIDC_CONTRACT" "skipped Authentik OIDC provider/application contract validation; missing bootstrap token or python3"
fi

if command -v curl >/dev/null 2>&1; then
  if curl -fsSIk "https://argocd.${BASE_DOMAIN}" >/dev/null 2>&1; then
    pass "ARGOCD_HTTPS" "Argo CD URL responds over HTTPS"
  else
    warn "ARGOCD_HTTPS" "Argo CD HTTPS check failed from host; verify DNS/TLS externally"
  fi
fi
