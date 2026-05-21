# Current Active Tasks

This file is the active task source for PlatformInit Roo Lab.

## Active repository

- Repository: `platforminit-roo-lab`
- Primary branch: `dev`
- Current work branch: `batch/roo-workflow-rehearsal-no-infra`
- Target role: full-access dev workflow rehearsal repository
- Disposable target host: `platforminit-dev-01`
- Stable recovery source: `platforminit-platform`

## Active work package

### B01 - Roo Workflow Rehearsal Without Infrastructure Mutation

Goal: rehearse the Roo batch lifecycle with task/docs-only changes before allowing any infrastructure mutation.

Active tasks:

1. Update `tasks/active/NEXT_TASK.md` for B01.
2. Create `tasks/batches/B01-roo-workflow-rehearsal-no-infra/README.md`.
3. Create or update `docs/roo-lab/VALIDATION_REPORT_TEMPLATE.md`.
4. Preserve clean active context and deprecated component guardrails.
5. Prepare a changed-files-only reviewer handoff.
6. Validate changed files are limited to task/docs paths.
7. Validate no production/customer scope is targeted.
8. Validate no infrastructure workflows or runtime mutation commands are included.

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

## Current Roo execution rule

The current Roo execution cycle must rehearse workflow coordination only through task/docs changes.

Do not trigger infrastructure workflows.
Do not run CH01-CH05.
Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime.
Do not modify GitHub secrets or environments.
