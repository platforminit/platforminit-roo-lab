#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
sudo --preserve-env=CF_API_TOKEN,LETSENCRYPT_EMAIL,DEPLOY_MODE,PUBLIC_IP bash "$ROOT_DIR/scripts/ch03-orchestrator.sh"
