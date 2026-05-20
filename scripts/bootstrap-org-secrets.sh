#!/usr/bin/env bash
set -euo pipefail

ORG="${ORG:-platforminit}"
REPO="${REPO:-platforminit-platform}"
REPO_SLUG="${ORG}/${REPO}"
SECRETS_DIR="${SECRETS_DIR:-.local_secrets}"

require_file() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "Missing or empty secret file: $path" >&2
    exit 1
  fi
}

gh auth status >/dev/null

require_file "${SECRETS_DIR}/development_api_key"
require_file "${SECRETS_DIR}/n8n_api_key"
require_file "${SECRETS_DIR}/platforminit_api_key"

gh secret set HCLOUD_TOKEN_DEVELOPMENT \
  --repo "$REPO_SLUG" \
  --body "$(tr -d '\r\n' < "${SECRETS_DIR}/development_api_key")"

gh secret set HCLOUD_TOKEN_N8N \
  --repo "$REPO_SLUG" \
  --body "$(tr -d '\r\n' < "${SECRETS_DIR}/n8n_api_key")"

gh secret set HCLOUD_TOKEN_PLATFORMINIT \
  --repo "$REPO_SLUG" \
  --body "$(tr -d '\r\n' < "${SECRETS_DIR}/platforminit_api_key")"

echo "Uploaded Hetzner project tokens as repo secrets for ${REPO_SLUG}"
