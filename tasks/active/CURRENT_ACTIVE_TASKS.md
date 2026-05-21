# Current Active Tasks

This file is the active task source for PlatformInit Roo Lab.

## Active repository

- Repository: `platforminit-roo-lab`
- Primary branch: `dev`
- Current work branch: `batch/roo-lab-first-validation`
- Target role: full-access dev workflow rehearsal repository
- Disposable target host: `platforminit-dev-01`
- Stable recovery source: `platforminit-platform`

## Active work package

### B00 - Clean PlatformInit Agent Operating Layer

Goal: prepare Roo Code custom modes, project skills, current context, branch rules, review rules, and recovery rules before allowing any infrastructure workflow rehearsal.

Active tasks:

1. Validate `.roomodes` custom modes.
2. Validate `.roo/rules.md` and mode-specific rules.
3. Validate project skills under `.roo/skills/*/SKILL.md`.
4. Validate clean active context files.
5. Validate GitHub workflow environment bindings for `development` and `n8n`.
6. Validate organization secret names are visible to the repository.
7. Validate WSL runtime guard.
8. Validate current branch is `batch/roo-lab-first-validation` before Roo work.
9. Validate no production/customer scope is targeted.
10. Prepare review handoff after agent-layer validation.

## Current active architectural direction

- CH01-CH05 remain the foundation layers.
- CH05 current direction is Checkmk Community with Authentik/Traefik trusted-header SSO.
- CH06 next direction is security and compliance diagnostics first, not destructive remediation.
- n8n direction is standalone host/runtime, separate from the main k3s platform path.
- PlatformInit remains single-node, cost-conscious, deterministic rebuild first.

## Deprecated context handling

Deprecated components and superseded experiments must not appear as active tasks in this file.

Historical or superseded directions are documented only under:

- `docs/roo-lab/context/DEPRECATED_COMPONENTS.md`
- `docs/roo-lab/context/ChatGPTMemory.curated-20260520.json`
- `docs/roo-lab/context/CHATGPT_MEMORY_BASELINE.md`

Agents must not resurrect deprecated work from archived memory unless explicitly instructed by the human operator.

## First Roo execution rule

The first Roo execution cycle must validate the agent operating layer only.

Do not trigger infrastructure workflows.
Do not run CH01-CH05.
Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, or Checkmk.
