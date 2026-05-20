#!/usr/bin/env bash
set -euo pipefail
report="${1:-/tmp/platforminit-os-security-check.txt}"
apt-get update -y >/dev/null 2>&1
apt list --upgradable 2>/dev/null | awk '/security/ {print}' | tee "$report" || true
