# Next Active Task: PLATFORM-CH01-T01 - Validate host lifecycle source of truth

## Track

`platform`

## Chapter

`CH01`

## Branch

`platform/ch01-validate-host-lifecycle-source-of-truth`

## Preferred mode

`PlatformInit Architect`

## Goal

Normalize host lifecycle contracts, project routing, host naming, volume layout, and rebuild assumptions before mutable workflows.

## Human entrypoint

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/orchestrator/start-next-task.sh --track platform
code .
```

Then in Roo:

```text
Read tasks/active/platform/NEXT_TASK.md and execute the active task exactly as described.
```

## Required startup checks

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/lib/require-wsl-runtime.sh
git branch --show-current
git status --short
```

Expected branch:

```text
platform/ch01-validate-host-lifecycle-source-of-truth
```

## Allowed files / paths

- `tasks/roadmap/platform.json`
- `tasks/active/platform/NEXT_TASK.md`
- `docs/roo-lab/TASK_ORCHESTRATION_MODEL.md`

## Forbidden actions

- Do not run CH01-CH05 workflows unless the task explicitly grants runtime approval.
- Do not mutate Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, n8n runtime, GitHub secrets, or GitHub environments.
- Do not resurrect deprecated CH05 directions as active work.

## Native Roo role handoff

Use the native Roo `switch_mode` contract.

Manual next-prompt printing is allowed only when native `switch_mode` is unavailable or blocked. If fallback is used, explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

## Completion rule

At closeout, Release Manager must run:

```bash
./scripts/orchestrator/close-current-task.sh --track platform --task PLATFORM-CH01-T01
```

This marks the task complete and regenerates the next task for this track.
