#!/usr/bin/env bash
set -euo pipefail
STAGING_DIR="${1:-/tmp/platforminit-host-access}"
[[ -d "$STAGING_DIR" ]] || { echo "Missing staging dir: $STAGING_DIR" >&2; exit 1; }
AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"
LEGACY_AUDIT_DIR="/var/lib/platforminit/audit"
install -d -m 755 /usr/local/lib/platforminit /usr/local/sbin "$AUDIT_DIR"
mkdir -p "$(dirname "$LEGACY_AUDIT_DIR")"
if [[ "$AUDIT_DIR" != "$LEGACY_AUDIT_DIR" ]]; then
  rm -rf "$LEGACY_AUDIT_DIR"
  ln -sfn "$AUDIT_DIR" "$LEGACY_AUDIT_DIR"
fi
install -m 0644 "$STAGING_DIR/lib-policy.sh" /usr/local/lib/platforminit/lib-policy.sh
install -m 0755 "$STAGING_DIR/grant-temporary-sudo.sh" /usr/local/sbin/platforminit-grant-sudo
install -m 0755 "$STAGING_DIR/sync-host-access.sh" /usr/local/sbin/platforminit-sync-host-access
cat > /usr/local/lib/platforminit/VERSION <<EOFV
synced_at=$(date -u +%FT%TZ)
source_dir=$STAGING_DIR
EOFV
