#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="${CH01_RUNTIME_ROOT:-/srv/ch01-runtime}"
AUTHORIZED_KEYS_FILE="${AUTHORIZED_KEYS_FILE:-$RUNTIME_ROOT/secrets/authorized_keys}"

resolve_existing_file() {
  local explicit="${1:-}"
  shift || true
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    printf '%s
' "$explicit"
    return 0
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      printf '%s
' "$candidate"
      return 0
    fi
  done
  return 1
}

POLICY_FILE="$(resolve_existing_file "${POLICY_FILE:-}"   "$SCRIPT_DIR/baseline.yaml"   "$SCRIPT_DIR/../policy/baseline.yaml")" || {
  echo "Missing baseline.yaml" >&2
  exit 1
}
DEPENDENCY_FILE="$(resolve_existing_file "${DEPENDENCY_FILE:-}"   "$SCRIPT_DIR/dependencies.yaml"   "$SCRIPT_DIR/../policy/dependencies.yaml")" || {
  echo "Missing dependencies.yaml" >&2
  exit 1
}
LIB_POLICY_FILE="$(resolve_existing_file "${PLATFORMINIT_LIB_POLICY:-}"   "$SCRIPT_DIR/lib-policy.sh"   "/usr/local/lib/platforminit/lib-policy.sh")" || {
  echo "Missing lib-policy.sh" >&2
  exit 1
}
source "$LIB_POLICY_FILE"

export POLICY_FILE DEPENDENCY_FILE PLATFORMINIT_LIB_POLICY="$LIB_POLICY_FILE"

mkdir -p "$RUNTIME_ROOT" "$RUNTIME_ROOT/reports" "$RUNTIME_ROOT/state" "$RUNTIME_ROOT/work" "$RUNTIME_ROOT/secrets" "$PLATFORMINIT_AUDIT_DIR"
"$SCRIPT_DIR/install-dependencies.sh"
command -v yq >/dev/null 2>&1 || { echo "Missing yq after dependency install" >&2; exit 1; }

mapfile -t packages < <(yq -r '.packages.common[] , .packages.security[]' "$POLICY_FILE")
baseline_event "packages_declared" "ok" "$(printf '%s ' "${packages[@]}")"

while IFS= read -r user; do
  [[ -n "$user" ]] || continue
  shell="$(yq -r ".users.${user}.shell" "$POLICY_FILE")"
  id "$user" >/dev/null 2>&1 || useradd -m -s "$shell" "$user"
  while IFS= read -r group; do
    [[ -n "$group" ]] && usermod -aG "$group" "$user"
  done < <(yq -r ".users.${user}.groups[]?" "$POLICY_FILE")
  install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
  if [[ -f "$AUTHORIZED_KEYS_FILE" ]]; then
    install -m 600 -o "$user" -g "$user" "$AUTHORIZED_KEYS_FILE" "/home/$user/.ssh/authorized_keys"
  fi
  baseline_event "user_policy" "ok" "$user:grant_only"
done < <(yq -r '.users | keys[]' "$POLICY_FILE")

rm -f /etc/sudoers.d/devops /etc/sudoers.d/devops-temp /etc/sudoers.d/devops-temporary /etc/sudoers.d/devops-elevation /etc/sudoers.d/itadmin-temporary || true

cat >/etc/ssh/sshd_config.d/99-platforminit-hardening.conf <<EOFSSH
PasswordAuthentication $(yq -r '.ssh.password_authentication' "$POLICY_FILE")
PermitRootLogin $(yq -r '.ssh.permit_root_login' "$POLICY_FILE")
PubkeyAuthentication $(yq -r '.ssh.pubkey_authentication' "$POLICY_FILE")
MaxAuthTries $(yq -r '.ssh.max_auth_tries' "$POLICY_FILE")
X11Forwarding $(yq -r '.ssh.x11_forwarding' "$POLICY_FILE")
AuthorizedKeysFile .ssh/authorized_keys
LoginGraceTime $(yq -r '.ssh.login_grace_time // 20' "$POLICY_FILE")
MaxStartups $(yq -r '.ssh.max_startups // "50:30:200"' "$POLICY_FILE")
EOFSSH
install -d -m 755 /run/sshd
sshd -t
systemctl restart ssh || systemctl restart sshd
baseline_event "ssh_hardening" "ok" "root disabled, password auth disabled, MaxStartups tuned"

ufw --force reset
ufw default "$(yq -r '.firewall.default_incoming' "$POLICY_FILE")" incoming
ufw default "$(yq -r '.firewall.default_outgoing' "$POLICY_FILE")" outgoing
while IFS= read -r port; do
  [[ -n "$port" ]] && ufw allow "${port}/tcp"
done < <(yq -r '.firewall.allow_tcp[]' "$POLICY_FILE")
ufw --force enable
baseline_event "ufw_policy" "ok"

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOFAUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOFAUTO
baseline_event "unattended_upgrades" "ok"

FIM_REPORT="$RUNTIME_ROOT/reports/fim-baseline-$(date -u +%Y%m%dT%H%M%SZ).txt"
if "$SCRIPT_DIR/fim-check.sh" "$FIM_REPORT"; then
  baseline_event "fim_policy_check" "ok" "$FIM_REPORT"
else
  baseline_event "fim_policy_check" "fail" "$FIM_REPORT"
  echo "Policy-driven FIM check failed" >&2
  exit 1
fi

cat > "$RUNTIME_ROOT/state/policy-state.json" <<EOFSTATE
{
  "applied_at": "$(date -u +%FT%TZ)",
  "policy_file": "$POLICY_FILE",
  "dependency_file": "$DEPENDENCY_FILE",
  "runtime_root": "$RUNTIME_ROOT"
}
EOFSTATE

audit_event "policy_baseline_applied" "ok" "runtime_root=$RUNTIME_ROOT"
