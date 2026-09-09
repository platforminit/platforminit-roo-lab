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
2. `tasks/tracker.json` — the only authoritative task registry and mutable task state.
3. Generated task views under `tasks/active/`.
4. Current repository files, workflow definitions, architecture docs, and runbooks.
5. Archived/historical material only when explicitly referenced.

Generated Markdown is read-only. Never edit task state in `tasks/active/*.md`.
Never recreate `tasks/status/*.json`, `tasks/roadmap/*.json`, `CURRENT_ACTIVE_TASKS.md`, or other competing current/next-task sources.

Use the controller instead of editing task state directly:

```bash
python3 tools/task_controller/taskctl.py list
python3 tools/task_controller/taskctl.py next --track platform
python3 tools/task_controller/taskctl.py next --track n8n
python3 tools/task_controller/taskctl.py validate
```

## Non-negotiable execution rules

1. Load the active task through the controller or the compact delivery-context MCP tool before opening broad repository context.
2. Verify WSL, repository root, expected task branch, and working tree before changing files.
3. Never use Windows CMD, PowerShell, Git Bash, MobaXterm shell, or `vscode-remote://` launchers for Roo execution.
4. Never push directly to `dev`.
5. Never dump secret values into files, logs, artifacts, Markdown, or terminal output.
6. Prefer small, bounded patches within the task's `allowedFiles` scope.
7. Run the task's `requiredValidators` before submission and again before closure.
8. Reviewer and OWASP verdicts must be recorded through `taskctl`; prose-only approval is not sufficient.
9. Only the Release Manager may close a `ready_to_close` task, and only through `taskctl complete`.
10. Generated-view drift, duplicate task IDs, missing dependencies, invalid transitions, stale legacy task artifacts, and active branch/task mismatches are release blockers.

## Lifecycle

The canonical lifecycle is:

`pending -> in_progress -> needs_review -> needs_security_review -> ready_to_close -> done`

Failure/rework transitions are controller-owned:

- reviewer `request_changes` -> `in_progress`;
- OWASP `review_required` -> `in_progress`;
- reviewer/OWASP `block` or explicit block command -> `blocked`;
- only the Orchestrator may unblock a task.

Role flow:

1. `platforminit-orchestrator` starts exactly one runnable task for a track.
2. `platforminit-deepseek-coder` implements only the bounded task scope and submits through the controller.
3. `platforminit-openai-reviewer` records `approve`, `request_changes`, or `block` with a report under `docs/reviews/`.
4. `platforminit-owasp-reviewer` records `clear`, `review_required`, or `block` with a report under `docs/security-reviews/`.
5. `platforminit-release-manager` closes only a fully approved task through the controller.

Use native Roo `switch_mode` handoff whenever the next stage belongs to another PlatformInit role. Manual next-prompt printing is fallback-only and must report `SWITCH_MODE_UNAVAILABLE_FALLBACK_USED`.

## Context and token discipline

Prefer compact context before raw file reads:

- active task and transition;
- changed files against `dev`;
- task-specific allowed paths;
- focused tests/validators;
- one or two path-scoped codebase searches.

Do not load entire roadmap/history files into context. Use codebase indexing/search for discovery and open only the relevant files. `tools/platforminit_mcp/` provides repository-local context tooling; future RAG must build on this boundary rather than becoming a second task source of truth.

## Active architecture baseline

PlatformInit remains a cost-conscious, deterministic rebuild platform built around Hetzner Cloud, Ubuntu, GitHub Actions, k3s, Argo CD, Traefik, cert-manager/Let's Encrypt, Cloudflare DNS-01, Authentik, and Checkmk Community. The `n8n` track remains standalone and consumes only shared host-lifecycle/baseline capabilities unless a later task explicitly changes that contract.

`DEPRECATED_COMPONENTS.md` remains a hard negative context file. Deprecated or superseded components must not be resurrected without an explicit architect decision.

## Human approval boundary

Human approval remains mandatory before:

- CH01-CH05 workflow execution;
- infrastructure mutation;
- GitHub secret or environment mutation;
- production/customer scope;
- Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime changes.
