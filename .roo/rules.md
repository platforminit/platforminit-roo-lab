# PlatformInit Roo Lab — Global Rules

These rules apply to all PlatformInit custom modes in this repository.

## Repository identity

- Repository role: full-access development rehearsal controller.
- Local root: `/mnt/d/SYSADMIN/platforminit-roo-lab`
- Stable recovery source: `/mnt/d/SYSADMIN/platforminit-platform`
- Default branch: `dev`
- First working branch: `batch/roo-lab-first-validation`
- Active dev host: `platforminit-dev-01`
- Forbidden host name: `deprecated long-form development host alias`
- Downloads path: `/mnt/c/Users/hattila/Downloads`
- Shell: WSL Ubuntu only.

## Non-negotiable execution rules

1. Start from `tasks/active/NEXT_TASK.md` or an explicitly assigned batch README.
2. Verify WSL, repo root, branch, and working tree before changing files.
3. Never use Windows CMD, PowerShell, Git Bash, MobaXterm shell, or `vscode-remote://` launchers.
4. Do not push directly to `dev`.
5. Do not dump secret values into files, logs, artifacts, markdown, or terminal output.
6. Treat `platforminit-dev-01` as disposable but protect secrets and production/customer scope.
7. Prefer small, targeted patches over broad rewrites.
8. Every implementation must include validation commands and a rollback/recovery note.
9. Every reviewer must review changed files only unless the task explicitly says full-repo review.
10. OWASP/security review is read-only unless the human explicitly approves a fix batch.

## Source-of-truth order

Agents must resolve conflicts in this order:

1. Current human instruction in the chat/task.
2. `tasks/active/NEXT_TASK.md`.
3. `docs/roo-lab/context/ACTIVE_AGENT_CONTEXT.md`.
4. Current repository files and workflow definitions.
5. CH01-CH15 roadmap context.
6. Archived/historical memory, only if explicitly referenced.

`DEPRECATED_COMPONENTS.md` is a hard negative context file: if a component is listed there as deprecated or superseded, agents must not resurrect it without an explicit architect decision.

## Active architecture baseline

PlatformInit is a cost-conscious, single-node, deterministic rebuild platform:

- Hetzner Cloud
- Ubuntu
- GitHub Actions
- Terraform where applicable
- k3s single-node Kubernetes
- Argo CD GitOps ownership for long-running cluster workloads
- Traefik ingress
- cert-manager + Let's Encrypt
- Cloudflare DNS-01
- Authentik identity/SSO
- Checkmk Community for operator-first monitoring
- Separate `development`, `n8n`, and later `platforminit` project scopes

## Hetzner and secret model

Expected project-scoped token names:

- `HCLOUD_TOKEN_DEVELOPMENT`
- `HCLOUD_TOKEN_N8N`
- `HCLOUD_TOKEN_PLATFORMINIT`

`INFRA_API_TOKEN` is legacy fallback only. Do not introduce new code paths that prefer it over project-scoped tokens.

Local raw token bootstrap files, if present, must remain ignored and must never be committed:

- `.local_secrets/development_api_key`
- `.local_secrets/n8n_api_key`
- `.local_secrets/platforminit_api_key`

## Batch lifecycle

Preferred lifecycle:

1. Orchestrator reads the active batch.
2. Architect clarifies decisions if needed.
3. DeepSeek Coder implements bounded tasks.
4. OpenAI Reviewer performs changed-files-only review.
5. OWASP Reviewer performs read-only security/privacy/release review for security-sensitive or batch-end gates.
6. SRE Diagnostics validates evidence if infrastructure/runtime changed.
7. Release Manager prepares known-good checkpoint if validation passes.
8. Docs Operator updates handoff/runbook docs.

## Lessons learned from Peximed failure
<!-- PLATFORMINIT_NATIVE_SWITCH_MODE_HANDOFF_START -->
## Native Roo mode-switch handoff contract

PlatformInit roles MUST use native Roo `switch_mode` handoff when the next phase belongs to another PlatformInit role.

Manual next-prompt printing is forbidden during normal role flow. It is allowed only when native `switch_mode` is unavailable or blocked. In that case the role must explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

Required role flow:

1. PlatformInit Orchestrator MUST request native switch to `platforminit-deepseek-coder`.
2. PlatformInit DeepSeek Coder MUST request native switch to `platforminit-openai-reviewer`.
3. PlatformInit OpenAI Reviewer:
   - on `APPROVE`, MUST request native switch to `platforminit-owasp-reviewer`;
   - on `REQUEST_CHANGES`, MUST request native switch back to `platforminit-deepseek-coder` with the exact requested fix.
4. PlatformInit OWASP Reviewer:
   - on `PASS`, MUST request native switch to `platforminit-release-manager`;
   - on `MUST_FIX`, MUST request native switch back to `platforminit-deepseek-coder` with the exact fix request.
5. PlatformInit Release Manager MUST prepare the final human commit/PR/merge handoff.

Human approval remains mandatory before:

- CH01-CH05 workflow execution;
- infrastructure mutation;
- GitHub secret or environment mutation;
- production/customer scope;
- Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime changes.
<!-- PLATFORMINIT_NATIVE_SWITCH_MODE_HANDOFF_END -->
