# NEXT TASK — platform

## Task

- Track: `platform`
- Task ID: `P-CH04-T01`
- Chapter: `CH04`
- Title: Define platform services GitOps contract (Traefik, cert-manager, Argo CD)
- Branch: `batch/platform-ch04-platform-services-gitops-contract`
- Scope: `platform`

## Goal

Define and implement Traefik, cert-manager, and Argo CD GitOps contract for the platform track.

## Shared foundation model

This task does not consume a shared platform dependency.

No same-track dependency is declared for this current pointer.

## Acceptance criteria

- Traefik LoadBalancer exposes services on ports 80/443
- cert-manager issues Let's Encrypt certificates via Cloudflare DNS-01
- Argo CD is bootstrapped and manages its own ApplicationSet
- Platform services are deployed via Argo CD, not manual kubectl
- Validation scripts exist for each component

## Forbidden actions

- Do not resurrect deprecated CH05 directions as active work.
- Do not expose secret values.
- Do not use Windows shell, PowerShell, CMD, Git Bash, or MobaXterm for Roo execution.
- do not run infrastructure workflows
- do not mutate Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, n8n runtime, GitHub secrets, or GitHub environments
- do not expose secret values

## Required startup

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/orchestrator/start-next-task.sh --track platform
```

## Roo entrypoint

```text
Read tasks/active/platform/NEXT_TASK.md and execute the active task exactly as described.
```

## Native role handoff

PlatformInit roles must use native Roo `switch_mode` handoff.

Manual next-prompt printing is allowed only if native `switch_mode` is unavailable or blocked, and the role must explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

## Release Manager executor requirements

After OWASP review passes, the PlatformInit Release Manager MUST execute the full lifecycle:

1. Detect the active task ID from `tasks/status/platform.json`.
2. Verify changed files and validation evidence are complete.
3. Create a scoped implementation commit with a descriptive message.
4. Push the branch to origin.
5. Open a PR via `gh` CLI. If `gh` is unavailable, produce manual PR instructions and mark `BLOCKED_BY_TOOLING`.
6. After merge, run `./scripts/orchestrator/close-current-task.sh`.
7. Verify status/roadmap/NEXT_TASK agreement.
8. Commit and push closure metadata.
9. Start or prepare the next task.

The Release Manager MUST NOT stop at "human commit pending" unless the blocker is explicitly marked `BLOCKED_BY_PERMISSION` or `BLOCKED_BY_TOOLING`.

Forbidden phrases that must NOT appear as active contract wording:

- `final human commit/PR/merge handoff`
- `human commit pending`
- `commit recommendation` (when used as a handoff instruction)
