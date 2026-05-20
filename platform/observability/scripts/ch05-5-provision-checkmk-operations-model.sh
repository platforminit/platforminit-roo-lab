#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
export KUBECONFIG
[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -n "$BASE_DOMAIN" ]] || die "BASE_DOMAIN is required for PlatformInit Checkmk service checks"

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

HOST_IPV4="${HOST_IPV4:-$(hostname -I | awk '{print $1}') }"
HOST_IPV4="${HOST_IPV4%% }"
[[ -n "$HOST_IPV4" ]] || HOST_IPV4="127.0.0.1"

log "Provisioning visible PlatformInit Checkmk host/service model in pod/${POD} host=${PLATFORM_HOST} host_ipv4=${HOST_IPV4} base_domain=${BASE_DOMAIN}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$HOST_IPV4" "$BASE_DOMAIN" <<'CHECKMK_MODEL'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
HOST_IPV4="$3"
BASE_DOMAIN="$4"
SITE_ROOT="/omd/sites/${SITE}"

omd status "$SITE" >/dev/null

mkdir -p \
  "${SITE_ROOT}/local/lib/nagios/plugins" \
  "${SITE_ROOT}/local/share/platforminit" \
  "${SITE_ROOT}/etc/check_mk/conf.d/platforminit"

cat > "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service" <<'PYPLUGIN'
#!/usr/bin/env python3
import argparse
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request


def emit(code: int, state: str, service: str, detail: str, perfdata: str = "") -> int:
    # The CH05.5 synthetic checks are intentionally state-only. Earlier builds
    # emitted ad-hoc Nagios perfdata (for example time=0.016s). Checkmk Raw can
    # show these in the service detail page but does not have a stable graph
    # recipe for the custom metrics, which resulted in browser-visible
    # "Loading graph failed: 'graph_recipe'" errors. Real time-series graphs
    # belong to CH05.7 after the native Checkmk Linux agent is installed.
    print(f"{state} - {service}: {detail}")
    return code


def check_tcp(args) -> int:
    start = time.time()
    try:
        with socket.create_connection((args.host, args.port), timeout=args.timeout):
            elapsed = time.time() - start
        return emit(0, "OK", args.service, f"TCP {args.host}:{args.port} reachable in {elapsed:.3f}s")
    except Exception as exc:
        return emit(2, "CRITICAL", args.service, f"TCP {args.host}:{args.port} failed: {exc}")


def check_http(args) -> int:
    codes = {int(x.strip()) for x in args.ok_codes.split(',') if x.strip()}
    req = urllib.request.Request(args.url, method="GET", headers={"User-Agent": "PlatformInit-Checkmk/1.0"})
    ctx = ssl._create_unverified_context()
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=args.timeout, context=ctx) as resp:
            code = resp.getcode()
            elapsed = time.time() - start
    except urllib.error.HTTPError as exc:
        code = exc.code
        elapsed = time.time() - start
    except Exception as exc:
        return emit(2, "CRITICAL", args.service, f"HTTP check failed for {args.url}: {exc}")
    if code in codes:
        return emit(0, "OK", args.service, f"HTTP {code} from {args.url} in {elapsed:.3f}s")
    return emit(2, "CRITICAL", args.service, f"Unexpected HTTP {code} from {args.url}")


def check_path_usage(args) -> int:
    path = args.path
    if not os.path.exists(path):
        return emit(2, "CRITICAL", args.service, f"Path does not exist: {path}")
    try:
        st = os.statvfs(path)
        total = st.f_blocks * st.f_frsize
        available = st.f_bavail * st.f_frsize
        used = total - available
        used_pct = (used / total * 100.0) if total else 0.0
    except Exception as exc:
        return emit(2, "CRITICAL", args.service, f"Could not stat {path}: {exc}")
    state = "OK"
    code = 0
    if used_pct >= args.crit:
        state, code = "CRITICAL", 2
    elif used_pct >= args.warn:
        state, code = "WARNING", 1
    detail = f"{path} usage is {used_pct:.2f}% ({used // (1024**2)} MiB used of {total // (1024**2)} MiB)"
    return emit(code, state, args.service, detail)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["ok", "tcp", "http", "path-usage"], required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--detail", default="PlatformInit synthetic service check is active")
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--url")
    parser.add_argument("--path")
    parser.add_argument("--warn", type=float, default=80.0)
    parser.add_argument("--crit", type=float, default=90.0)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--ok-codes", default="200,301,302,401,403")
    args = parser.parse_args()

    if args.mode == "ok":
        return emit(0, "OK", args.service, args.detail)
    if args.mode == "tcp":
        if not args.host or not args.port:
            return emit(3, "UNKNOWN", args.service, "tcp mode requires --host and --port")
        return check_tcp(args)
    if args.mode == "http":
        if not args.url:
            return emit(3, "UNKNOWN", args.service, "http mode requires --url")
        return check_http(args)
    if args.mode == "path-usage":
        if not args.path:
            return emit(3, "UNKNOWN", args.service, "path-usage mode requires --path")
        return check_path_usage(args)
    return emit(3, "UNKNOWN", args.service, "unsupported mode")


if __name__ == "__main__":
    sys.exit(main())
PYPLUGIN
chmod 0755 "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"
chown "${SITE}:${SITE}" "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"

# Stop-loss recovery: remove the failed CH05.7 experimental overlay before
# returning to the last known-good CH05.5 state-only synthetic model.
rm -f -- "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/zz_platforminit_agent_address.mk"

cat > "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_hosts.mk" <<PLATFORMINIT_MK
# Managed by PlatformInit CH05.5.
# This file intentionally defines a small, operator-first Checkmk model.

globals().setdefault("all_hosts", [])
globals().setdefault("ipaddresses", {})
globals().setdefault("define_hostgroups", {})
globals().setdefault("host_groups", [])
globals().setdefault("custom_checks", [])

# Keep the Checkmk host in a normal pull-agent model. The raw tcp tag is
# required in Checkmk 2.x/2.5 so cmk -D exposes a TCP agent target.
# Without it the host can remain in a no-agent/piggyback-only state even when
# the default agent tag is cmk-agent.
all_hosts += [
    "${PLATFORM_HOST}|cmk-agent|tcp|prod|lan",
]

ipaddresses.update({
    "${PLATFORM_HOST}": "${HOST_IPV4}",
})

define_hostgroups.update({
    "platforminit_hosts": "PlatformInit / Hosts",
    "platforminit_kubernetes": "PlatformInit / Kubernetes",
    "platforminit_operations": "PlatformInit / Operations",
    "platforminit_storage": "PlatformInit / Storage",
})

custom_checks = [
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000001",
        "value": {
            "command_name": "platforminit-host-availability",
            "service_description": "Host availability",
            "command_line": "\$USER2\$/platforminit_check_service --mode ok --service 'Host availability' --detail 'PlatformInit Checkmk host object is active'",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Host availability",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000002",
        "value": {
            "command_name": "platforminit-ssh",
            "service_description": "SSH",
            "command_line": "\$USER2\$/platforminit_check_service --mode tcp --service 'SSH' --host ${HOST_IPV4} --port 22",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: SSH",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000003",
        "value": {
            "command_name": "platforminit-kubernetes-api",
            "service_description": "Kubernetes API",
            "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Kubernetes API' --url https://kubernetes.default.svc/healthz --ok-codes 200,401,403",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Kubernetes API",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000004",
        "value": {
            "command_name": "platforminit-checkmk-webui",
            "service_description": "Checkmk WebUI",
            "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Checkmk WebUI' --url http://127.0.0.1:5000/${SITE}/ --ok-codes 200,301,302,401,403",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Checkmk WebUI",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000005",
        "value": {
            "command_name": "platforminit-argocd-webui",
            "service_description": "Argo CD WebUI",
            "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Argo CD WebUI' --url https://argocd.${BASE_DOMAIN}/ --ok-codes 200,301,302,401,403",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Argo CD WebUI",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000006",
        "value": {
            "command_name": "platforminit-authentik-webui",
            "service_description": "Authentik WebUI",
            "command_line": "\$USER2\$/platforminit_check_service --mode http --service 'Authentik WebUI' --url https://auth.${BASE_DOMAIN}/ --ok-codes 200,301,302,401,403",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Authentik WebUI",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000007",
        "value": {
            "command_name": "platforminit-root-filesystem",
            "service_description": "Root filesystem",
            "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Root filesystem' --path /platforminit-host/root --warn 80 --crit 90",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Root filesystem",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000008",
        "value": {
            "command_name": "platforminit-k3s-runtime-storage",
            "service_description": "Kubernetes runtime storage",
            "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Kubernetes runtime storage' --path /platforminit-host/srv-data-k3s --warn 80 --crit 90",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Kubernetes runtime storage",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000009",
        "value": {
            "command_name": "platforminit-k3s-pvc-storage",
            "service_description": "Kubernetes PVC storage",
            "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Kubernetes PVC storage' --path /platforminit-host/srv-data-k3s-storage --warn 80 --crit 90",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Kubernetes PVC storage",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000010",
        "value": {
            "command_name": "platforminit-checkmk-storage",
            "service_description": "Checkmk storage",
            "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Checkmk storage' --path /platforminit-host/srv-observability-data --warn 80 --crit 90",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Checkmk storage",
        },
    },
    {
        "id": "b1d7a4d2-3f20-4d8e-9c1a-000000000011",
        "value": {
            "command_name": "platforminit-platform-runtime-artifacts",
            "service_description": "Platform runtime artifacts",
            "command_line": "\$USER2\$/platforminit_check_service --mode path-usage --service 'Platform runtime artifacts' --path /platforminit-host/srv-platforminit --warn 80 --crit 90",
            "has_perfdata": False,
        },
        "condition": {"host_name": ["${PLATFORM_HOST}"]},
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05 managed service: Platform runtime artifacts",
        },
    }
] + custom_checks
PLATFORMINIT_MK
chown -R "${SITE}:${SITE}" "${SITE_ROOT}/etc/check_mk/conf.d/platforminit" "${SITE_ROOT}/local/share/platforminit"

# CH05.5 synthetic checks are state-only by design. Earlier iterations
# installed experimental Graphing API definitions and emitted ad-hoc/custom
# perfdata. That made Checkmk render broken graph panels with browser-visible
# "Loading graph failed: 'graph_recipe'" errors. Remove the experimental graph
# plugin and all host/user-scoped graph caches. Real time-series graphs belong
# to CH05.7 after native Checkmk agent installation and service discovery.
rm -rf -- "${SITE_ROOT}/local/lib/python3/cmk_addons/plugins/platforminit_synthetic"

for graph_dir in \
  "${SITE_ROOT}/var/check_mk/rrd/${PLATFORM_HOST}" \
  "${SITE_ROOT}/var/pnp4nagios/perfdata/${PLATFORM_HOST}" \
  "${SITE_ROOT}/var/check_mk/graphing/${PLATFORM_HOST}" \
  "${SITE_ROOT}/tmp/check_mk/graphing/${PLATFORM_HOST}"
do
  if [[ -e "${graph_dir}" ]]; then
    rm -rf -- "${graph_dir}"
  fi
done

if [[ -d "${SITE_ROOT}/var/check_mk/web" ]]; then
  find "${SITE_ROOT}/var/check_mk/web" -type d \
    \( -name 'cached_graph_images' -o -name 'graph_cache' \) \
    -prune -exec rm -rf -- {} + 2>/dev/null || true
fi
if [[ -d "${SITE_ROOT}/tmp/check_mk" ]]; then
  find "${SITE_ROOT}/tmp/check_mk" -type d -name 'graphing' \
    -prune -exec rm -rf -- {} + 2>/dev/null || true
fi

cat > "${SITE_ROOT}/local/share/platforminit/README.txt" <<PLATFORMINIT_README
PlatformInit CH05 Checkmk layer

Provisioned host:
- ${PLATFORM_HOST}

Provisioned services:
- Host availability
- SSH
- Kubernetes API
- Checkmk WebUI
- Argo CD WebUI
- Authentik WebUI
- Root filesystem
- Kubernetes runtime storage
- Kubernetes PVC storage
- Checkmk storage
- Platform runtime artifacts
PLATFORMINIT_README
chown "${SITE}:${SITE}" "${SITE_ROOT}/local/share/platforminit/README.txt"

su - "${SITE}" -c "cmk -R"
su - "${SITE}" -c "omd restart apache" >/dev/null || true

# Force one fresh result pass after switching synthetic services to state-only
# output. Additionally submit a passive state-only result first. This overwrites
# stale live-status perf_data fields immediately; scheduling alone can leave old
# perfdata visible long enough for Checkmk to keep rendering broken graph panes.
now="$(date +%s)"
cmd_pipe="${SITE_ROOT}/tmp/run/nagios.cmd"
platforminit_services=(
  "Host availability"
  "SSH"
  "Kubernetes API"
  "Checkmk WebUI"
  "Argo CD WebUI"
  "Authentik WebUI"
  "Root filesystem"
  "Kubernetes runtime storage"
  "Kubernetes PVC storage"
  "Checkmk storage"
  "Platform runtime artifacts"
)
if [[ -p "${cmd_pipe}" ]]; then
  for svc in "${platforminit_services[@]}"; do
    timeout 3s bash -c 'printf "[%s] PROCESS_SERVICE_CHECK_RESULT;%s;%s;0;OK - %s: PlatformInit state-only synthetic check reset\n" "$1" "$2" "$3" "$3" > "$4"' \
      _ "${now}" "${PLATFORM_HOST}" "${svc}" "${cmd_pipe}" || true
    timeout 3s bash -c 'printf "[%s] SCHEDULE_FORCED_SVC_CHECK;%s;%s;%s\n" "$1" "$2" "$3" "$1" > "$4"' \
      _ "${now}" "${PLATFORM_HOST}" "${svc}" "${cmd_pipe}" || true
  done
  sleep 10
fi

# Do not pipe Checkmk Python commands into grep -q. In Checkmk 2.x, cmk output
# can raise BrokenPipeError and exit with rc=120 when the downstream grep closes
# early after a match. Capture output first, then grep the stable files.
MODEL_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "${MODEL_CHECK_DIR}"' EXIT

su - "${SITE}" -c "cmk -l" > "${MODEL_CHECK_DIR}/hosts.txt"
su - "${SITE}" -c "cmk -N" > "${MODEL_CHECK_DIR}/nagios.cfg"

grep -Fx "${PLATFORM_HOST}" "${MODEL_CHECK_DIR}/hosts.txt" >/dev/null
grep -q "host_name[[:space:]]\+${PLATFORM_HOST}" "${MODEL_CHECK_DIR}/nagios.cfg"
grep -q "service_description[[:space:]]\+SSH" "${MODEL_CHECK_DIR}/nagios.cfg"
CHECKMK_MODEL

log "Checkmk operations model provisioned and core configuration reloaded"
