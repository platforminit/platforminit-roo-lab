---
name: platforminit-shell-idempotency
description: Use when implementing Bash scripts, CI shell blocks, SSH remote scripts, or validation tooling.
---


# PlatformInit Shell Idempotency Skill

## Bash baseline

Use:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Prefer helper functions:

```bash
log()  { echo "[$(date -u +%FT%TZ)] [INFO] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [ERROR] $*" >&2; exit 1; }
```

## Idempotency checklist

- Can run twice.
- Detects existing state.
- Does not assume empty directories.
- Does not delete without explicit guard.
- Uses temp files then atomic move for generated outputs.
- Quotes variables.
- Validates env vars.
- Emits actionable errors.

## Dangerous patterns

- `rm -rf "$VAR"` where VAR may be empty.
- `eval`.
- unquoted heredocs with secret variables.
- swallowing failures with `|| true` without explanation.
- command construction from GitHub Actions inputs without validation.
