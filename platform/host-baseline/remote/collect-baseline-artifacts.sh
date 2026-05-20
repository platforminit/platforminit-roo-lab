#!/usr/bin/env bash
set -euo pipefail
requested_root="${1:-auto}"
if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
layout="${PLATFORMINIT_VOLUME_LAYOUT:-single}"
data_path="${PLATFORMINIT_DATA_PATH:-/srv/data}"
if [[ -z "$requested_root" || "$requested_root" == "auto" ]]; then
  case "$layout" in
    none) runtime_root="/var/lib/platforminit/ch01-runtime"; audit_dir="/var/lib/platforminit/audit" ;;
    single) runtime_root="/srv/platforminit/ch01-runtime"; audit_dir="/srv/platforminit/audit" ;;
    split) runtime_root="${data_path}/platforminit/ch01-runtime"; audit_dir="${data_path}/platforminit/audit" ;;
    *) runtime_root="/var/lib/platforminit/ch01-runtime"; audit_dir="/var/lib/platforminit/audit" ;;
  esac
else
  runtime_root="$requested_root"
  audit_dir="${PLATFORMINIT_AUDIT_DIR:-/var/lib/platforminit/audit}"
fi
rm -rf /tmp/platforminit-baseline-collect
install -d -m 755 /tmp/platforminit-baseline-collect/reports /tmp/platforminit-baseline-collect/audit
if [[ -d "$runtime_root/reports" ]]; then cp -a "$runtime_root/reports/." /tmp/platforminit-baseline-collect/reports/; fi
if [[ -d "$audit_dir" ]]; then cp -a "$audit_dir/." /tmp/platforminit-baseline-collect/audit/; fi
printf '%s\n' "$runtime_root" > /tmp/platforminit-baseline-collect/runtime_root.txt
printf '%s\n' "$audit_dir" > /tmp/platforminit-baseline-collect/audit_dir.txt
