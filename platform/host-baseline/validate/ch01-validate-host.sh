#!/usr/bin/env bash
set -euo pipefail

CH01_RUNTIME_ROOT="${CH01_RUNTIME_ROOT:-/srv/ch01-runtime}"
REPORT_DIR="${REPORT_DIR:-${CH01_RUNTIME_ROOT}/reports}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_MD="${REPORT_MD:-$REPORT_DIR/validate-host-${TS}.md}"
REPORT_JSON="${REPORT_JSON:-$REPORT_DIR/validate-host-${TS}.json}"
EXPECTED_USER="${EXPECTED_USER:-devops}"
BROKER_USER="${BROKER_USER:-itadmin}"

# Resolve baseline profile
PLATFORMINIT_BASELINE_PROFILE="${PLATFORMINIT_BASELINE_PROFILE:-}"
if [[ -z "$PLATFORMINIT_BASELINE_PROFILE" && -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
PLATFORMINIT_BASELINE_PROFILE="${PLATFORMINIT_BASELINE_PROFILE:-platform-k3s}"

mkdir -p "$REPORT_DIR"
PASS=0; WARN=0; FAIL=0; CHECKS_JSON=""
json_escape(){ local s=${1:-}; s=${s//\\/\\\\}; s=${s//"/\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}; printf '%s' "$s"; }
append_check(){ local id="$1" sev="$2" st="$3" obs="$4" exp="$5"; local entry; entry=$(printf '{"id":"%s","severity":"%s","status":"%s","observed":"%s","expected":"%s"}' "$(json_escape "$id")" "$(json_escape "$sev")" "$(json_escape "$st")" "$(json_escape "$obs")" "$(json_escape "$exp")"); [[ -n "$CHECKS_JSON" ]] && CHECKS_JSON+=$'\n,'; CHECKS_JSON+="$entry"; }
md(){ printf '%s\n' "$*" >> "$REPORT_MD"; }
section(){ md ""; md "$1"; md ""; }
res(){ local sev="$1" id="$2" msg="$3" obs="${4:-}" exp="${5:-}"; case "$sev" in PASS) PASS=$((PASS+1)); append_check "$id" PASS pass "$obs" "$exp" ;; WARN) WARN=$((WARN+1)); append_check "$id" WARN warn "$obs" "$exp" ;; FAIL) FAIL=$((FAIL+1)); append_check "$id" FAIL fail "$obs" "$exp" ;; esac; md "$sev | $id | $msg"; }

: > "$REPORT_MD"
md "# CH01 Host validation report"
md "- Generated: $(date -u +%FT%TZ)"
md "- Host: $(hostname -f 2>/dev/null || hostname)"
md "- Baseline profile: ${PLATFORMINIT_BASELINE_PROFILE}"

section "## Users"
id "$EXPECTED_USER" >/dev/null 2>&1 && res PASS USER_DEVOPS "$EXPECTED_USER exists" || res FAIL USER_DEVOPS "$EXPECTED_USER missing"
id "$BROKER_USER" >/dev/null 2>&1 && res PASS USER_ITADMIN "$BROKER_USER exists" || res FAIL USER_ITADMIN "$BROKER_USER missing"
for user in "$EXPECTED_USER" "$BROKER_USER"; do
  if [[ -f "/home/${user}/.ssh/authorized_keys" ]]; then
    dir_mode="$(stat -c '%a' "/home/${user}/.ssh" 2>/dev/null || true)"
    key_mode="$(stat -c '%a' "/home/${user}/.ssh/authorized_keys" 2>/dev/null || true)"
    [[ "$dir_mode" == "700" && "$key_mode" == "600" ]] && res PASS "AUTH_KEYS_${user^^}" "authorized_keys permissions ok for $user" ".ssh=$dir_mode key=$key_mode" ".ssh=700 key=600" || res FAIL "AUTH_KEYS_${user^^}" "authorized_keys permissions wrong for $user" ".ssh=$dir_mode key=$key_mode" ".ssh=700 key=600"
  else
    res FAIL "AUTH_KEYS_${user^^}" "authorized_keys missing for $user"
  fi
done

section "## Privilege model"
if [[ ! -f /etc/sudoers.d/devops ]] && [[ ! -f /etc/sudoers.d/devops-temp ]] && [[ ! -f /etc/sudoers.d/devops-temporary ]] && [[ ! -f /etc/sudoers.d/devops-elevation ]]; then
  res PASS DEVOPS_NO_STANDING_SUDO "devops has no standing sudo drop-in"
else
  res WARN DEVOPS_NO_STANDING_SUDO "devops temporary/elevated sudo drop-in present"
fi
if [[ -f /etc/sudoers.d/itadmin-platforminit ]] && visudo -cf /etc/sudoers.d/itadmin-platforminit >/dev/null 2>&1; then
  res PASS ITADMIN_BROKER_POLICY "itadmin scoped broker policy present"
else
  res FAIL ITADMIN_BROKER_POLICY "itadmin scoped broker policy missing or invalid"
fi

section "## SSH"
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
  res PASS SSH_SERVICE "sshd service active"
else
  res FAIL SSH_SERVICE "sshd service not active"
fi
sshd_cfg="$(sshd -T 2>/dev/null || true)"
if [[ -z "$sshd_cfg" ]]; then
  res FAIL SSH_EFFECTIVE_CONFIG "Cannot read effective sshd config"
else
  if grep -q '^permitrootlogin no$' <<< "$sshd_cfg"; then
    res PASS SSH_ROOT_LOGIN "PermitRootLogin no"
  else
    res FAIL SSH_ROOT_LOGIN "PermitRootLogin not set to no"
  fi
  if grep -q '^passwordauthentication no$' <<< "$sshd_cfg"; then
    res PASS SSH_PASSWORD_AUTH "PasswordAuthentication no"
  else
    res FAIL SSH_PASSWORD_AUTH "PasswordAuthentication not set to no"
  fi
  if grep -q '^pubkeyauthentication yes$' <<< "$sshd_cfg"; then
    res PASS SSH_PUBKEY_AUTH "PubkeyAuthentication yes"
  else
    res FAIL SSH_PUBKEY_AUTH "PubkeyAuthentication not set to yes"
  fi
fi

section "## Volume layout"
if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
  res PASS HOST_CONTEXT "host context present" "/etc/platforminit/host-context.env"
else
  PLATFORMINIT_VOLUME_LAYOUT="single"
  PLATFORMINIT_SRV_PATH="/srv"
  PLATFORMINIT_DATA_PATH="/srv/data"
  PLATFORMINIT_DB_PATH="/srv/db"
  PLATFORMINIT_OBSERVABILITY_PATH="/srv/observability"
  res WARN HOST_CONTEXT "host context missing; using legacy single-volume assumptions"
fi
PLATFORMINIT_VOLUME_LAYOUT="${PLATFORMINIT_VOLUME_LAYOUT:-single}"
PLATFORMINIT_SRV_PATH="${PLATFORMINIT_SRV_PATH:-/srv}"
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
PLATFORMINIT_DB_PATH="${PLATFORMINIT_DB_PATH:-/srv/db}"
PLATFORMINIT_OBSERVABILITY_PATH="${PLATFORMINIT_OBSERVABILITY_PATH:-/srv/observability}"
check_mount(){
  local id="$1" path="$2"
  if mountpoint -q "$path"; then
    res PASS "$id" "$path is mounted" "$(findmnt -n -o SOURCE,SIZE,USE% "$path" 2>/dev/null || true)"
  else
    res FAIL "$id" "$path is not mounted" "missing" "mounted persistent volume"
  fi
}
case "$PLATFORMINIT_VOLUME_LAYOUT" in
  none)
    [[ -d "$PLATFORMINIT_SRV_PATH" ]] && res PASS VOLUME_LAYOUT_NONE "no persistent volume layout selected" "$PLATFORMINIT_SRV_PATH exists" || res FAIL VOLUME_LAYOUT_NONE "$PLATFORMINIT_SRV_PATH missing"
    if mountpoint -q /srv 2>/dev/null; then
      srv_src="$(findmnt -n -o SOURCE /srv 2>/dev/null || true)"
      res FAIL VOLUME_LAYOUT_NONE_UNEXPECTED_MOUNT "volume_layout=none but /srv is a mountpoint" "source=${srv_src}" "no mount expected"
    else
      res PASS VOLUME_LAYOUT_NONE_NO_MOUNT "volume_layout=none: /srv is not a mountpoint (root-disk-only)"
    fi
    unexpected_disks="$(lsblk -pnro NAME,TYPE,MOUNTPOINT 2>/dev/null | awk -F' ' '$2=="disk" && $3=="" {print $1}' | grep -v "$(lsblk -nlo PKNAME "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null)" || true)"
    if [[ -n "$unexpected_disks" ]]; then
      res WARN VOLUME_LAYOUT_NONE_UNEXPECTED_DISK "volume_layout=none but unattached disk(s) detected" "$(echo "$unexpected_disks" | tr '\n' ' ')" "no unattached disks"
    else
      res PASS VOLUME_LAYOUT_NONE_NO_UNEXPECTED_DISK "volume_layout=none: no unattached disks detected"
    fi
    ;;
  single)
    check_mount VOLUME_SRV_MOUNT "$PLATFORMINIT_SRV_PATH"
    ;;
  split)
    if mountpoint -q /srv && ! grep -qE $'^[^\t]+\t[^\t]+\t[^\t]+\t/srv$' /etc/platforminit/volume-layout.tsv 2>/dev/null; then
      res FAIL VOLUME_STALE_SRV_MOUNT "/srv is mounted even though split layout expects /srv/data, /srv/db and /srv/observability" "$(findmnt -n -o SOURCE /srv 2>/dev/null || true)" "no direct /srv mount in split layout"
    else
      res PASS VOLUME_NO_STALE_SRV_MOUNT "no stale /srv mount detected for split layout"
    fi
    check_mount VOLUME_DATA_MOUNT "$PLATFORMINIT_DATA_PATH"
    check_mount VOLUME_DB_MOUNT "$PLATFORMINIT_DB_PATH"
    check_mount VOLUME_OBSERVABILITY_MOUNT "$PLATFORMINIT_OBSERVABILITY_PATH"
    ;;
  *)
    res FAIL VOLUME_LAYOUT_SUPPORTED "unsupported volume layout: $PLATFORMINIT_VOLUME_LAYOUT"
    ;;
esac

section "## Baseline profile"
case "$PLATFORMINIT_BASELINE_PROFILE" in
  platform-k3s)
    res PASS BASELINE_PROFILE_VALID "baseline profile: ${PLATFORMINIT_BASELINE_PROFILE} (full k3s host)" "${PLATFORMINIT_BASELINE_PROFILE}" "known profile"
    # platform-k3s expects k3s-related paths
    if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
      res PASS PROFILE_K3S_CONFIG "k3s config present (expected for platform-k3s profile)"
    else
      res WARN PROFILE_K3S_CONFIG "k3s config not present (may not be installed yet)"
    fi
    ;;
  standalone-n8n)
    res PASS BASELINE_PROFILE_VALID "baseline profile: ${PLATFORMINIT_BASELINE_PROFILE} (standalone n8n, no k3s)" "${PLATFORMINIT_BASELINE_PROFILE}" "known profile"
    # standalone-n8n should NOT have k3s
    if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
      res WARN PROFILE_N8N_K3S_UNEXPECTED "k3s config present but profile is standalone-n8n (unexpected)"
    else
      res PASS PROFILE_N8N_NO_K3S "no k3s config (expected for standalone-n8n profile)"
    fi
    ;;
  *)
    res FAIL BASELINE_PROFILE_VALID "unknown baseline profile: ${PLATFORMINIT_BASELINE_PROFILE}" "${PLATFORMINIT_BASELINE_PROFILE}" "platform-k3s or standalone-n8n"
    ;;
esac

section "## Baseline evidence"
AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"
LEGACY_AUDIT_DIR="/var/lib/platforminit/audit"
if [[ -f "$AUDIT_DIR/bootstrap-host-access.json" || -f "$LEGACY_AUDIT_DIR/bootstrap-host-access.json" ]]; then
  res PASS BOOTSTRAP_AUDIT "Bootstrap audit marker present" "$AUDIT_DIR or $LEGACY_AUDIT_DIR"
else
  res FAIL BOOTSTRAP_AUDIT "Bootstrap audit marker missing" "checked=$AUDIT_DIR/bootstrap-host-access.json or $LEGACY_AUDIT_DIR/bootstrap-host-access.json" "run 01.1 - Host Bootstrap"
fi
if [[ -f "$AUDIT_DIR/security.log" || -f "$LEGACY_AUDIT_DIR/security.log" ]]; then
  res PASS SECURITY_AUDIT "Security audit log present" "$AUDIT_DIR or $LEGACY_AUDIT_DIR"
else
  res FAIL SECURITY_AUDIT "Security audit log missing" "checked=$AUDIT_DIR/security.log or $LEGACY_AUDIT_DIR/security.log" "run 01.1 - Host Bootstrap"
fi
[[ -f /etc/ssh/sshd_config.d/99-platforminit-hardening.conf ]] && [[ -f /etc/sudoers.d/itadmin-platforminit ]] && res PASS FIM_POLICY_FILES "policy-driven FIM target files present" || res FAIL FIM_POLICY_FILES "policy-driven FIM target files missing"

md ""; md "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
cat > "$REPORT_JSON" <<EOFJSON
{
  "generated_at": "$(date -u +%FT%TZ)",
  "host": "$(hostname -f 2>/dev/null || hostname)",
  "profile": "ch01-host-validator-v2",
  "baseline_profile": "$(json_escape "$PLATFORMINIT_BASELINE_PROFILE")",
  "checks": [
$CHECKS_JSON
  ],
  "summary": {"pass": $PASS, "warn": $WARN, "fail": $FAIL}
}
EOFJSON
ln -sfn "$(basename "$REPORT_MD")" "${REPORT_DIR}/validate-host-latest.md"
ln -sfn "$(basename "$REPORT_JSON")" "${REPORT_DIR}/validate-host-latest.json"
EXIT_ON_FAIL="${VALIDATOR_EXIT_ON_FAIL:-1}"
if [[ "$EXIT_ON_FAIL" == "1" ]] && (( FAIL != 0 )); then
  exit 2
fi
