# PlatformInit Roo Lab — Global Rules

These rules apply to all PlatformInit custom modes in this repository.

## Repository identity

- Repository role: full-access development rehearsal controller.
- Local root: `/mnt/d/SYSADMIN/platforminit-roo-lab`.
- Stable recovery source: `/mnt/d/SYSADMIN/platforminit-platform`.
- Default branch: `dev`.
- Shell: WSL Ubuntu only.

## Task source of truth

1. Current human instruction in the active chat/task.
2. `tasks/tracker.json` — the only authoritative PlatformInit task registry and mutable PlatformInit task state.
3. Generated PlatformInit task views under `tasks/active/`.
4. Current repository files, workflow definitions, architecture docs, and runbooks.
5. Archived/historical material only when explicitly referenced.

Generated Markdown is read-only. Never edit task state in `tasks/active/*.md`.
Never recreate legacy task/status/roadmap files as competing PlatformInit current/next-task sources.

n8n is a separate delivery track with its own roadmap and parked registry under `docs/n8n/` and
`n8n/tasks/`. It must not be selected, started, reviewed, or closed through PlatformInit taskctl,
`/next-task`, generated views, or PlatformInit MCP.

Use the PlatformInit controller instead of editing task state directly:

```bash
python3 tools/task_controller/taskctl.py list --track platform
python3 tools/task_controller/taskctl.py next --track platform
python3 tools/task_controller/taskctl.py validate
```

## Non-negotiable execution rules

1. Load MCP `health` and `get_delivery_context` before broad repository context.
2. Verify WSL, repository root, expected task branch, and working tree before changing files.
3. Never use Windows CMD, PowerShell, Git Bash, MobaXterm shell, or `vscode-remote://` launchers for Zoo execution.
4. Never push directly to `dev`.
5. Never expose secret values in files, logs, artifacts, Markdown, or terminal output.
6. Prefer small, bounded patches within the task's `allowedFiles` scope.
7. Run only task-required/focused validators unless a changed shared dependency invalidates earlier evidence.
8. Reviewer and OWASP verdicts must be recorded through taskctl; prose-only approval is insufficient.
9. Only the Release Manager may close `ready_to_close`, and only through taskctl.
10. Generated-view drift, duplicate IDs, missing dependencies, invalid transitions, stale legacy authoritative artifacts, and active branch/task mismatch are release blockers.

## Lifecycle and Zoo handoff

Canonical lifecycle:

`pending -> in_progress -> needs_review -> needs_security_review -> ready_to_close -> done`

Failure/rework transitions remain controller-owned.

Every specialist transition MUST use a fresh Zoo `new_task` child. Do not use legacy Roo `switch_mode`
for delivery stages and do not continue a new specialist in the previous specialist's accumulated
conversation.

Role flow:

1. Orchestrator starts exactly one runnable PlatformInit task.
2. Fresh `platforminit-deepseek-coder` child implements and submits.
3. Orchestrator reloads compact MCP context.
4. Fresh `platforminit-openai-reviewer` child reviews and records one consolidated verdict batch.
5. Orchestrator reloads compact MCP context.
6. Fresh `platforminit-owasp-reviewer` child performs security/privacy review.
7. Orchestrator reloads compact MCP context.
8. Fresh `platforminit-release-manager` child verifies evidence, prepares PR, and closes via controller.

Each child must call `attempt_completion` with resulting controller status, changed/evidence paths, and
unresolved risks. The parent reloads MCP context before routing again.

## Context and token discipline

- MCP compact context first; raw tracker/roadmap reads are fallback only.
- Target 1-3 primary non-state changed files per task.
- 4-5 primary files is exceptional and must be justified.
- More than 5 non-state files or more than one subsystem/operator contract =>
  `TASK_TOO_LARGE_SPLIT_REQUIRED`.
- Use path-scoped codebase search before raw broad reads.
- Full-repository validation is forbidden unless explicitly required or invalidated by shared changes.
- Reuse unchanged passing evidence; do not rerun passing checks for reassurance.
- Review/security findings return as one consolidated batch.
- On API 400/context exhaustion, terminate the child and resume in a fresh child from MCP compact
  context and evidence paths. Never rebuild failed context with broad repository rereads.

## MCP availability

Every `platforminit-*` project mode must include the `mcp` group. Fresh-child mode changes must be
verified with MCP `health` and `get_active_task`; `.roo/commands/mcp-smoke.md` is the runtime smoke
procedure and `tools/platforminit_mcp/validate_mode_access.py` is the static check.

## Active architecture baseline

PlatformInit remains a cost-conscious, deterministic rebuild platform built around Hetzner Cloud,
Ubuntu, GitHub Actions, k3s, Argo CD, Traefik, cert-manager/Let's Encrypt, Cloudflare DNS-01,
Authentik, and Checkmk Community.

`DEPRECATED_COMPONENTS.md` remains hard negative context. Deprecated or superseded components must
not be resurrected without an explicit architect decision.

## Human approval boundary

Human approval remains mandatory before:

- CH01-CH05 workflow execution;
- infrastructure mutation;
- GitHub secret or environment mutation;
- production/customer scope;
- Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime changes.
