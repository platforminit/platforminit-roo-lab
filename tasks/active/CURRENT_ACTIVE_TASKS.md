# Current Active Tasks

This file is the active task source for PlatformInit Roo Lab.

## Active repository

- Repository: `platforminit-roo-lab`
- Primary branch: `dev`
- Current work branch: `batch/roo-role-handoff-rehearsal-v2`
- Target role: full-access dev workflow rehearsal repository
- Disposable target host: `platforminit-dev-01`
- Stable recovery source: `platforminit-platform`

## Active work package

### B02 — Native Role Handoff Rehearsal Without Infrastructure Mutation

Goal: rehearse the full PlatformInit native Roo `switch_mode` role handoff lifecycle with docs/task-only changes. Validate that each role can hand off to the next via native `switch_mode` without printing manual prompts, without triggering infrastructure workflows, and without mutating runtime infrastructure.

Active tasks:

1. Create `tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md` with full batch definition.
2. Create `docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md` with handoff contract and validation checks.
3. Update `tasks/active/NEXT_TASK.md` to B02.
4. Update `tasks/active/CURRENT_ACTIVE_TASKS.md` to B02.
5. Validate changed files are limited to allowed task/docs paths.
6. Request native `switch_mode` to `platforminit-openai-reviewer`.

## Role sequence

```text
PlatformInit Orchestrator
  -> switch_mode: platforminit-deepseek-coder

PlatformInit DeepSeek Coder
  -> switch_mode: platforminit-openai-reviewer

PlatformInit OpenAI Reviewer
  APPROVE -> switch_mode: platforminit-owasp-reviewer
  REQUEST_CHANGES -> switch_mode: platforminit-deepseek-coder

PlatformInit OWASP Reviewer
  PASS -> switch_mode: platforminit-release-manager
  MUST_FIX -> switch_mode: platforminit-deepseek-coder

PlatformInit Release Manager
  -> final human commit/PR/merge handoff
```

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

The current Roo execution cycle must rehearse native role handoff through docs/task-only changes.

Do not trigger infrastructure workflows.
Do not run CH01-CH05.
Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime.
Do not modify GitHub secrets or environments.
Do not modify GitHub Actions workflows.
Do not resurrect deprecated CH05 directions as active work.
