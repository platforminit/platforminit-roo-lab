#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${REPORT_DIR:-/srv/ch02/reports}"
REPORT="${REPORT:-$REPORT_DIR/validate-$(date -u +%Y%m%dT%H%M%SZ).md}"

mkdir -p "$REPORT_DIR"

PASS=0
WARN=0
FAIL=0

md(){ printf '%s\n' "$*" | tee -a "$REPORT" >/dev/null; }

hr(){
  md ""
  md "$1"
}

res(){
  local lvl="$1"
  shift
  local msg="$*"

  case "$lvl" in
    PASS) PASS=$((PASS+1));;
    WARN) WARN=$((WARN+1));;
    FAIL) FAIL=$((FAIL+1));;
  esac

  md "$lvl | $msg"
}

cmd_ok(){ command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# helpers
# ----------------------------

get_public_ipv4(){
  local ip

  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"

  if [[ -n "${ip:-}" ]]; then
      printf '%s\n' "$ip"
      return
  fi

  if cmd_ok curl; then
      curl -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true
  fi
}

# robust k3s data-dir detect
k3s_data_dir(){

  local dd=""

  # 1) config.yaml
  if [[ -f /etc/rancher/k3s/config.yaml ]]; then
      dd="$(awk -F': *' '$1=="data-dir"{print $2; exit}' /etc/rancher/k3s/config.yaml 2>/dev/null || true)"
  fi

  # 2) systemd fallback
  if [[ -z "${dd:-}" ]]; then
      dd="$(systemctl show -p ExecStart k3s 2>/dev/null | sed -n 's/.*--data-dir[= ]\([^ ]*\).*/\1/p' || true)"
  fi

  # 3) default
  [[ -n "${dd:-}" ]] || dd="/srv/data/k3s"

  printf '%s\n' "$dd"
}

# ----------------------------
# start report
# ----------------------------

: >"$REPORT"

md "# Host validation report"
md "- Generated: $(date -u +%FT%TZ)"
md "- Host: $(hostname -f 2>/dev/null || hostname)"
md "- Report: $REPORT"

# ----------------------------
# Host basics
# ----------------------------

hr "## Host basics"

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  [[ "${NAME:-}" == "Ubuntu"* ]] \
      && res PASS "OS: ${PRETTY_NAME:-unknown}" \
      || res WARN "OS: ${PRETTY_NAME:-unknown}"
else
  res WARN "OS release file missing"
fi

if systemctl is-active --quiet systemd-timesyncd 2>/dev/null \
   || systemctl is-active --quiet chrony 2>/dev/null; then
  res PASS "Time synchronization active"
else
  res WARN "Time synchronization NOT active"
fi

# ----------------------------
# /srv volume (layout-aware)
# ----------------------------

hr "## /srv volume"

# Resolve volume layout from host context if available
if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
PLATFORMINIT_VOLUME_LAYOUT="${PLATFORMINIT_VOLUME_LAYOUT:-single}"

case "$PLATFORMINIT_VOLUME_LAYOUT" in
  none)
    # Root-disk-only host: /srv is a directory, not a mountpoint
    if [[ -d /srv ]]; then
      res PASS "/srv exists (volume_layout=none)"
    else
      res FAIL "/srv missing (volume_layout=none)"
    fi
    # Verify no unexpected Hetzner volume is mounted under /srv
    unexpected_mounts="$(findmnt -n -o TARGET /srv 2>/dev/null || true)"
    if [[ -z "$unexpected_mounts" ]]; then
      res PASS "/srv is not a mountpoint (expected for volume_layout=none)"
    else
      res WARN "/srv is unexpectedly a mountpoint for volume_layout=none: $unexpected_mounts"
    fi
    ;;
  single)
    if mountpoint -q /srv; then
      res PASS "/srv is mountpoint (volume_layout=single)"
    else
      res FAIL "/srv is NOT mountpoint (volume_layout=single)"
    fi
    srv_src="$(findmnt -n -o SOURCE /srv 2>/dev/null || true)"
    if [[ -n "${srv_src:-}" ]]; then
      res PASS "/srv source: $srv_src"
    else
      res WARN "Cannot determine /srv source"
    fi
    grep -Eq '^[^#].*[[:space:]]/srv[[:space:]]' /etc/fstab \
        && res PASS "/srv entry present in fstab" \
        || res FAIL "/srv entry missing in fstab"
    ;;
  split)
    # Split layout: /srv itself should NOT be a mountpoint
    if mountpoint -q /srv; then
      res WARN "/srv is a mountpoint but volume_layout=split expects subdirectory mounts"
    else
      res PASS "/srv is not a mountpoint (volume_layout=split)"
    fi
    for sub in /srv/data /srv/db /srv/observability; do
      if mountpoint -q "$sub"; then
        res PASS "${sub} is mountpoint (volume_layout=split)"
      else
        res FAIL "${sub} is NOT mountpoint (volume_layout=split)"
      fi
    done
    ;;
  *)
    res WARN "Unknown volume_layout: $PLATFORMINIT_VOLUME_LAYOUT"
    if mountpoint -q /srv; then
      res PASS "/srv is mountpoint (unknown layout)"
    else
      res FAIL "/srv is NOT mountpoint"
    fi
    ;;
esac

# ----------------------------
# SSH
# ----------------------------

hr "## SSH"

id devops >/dev/null 2>&1 \
  && res PASS "devops user exists" \
  || res FAIL "devops user missing"

if systemctl is-active --quiet ssh 2>/dev/null \
   || systemctl is-active --quiet sshd 2>/dev/null; then
  res PASS "sshd service active"
else
  res FAIL "sshd service NOT active"
fi

sshd_cfg="$(sshd -T 2>/dev/null || true)"

if [[ -n "$sshd_cfg" ]]; then

  echo "$sshd_cfg" | grep -q '^permitrootlogin no$' \
      && res PASS "PermitRootLogin no" \
      || res WARN "PermitRootLogin not disabled"

  echo "$sshd_cfg" | grep -q '^passwordauthentication no$' \
      && res PASS "PasswordAuthentication no" \
      || res WARN "PasswordAuthentication not disabled"

  echo "$sshd_cfg" | grep -q '^pubkeyauthentication yes$' \
      && res PASS "PubkeyAuthentication yes" \
      || res WARN "PubkeyAuthentication not enabled"

else
  res WARN "Cannot read sshd config"
fi

# ----------------------------
# Firewall
# ----------------------------

hr "## Firewall"

if cmd_ok ufw; then
  if ufw status | head -n1 | grep -qi active; then
      res PASS "ufw active"
  else
      res WARN "ufw not active"
  fi
else
  res WARN "ufw not installed"
fi

# ----------------------------
# k3s core
# ----------------------------

hr "## k3s"

systemctl is-active --quiet k3s \
  && res PASS "k3s service active" \
  || res FAIL "k3s service NOT active"

dd="$(k3s_data_dir)"

if [[ -d "$dd" ]]; then
  res PASS "k3s data-dir: $dd"
else
  res WARN "k3s data-dir not found: $dd"
fi

# Legacy /srv/k3s and /var/lib/rancher/k3s are not valid target paths for PlatformInit.
# k3s_data_dir() validates the configured layout-aware data-dir.

# ----------------------------
# kubectl
# ----------------------------

if cmd_ok kubectl; then
  if kubectl get nodes >/dev/null 2>&1; then
      res PASS "kubectl can access cluster"
  else
      res FAIL "kubectl cannot access cluster"
  fi
else
  res FAIL "kubectl not installed"
fi

# ----------------------------
# Host ports (Traefik truth)
# ----------------------------

hr "## Host ports"

if cmd_ok kubectl && kubectl -n kube-system get svc traefik >/dev/null 2>&1; then

  T_TYPE="$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.type}')"
  T_PORTS="$(kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}')"

  if echo " $T_PORTS " | grep -q " 80 " && echo " $T_PORTS " | grep -q " 443 "; then
      res PASS "Ingress ports 80/443 via traefik svc ($T_TYPE)"
  else
      res WARN "traefik svc present but ports not 80/443: $T_PORTS"
  fi

else

  if ss -lnt 2>/dev/null | grep -qE ':(80|443)'; then
      ss -lnt | grep -q ':80' \
          && res PASS "port 80 listening" \
          || res WARN "port 80 not detected"

      ss -lnt | grep -q ':443' \
          && res PASS "port 443 listening" \
          || res WARN "port 443 not detected"
  else
      res WARN "ports 80/443 not visible (k8s/iptables/LB may be used)"
  fi

fi

# ----------------------------
# DNS
# ----------------------------

hr "## DNS"

hostname_dns="k3s.sysadminhomelab.hu"

dns_ip="$(getent ahostsv4 "$hostname_dns" 2>/dev/null | awk '{print $1; exit}' || true)"
pub_ip="$(get_public_ipv4)"

if [[ -n "${dns_ip:-}" ]]; then

  res PASS "DNS A record: $dns_ip"

  if [[ -n "${pub_ip:-}" && "$dns_ip" == "$pub_ip" ]]; then
      res PASS "DNS matches public IP"
  else
      res WARN "DNS does not match public IP"
  fi

else
  res WARN "DNS resolution failed"
fi

# ----------------------------
# Summary
# ----------------------------

hr "## Summary"

md ""
md "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
md "Report: $REPORT"

[[ $FAIL -eq 0 ]]
