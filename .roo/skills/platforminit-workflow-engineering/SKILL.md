---
name: platforminit-workflow-engineering
description: Use when editing GitHub Actions, workflow_dispatch inputs, artifacts, environments, or project routing.
---


# PlatformInit GitHub Actions Engineering Skill

## Environment model

Workflow environment names in the copied repo are:

```text
development
n8n
```

Project-scoped secrets should be referenced by name only and never printed.

## Workflow principles

- `workflow_dispatch` inputs must be operator-friendly.
- Defaults must be safe and explicit.
- Artifacts must be useful: JSON/Markdown summaries, not noisy logs only.
- Use GitHub Releases for deployable bundles.
- Use Actions artifacts for diagnostics and validation evidence.
- Avoid hidden coupling to one branch unless intentional.

## Review checklist

- Does the workflow run on the expected environment?
- Does it use `secrets.HCLOUD_TOKEN_DEVELOPMENT` or correct project-scoped token?
- Does it avoid hardcoded host IDs where resolver output should be used?
- Are destructive operations gated by explicit action/input?
- Does it support repeated execution?
- Does it produce evidence when it fails?

## Common failure modes

- `environment: dev` when actual environment is `development`.
- `n8n` workflows accidentally using development token.
- fallback to legacy `INFRA_API_TOKEN`.
- command injection through `${{ inputs.* }}`.
- silent artifact upload of secret-bearing logs.
