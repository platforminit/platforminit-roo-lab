#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CH01_CODE_ROOT="${CH01_CODE_ROOT:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
CH01_RUNTIME_ROOT="${CH01_RUNTIME_ROOT:-/srv/ch01-runtime}"
REPORT_DIR="${REPORT_DIR:-${CH01_RUNTIME_ROOT}/reports}"
STATE_DIR="${STATE_DIR:-${CH01_RUNTIME_ROOT}/state}"
SECRETS_DIR="${SECRETS_DIR:-${CH01_RUNTIME_ROOT}/secrets}"

STATE="${STATE:-${CH01_CODE_ROOT}/baseline/state-known-good.json}"
KEYS_DEVOPS="${KEYS_DEVOPS:-${SECRETS_DIR}/devops_authorized_keys}"

mkdir -p "${REPORT_DIR}" "${STATE_DIR}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SMOKE_REPORT="${REPORT_DIR}/restore-smoke-${TS}.md"

export DEBIAN_FRONTEND=noninteractive

smoke_pass=0
smoke_warn=0
smoke_fail=0

smoke_md() { printf '%s\n' "$*" >> "${SMOKE_REPORT}"; }
smoke_res() {
  local severity="$1" id="$2" message="$3"
  case "$severity" in
    PASS) smoke_pass=$((smoke_pass+1)) ;;
    WARN) smoke_warn=$((smoke_warn+1)) ;;
    FAIL) smoke_fail=$((smoke_fail+1)) ;;
    *) die "Unknown smoke severity: $severity" ;;
  esac
  smoke_md "${severity} | ${id} | ${message}"
}

log "0) Preflight: install minimal deps (jq needed to parse state)"
apt-get update -y
apt-get install -y ca-certificates curl jq unzip vim ufw git

[ -f "$STATE" ] || die "Missing $STATE (baseline pinned)."
[ -f "$KEYS_DEVOPS" ] || die "Missing $KEYS_DEVOPS"

log "1) Install baseline allowlist (ONLY)"
PKGS="$(jq -r '.packages.baseline_allowlist' "$STATE" | awk 'NF' | tr '\n' ' ' | xargs || true)"
[ -n "${PKGS:-}" ] || PKGS="ca-certificates curl git jq unzip vim ufw"
apt-get install -y $PKGS

log "2) Ensure user devops + sudo"
if ! id devops >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" devops
fi
usermod -aG sudo devops

log "3) Install devops authorized_keys + strict perms"
install -d -m 700 -o devops -g devops /home/devops/.ssh
install -m 600 -o devops -g devops "$KEYS_DEVOPS" /home/devops/.ssh/authorized_keys

log "4) Sudo NOPASSWD for devops"
cat >/etc/sudoers.d/90-devops-nopasswd <<'SUDOEOF'
devops ALL=(ALL) NOPASSWD:ALL
SUDOEOF
chmod 440 /etc/sudoers.d/90-devops-nopasswd
visudo -cf /etc/sudoers.d/90-devops-nopasswd >/dev/null

log "5) SSH hardening via sshd_config.d"
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-ch01-baseline.conf <<'SSHEOF'
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
SSHEOF
systemctl restart ssh || systemctl restart sshd

log "6) UFW baseline"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw --force enable

log "6.5) Normalize Hetzner HC_Volume mount for /srv (idempotent)"
if [ ! -f /etc/fstab.bak.ch01 ]; then
  cp -a /etc/fstab /etc/fstab.bak.ch01
fi

if grep -qE '^/dev/disk/by-id/scsi-0HC_Volume_.*[[:space:]]+/mnt/HC_Volume_' /etc/fstab; then
  sed -i -E 's|^(/dev/disk/by-id/scsi-0HC_Volume_[^ ]+[[:space:]]+/mnt/HC_Volume_[^ ]+.*)|# CH01_DISABLED: \1|' /etc/fstab
fi

HC_DEV="$(ls -1 /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null | head -n1 || true)"
if [ -z "${HC_DEV:-}" ]; then
  HC_DEV="/dev/sda"
fi

HC_UUID="$(blkid -s UUID -o value "$HC_DEV" 2>/dev/null || true)"
BASELINE_UUID="$(jq -r '.storage.fstab' "$STATE" | awk '$2=="/srv" && $1 ~ /^UUID=/{sub(/^UUID=/,"",$1); print $1; exit}' || true)"
TARGET_UUID="${HC_UUID:-${BASELINE_UUID:-}}"

if [ -z "${TARGET_UUID:-}" ]; then
  log "WARN: Could not determine /srv UUID."
else
  sed -i -E '/^[[:space:]]*UUID=[0-9a-fA-F-]+[[:space:]]+\/srv[[:space:]]+/d' /etc/fstab
  echo "UUID=${TARGET_UUID} /srv ext4 defaults,nofail 0 2" >> /etc/fstab
fi

HC_MP="$(awk '$2 ~ "^/mnt/HC_Volume_" {print $2; exit}' /proc/mounts || true)"
if [ -n "${HC_MP:-}" ]; then
  umount "${HC_MP}" || true
fi

log "7) Ensure /srv mount (prefer actual HC volume UUID, fallback baseline UUID)"
mkdir -p /srv
mount -a || true

if ! mountpoint -q /srv; then
  die "/srv mount failed"
fi

log "8) Smoke + report"
: > "${SMOKE_REPORT}"
smoke_md "# CH01 Restore smoke report"
smoke_md "- Generated: $(date -u +%FT%TZ)"
smoke_md "- Host: $(hostname -f 2>/dev/null || hostname)"
smoke_md "- Report: ${SMOKE_REPORT}"
smoke_md ""

os_pretty="$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
smoke_res PASS HOST_OS "OS: ${os_pretty}"

if mountpoint -q /srv; then
  smoke_res PASS SRV_MOUNT "/srv mounted"
else
  smoke_res FAIL SRV_MOUNT "/srv not mounted"
fi

if id devops >/dev/null 2>&1; then
  smoke_res PASS USER_DEVOPS "devops user exists"
else
  smoke_res FAIL USER_DEVOPS "devops user missing"
fi

if su - devops -c 'sudo -n true' >/dev/null 2>&1; then
  smoke_res PASS DEVOPS_NOPASSWD "sudo -n works for devops"
else
  smoke_res FAIL DEVOPS_NOPASSWD "sudo -n failed for devops"
fi

if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
  smoke_res PASS SSH_SERVICE "SSH service active"
else
  smoke_res FAIL SSH_SERVICE "SSH service inactive"
fi

if ufw status 2>/dev/null | head -n1 | grep -qi '^Status: active'; then
  smoke_res PASS UFW_ACTIVE "ufw active"
else
  smoke_res FAIL UFW_ACTIVE "ufw inactive"
fi

smoke_md ""
smoke_md "Summary: PASS=${smoke_pass} WARN=${smoke_warn} FAIL=${smoke_fail}"
ln -sfn "$(basename "${SMOKE_REPORT}")" "${REPORT_DIR}/restore-smoke-latest.md"
log "Smoke report: ${SMOKE_REPORT}"

if (( smoke_fail > 0 )); then
  exit 2
fi

log "DONE"
