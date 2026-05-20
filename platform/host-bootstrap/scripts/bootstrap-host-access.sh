#!/usr/bin/env bash
set -euo pipefail
AUTOMATION_SSH_PUBLIC_KEY="${AUTOMATION_SSH_PUBLIC_KEY:-}"
if [[ -z "$AUTOMATION_SSH_PUBLIC_KEY" ]]; then
  echo "Missing AUTOMATION_SSH_PUBLIC_KEY" >&2
  exit 1
fi
BOOTSTRAP_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"
LEGACY_AUDIT_DIR="/var/lib/platforminit/audit"
init_audit_dirs(){
  mkdir -p "$BOOTSTRAP_AUDIT_DIR"
  mkdir -p "$(dirname "$LEGACY_AUDIT_DIR")"
  if [[ "$BOOTSTRAP_AUDIT_DIR" != "$LEGACY_AUDIT_DIR" ]]; then
    rm -rf "$LEGACY_AUDIT_DIR"
    ln -sfn "$BOOTSTRAP_AUDIT_DIR" "$LEGACY_AUDIT_DIR"
  fi
}
log(){ echo "[BOOTSTRAP][$(date -u +%FT%TZ)] $*"; }
audit(){
  local audit_file audit_parent
  audit_file="$BOOTSTRAP_AUDIT_DIR/security.log"
  audit_parent="$(dirname "$audit_file")"
  mkdir -p "$audit_parent" 2>/dev/null || true
  if ! printf '{"ts":"%s","event":"%s","status":"%s","detail":"%s"}
' "$(date -u +%FT%TZ)" "$1" "${2:-ok}" "${3:-}" >> "$audit_file" 2>/dev/null; then
    echo "[BOOTSTRAP][$(date -u +%FT%TZ)] WARN audit_write_failed file=${audit_file} event=$1 status=${2:-ok} detail=${3:-}" >&2
  fi
}
create_user(){ local u="$1"; id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"; }
install_key(){ local u="$1"; local h; h="$(getent passwd "$u" | cut -d: -f6)"; install -d -m 700 -o "$u" -g "$u" "$h/.ssh"; printf '%s
' "$AUTOMATION_SSH_PUBLIC_KEY" > "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"; chown -R "$u:$u" "$h/.ssh"; }
load_host_context(){
  if [[ -f /etc/platforminit/host-context.env ]]; then
    # shellcheck disable=SC1091
    source /etc/platforminit/host-context.env
  fi
  PLATFORMINIT_VOLUME_LAYOUT="${PLATFORMINIT_VOLUME_LAYOUT:-single}"
  PLATFORMINIT_SRV_PATH="${PLATFORMINIT_SRV_PATH:-/srv}"
  PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
  PLATFORMINIT_DB_PATH="${PLATFORMINIT_DB_PATH:-/srv/db}"
  PLATFORMINIT_OBSERVABILITY_PATH="${PLATFORMINIT_OBSERVABILITY_PATH:-/srv/observability}"
}
resolve_audit_dir_from_context(){
  case "${PLATFORMINIT_VOLUME_LAYOUT:-single}" in
    none) BOOTSTRAP_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/var/lib/platforminit/audit}" ;;
    single) BOOTSTRAP_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}" ;;
    split) BOOTSTRAP_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-${PLATFORMINIT_DATA_PATH:-/srv/data}/platforminit/audit}" ;;
    *) BOOTSTRAP_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/var/lib/platforminit/audit}" ;;
  esac
}
backup_fstab(){ cp -a /etc/fstab "/etc/fstab.platforminit.$(date -u +%Y%m%dT%H%M%SZ).bak"; }
remove_fstab_mountpoint(){
  local mount_path="$1" tmp
  tmp="$(mktemp)"
  awk -v mp="$mount_path" 'BEGIN{changed=0} /^[[:space:]]*#/ || NF < 2 {print; next} $2 == mp {changed=1; next} {print} END{exit 0}' /etc/fstab > "$tmp"
  if ! cmp -s /etc/fstab "$tmp"; then backup_fstab; cat "$tmp" > /etc/fstab; fi
  rm -f "$tmp"
}
remove_fstab_uuid_conflicts(){
  local uuid="$1" mount_path="$2" tmp
  tmp="$(mktemp)"
  awk -v uuid="UUID=${uuid}" -v mp="$mount_path" '
    /^[[:space:]]*#/ || NF < 2 {print; next}
    $1 == uuid && $2 != mp {next}
    $2 == mp && $1 != uuid {next}
    {print}
  ' /etc/fstab > "$tmp"
  if ! cmp -s /etc/fstab "$tmp"; then backup_fstab; cat "$tmp" > /etc/fstab; fi
  rm -f "$tmp"
}
ensure_no_stale_srv_mount_for_split(){
  [[ "${PLATFORMINIT_VOLUME_LAYOUT:-single}" == "split" ]] || return 0
  if grep -qE $'^[^\t]+\t[^\t]+\t[^\t]+\t/srv$' /etc/platforminit/volume-layout.tsv 2>/dev/null; then
    return 0
  fi
  if mountpoint -q /srv; then
    local src
    src="$(findmnt -n -o SOURCE /srv || true)"
    log "volume_layout=split detected but stale /srv mount exists from ${src}; unmounting before split mount reconciliation"
    audit "stale_srv_mount_detected" "warn" "source=${src} action=unmount_for_split_layout"
    if ! umount /srv; then
      audit "stale_srv_mount_unmount_failed" "fail" "source=${src}"
      echo "FATAL: volume_layout=split but stale /srv is mounted and busy: ${src}" >&2
      echo "Stop workloads using /srv or rebuild from a clean host before applying split volume layout." >&2
      exit 1
    fi
    remove_fstab_mountpoint /srv
  fi
}
mount_volume_by_id(){
  local role="$1" volume_id="$2" mount_path="$3" device="/dev/disk/by-id/scsi-0HC_Volume_${volume_id}" uuid current_source current_uuid
  if [[ ! -e "$device" ]]; then
    echo "FATAL: Volume device missing for ${role}: ${device}" >&2
    audit "volume_mount_probe" "fail" "role=${role} device_missing=${device}"
    exit 1
  fi
  if ! blkid "$device" >/dev/null 2>&1; then mkfs.ext4 -F "$device"; fi
  uuid="$(blkid -s UUID -o value "$device")"
  if mountpoint -q "$mount_path"; then
    current_source="$(findmnt -n -o SOURCE "$mount_path" || true)"
    current_uuid="$(findmnt -n -o UUID "$mount_path" || true)"
    if [[ "$current_uuid" == "$uuid" ]]; then
      log "${mount_path} already mounted with expected volume ${volume_id}"
      remove_fstab_uuid_conflicts "$uuid" "$mount_path"
      grep -qE "^UUID=${uuid}[[:space:]]+${mount_path//\//\/}[[:space:]]+" /etc/fstab || echo "UUID=${uuid} ${mount_path} ext4 defaults,nofail 0 2" >> /etc/fstab
      return 0
    fi
    echo "FATAL: ${mount_path} is already mounted from ${current_source:-unknown}, expected HC volume ${volume_id} UUID=${uuid}" >&2
    audit "volume_mount_conflict" "fail" "role=${role} mount=${mount_path} source=${current_source} expected_uuid=${uuid}"
    exit 1
  fi
  mkdir -p "$mount_path"
  remove_fstab_uuid_conflicts "$uuid" "$mount_path"
  grep -qE "^UUID=${uuid}[[:space:]]+${mount_path//\//\/}[[:space:]]+" /etc/fstab || echo "UUID=${uuid} ${mount_path} ext4 defaults,nofail 0 2" >> /etc/fstab
  mount "$mount_path"
  if ! mountpoint -q "$mount_path"; then
    echo "FATAL: failed to mount ${role} volume ${volume_id} at ${mount_path}" >&2
    audit "volume_mount_failed" "fail" "role=${role} volume_id=${volume_id} mount=${mount_path}"
    exit 1
  fi
  audit "volume_mount_ready" "ok" "role=${role} device=${device} mount=${mount_path} uuid=${uuid}"
}
ensure_layout_mounts_ready(){
  local expected=0 failures=0 role volume_id _name mount_path
  ensure_no_stale_srv_mount_for_split
  while IFS=$'\t' read -r role volume_id _name mount_path; do
    [[ -n "${role:-}" && -n "${volume_id:-}" && -n "${mount_path:-}" ]] || continue
    expected=$((expected+1))
    mount_volume_by_id "$role" "$volume_id" "$mount_path" || failures=$((failures+1))
  done < /etc/platforminit/volume-layout.tsv
  if [[ "$expected" == "0" ]]; then
    echo "FATAL: /etc/platforminit/volume-layout.tsv exists but contains no usable volume rows" >&2
    audit "volume_layout_empty" "fail" "path=/etc/platforminit/volume-layout.tsv"
    exit 1
  fi
  case "${PLATFORMINIT_VOLUME_LAYOUT:-single}" in
    split)
      for required in "${PLATFORMINIT_DATA_PATH}" "${PLATFORMINIT_DB_PATH}" "${PLATFORMINIT_OBSERVABILITY_PATH}"; do
        if ! mountpoint -q "$required"; then
          echo "FATAL: split volume layout requires mounted path: ${required}" >&2
          audit "volume_layout_mount_missing" "fail" "path=${required}"
          failures=$((failures+1))
        fi
      done
      ;;
    single)
      if ! mountpoint -q "${PLATFORMINIT_SRV_PATH}"; then
        echo "FATAL: single volume layout requires mounted path: ${PLATFORMINIT_SRV_PATH}" >&2
        audit "volume_layout_mount_missing" "fail" "path=${PLATFORMINIT_SRV_PATH}"
        failures=$((failures+1))
      fi
      ;;
  esac
  [[ "$failures" == "0" ]] || exit 1
}
ensure_srv_mount(){
  load_host_context
  resolve_audit_dir_from_context
  if [[ -s /etc/platforminit/volume-layout.tsv ]]; then
    ensure_layout_mounts_ready
    init_audit_dirs
    return 0
  fi

  if [[ "${PLATFORMINIT_VOLUME_LAYOUT:-single}" == "none" ]]; then
    log "volume_layout=none selected; skipping Hetzner volume mount reconciliation"
    mkdir -p "${PLATFORMINIT_SRV_PATH:-/srv}" /var/lib/platforminit
    init_audit_dirs
    audit "volume_layout_none" "ok" "root-disk-backed runtime path=${PLATFORMINIT_SRV_PATH:-/srv}"
    return 0
  fi

  if [[ "${PLATFORMINIT_VOLUME_LAYOUT:-single}" == "split" ]]; then
    echo "FATAL: volume_layout=split but /etc/platforminit/volume-layout.tsv is missing or empty" >&2
    echo "01 - Create or Rebuild Host must resolve data/db/observability volume IDs and write the split volume layout before 01.1 Host Bootstrap runs." >&2
    audit "volume_layout_missing" "fail" "layout=split path=/etc/platforminit/volume-layout.tsv"
    exit 1
  fi

  if mountpoint -q /srv; then log "/srv already mounted"; return 0; fi
  local root_source root_parent candidate uuid
  root_source="$(findmnt -n -o SOURCE / || true)"
  root_parent="$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)"
  candidate="$(lsblk -pnro NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" {print $1}' | grep -v "/dev/${root_parent}$" | head -n1 || true)"
  if [[ -z "$candidate" ]]; then log "No extra block device detected for /srv mount"; audit "srv_mount_probe" "warn" "no extra block device detected"; return 0; fi
  if ! blkid "$candidate" >/dev/null 2>&1; then mkfs.ext4 -F "$candidate"; fi
  uuid="$(blkid -s UUID -o value "$candidate")"
  mkdir -p /srv
  grep -qE '^[^#].+[[:space:]]+/srv[[:space:]]+' /etc/fstab || echo "UUID=${uuid} /srv ext4 defaults,nofail 0 2" >> /etc/fstab
  mount /srv
  init_audit_dirs
  audit "srv_mount_ready" "ok" "device=${candidate}"
}
install_helpers(){ install -d -m 755 /usr/local/lib/platforminit /usr/local/sbin "$BOOTSTRAP_AUDIT_DIR"; install -m 644 /tmp/platforminit-lib-policy.sh /usr/local/lib/platforminit/lib-policy.sh; install -m 755 /tmp/platforminit-grant-temporary-sudo.sh /usr/local/sbin/platforminit-grant-sudo; install -m 755 /tmp/platforminit-sync-host-access.sh /usr/local/sbin/platforminit-sync-host-access; }
install_broker_policy(){ cat > /etc/sudoers.d/itadmin-platforminit <<'EOFSUDO'
itadmin ALL=(root) NOPASSWD: /usr/local/sbin/platforminit-grant-sudo *
itadmin ALL=(root) NOPASSWD: /usr/local/sbin/platforminit-sync-host-access *
EOFSUDO
chmod 440 /etc/sudoers.d/itadmin-platforminit
visudo -cf /etc/sudoers.d/itadmin-platforminit >/dev/null; }
remove_standing_sudo(){ rm -f /etc/sudoers.d/devops /etc/sudoers.d/itadmin /etc/sudoers.d/devops-temp /etc/sudoers.d/devops-temporary /etc/sudoers.d/devops-elevation /etc/sudoers.d/itadmin-temporary || true; }
harden_ssh(){ install -d -m 755 /etc/ssh/sshd_config.d; cat > /etc/ssh/sshd_config.d/99-platforminit-hardening.conf <<'EOFSSH'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
LoginGraceTime 20
MaxStartups 50:30:200
EOFSSH
sshd -t
systemctl restart ssh || systemctl restart sshd; }
write_audit_marker(){ cat > "$BOOTSTRAP_AUDIT_DIR/bootstrap-host-access.json" <<EOFJSON
{
  "timestamp": "$(date -u +%FT%TZ)",
  "event": "host_bootstrap_completed",
  "users": ["devops", "itadmin"]
}
EOFJSON
audit "host_bootstrap_completed" "ok" "users=devops,itadmin"; }
main(){ load_host_context; resolve_audit_dir_from_context; init_audit_dirs; ensure_srv_mount; init_audit_dirs; create_user devops; create_user itadmin; install_key devops; install_key itadmin; usermod -aG sudo devops; usermod -aG sudo itadmin; install_helpers; install_broker_policy; remove_standing_sudo; harden_ssh; write_audit_marker; }
main "$@"
