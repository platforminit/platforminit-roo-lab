#!/usr/bin/env bash
set -euo pipefail
apt-get update -y
DEBIAN_FRONTEND=noninteractive unattended-upgrade -d || DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
