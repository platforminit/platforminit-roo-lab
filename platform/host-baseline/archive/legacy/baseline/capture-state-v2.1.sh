#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/srv/ch01/baseline}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT_DIR}/state-${TS}.json"

mkdir -p "$OUT_DIR"

FSTAB="$(cat /etc/fstab)"
FSTAB_SRV_UUID="$(awk '$2=="/srv" && $1 ~ /^UUID=/{sub(/^UUID=/,"",$1); print $1; exit}' /etc/fstab || true)"
MOUNTS="$(findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS --json 2>/dev/null || true)"

BASELINE_PKGS="$(cat <<'PKGEOF'
ca-certificates
curl
git
jq
unzip
vim
ufw
PKGEOF
)"

SSHD_T="$(sshd -T 2>/dev/null || true)"
SSHD_SUB="$(echo "$SSHD_T" | egrep '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|usepam|allowtcpforwarding|clientaliveinterval|clientalivecountmax)\b' || true)"
UFW_STATUS="$(ufw status verbose 2>/dev/null || true)"

HOSTNAME_F="$(hostname -f 2>/dev/null || hostname)"
IP_BR="$(ip -br a 2>/dev/null || true)"
LSBLK="$(lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,UUID 2>/dev/null || true)"
KERNEL="$(uname -r)"

jq -n \
  --arg ts "$TS" \
  --arg hostname "$HOSTNAME_F" \
  --arg ip_br "$IP_BR" \
  --arg lsblk "$LSBLK" \
  --arg kernel "$KERNEL" \
  --arg fstab "$FSTAB" \
  --arg fstab_srv_uuid "$FSTAB_SRV_UUID" \
  --argjson mounts "${MOUNTS:-null}" \
  --arg pkgs_baseline "$BASELINE_PKGS" \
  --arg sshd_subset "$SSHD_SUB" \
  --arg ufw_status "$UFW_STATUS" \
'{
  schema_version: "ch01-state-2",
  captured_at_utc: $ts,
  host: { hostname_fqdn: $hostname, ip_brief: $ip_br, kernel: $kernel, lsblk: $lsblk },
  storage: { fstab: $fstab, mounts: $mounts, srv_uuid_from_fstab: $fstab_srv_uuid },
  packages: { baseline_allowlist: $pkgs_baseline },
  security: { sshd_effective_subset: $sshd_subset, ufw: $ufw_status }
}' > "$OUT"

ln -sf "$(basename "$OUT")" "${OUT_DIR}/state-current.json"
echo "Wrote: $OUT"
echo "Current: ${OUT_DIR}/state-current.json"
