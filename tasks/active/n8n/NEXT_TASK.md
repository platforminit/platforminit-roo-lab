# Next Active Task: N8N-CH01-T01 - Validate n8n root-disk-only host lifecycle

## Track

`n8n`

## Chapter

`N8N-CH01`

## Branch

`n8n/ch01-root-disk-only-host-lifecycle`

## Preferred mode

`PlatformInit Architect`

## Goal

Validate n8n as a separate standalone host track using the n8n Hetzner project, low-cost host assumptions, no attached volume by default, and /srv/n8n root-disk persistence.

## Human entrypoint

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/orchestrator/start-next-task.sh --track n8n
code .
```

Then in Roo:

```text
Read tasks/active/n8n/NEXT_TASK.md and execute the active task exactly as described.
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
n8n/ch01-root-disk-only-host-lifecycle
```

## Allowed files / paths

- `tasks/roadmap/n8n.json`
- `tasks/active/n8n/NEXT_TASK.md`
- `docs/roo-lab/N8N_ROADMAP.md`
- `.roo/skills/platforminit-n8n-standalone/SKILL.md`

## Forbidden actions

- Do not mutate the n8n host unless the task explicitly grants runtime approval.
- Do not run main PlatformInit CH01-CH05 workflows for n8n roadmap planning.
- Do not modify n8n runtime, Gmail labels, OAuth apps, Canva assets, secrets, or GitHub environments without explicit approval.

## Native Roo role handoff

Use the native Roo `switch_mode` contract.

Manual next-prompt printing is allowed only when native `switch_mode` is unavailable or blocked. If fallback is used, explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

## Completion rule

At closeout, Release Manager must run:

```bash
./scripts/orchestrator/close-current-task.sh --track n8n --task N8N-CH01-T01
```

This marks the task complete and regenerates the next task for this track.
