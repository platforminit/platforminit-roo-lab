# Next Active Batch: B00 — Agent Operating Layer v2

## Human entrypoint

Open from WSL:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
code .
```

Use Roo in `PlatformInit Orchestrator` mode.

## First Roo prompt

```text
Read tasks/active/NEXT_TASK.md and execute the active batch exactly as described.

For this first cycle, validate the agent operating layer only.
Do not trigger infrastructure workflows.
Do not run CH01-CH05.
Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, or Checkmk.
```

## Mandatory checks

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
pwd
grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK
id -un
git branch --show-current
git status --short
gh api -H "Accept: application/vnd.github+json" /repos/platforminit/platforminit-roo-lab/environments --jq '.environments[].name'
```

Expected:

```text
/mnt/d/SYSADMIN/platforminit-roo-lab
WSL_OK
hattila
batch/roo-lab-first-validation
development
n8n
```

## Scope

This batch validates repository agent infrastructure only:

- `.roomodes`
- `.roo/rules.md`
- `.roo/rules-platforminit-*`
- `.roo/skills/*/SKILL.md`
- roadmap and memory context docs
- Peximed lessons docs
- active task contract

## Out of scope

- CH01 host rebuild
- CH02 baseline
- CH03 k3s
- CH04 platform
- CH04.5 identity
- CH05 Checkmk
- n8n runtime
- any production/customer scope

## Role sequence

1. Orchestrator validates branch/status/task.
2. Architect reviews whether context docs match current PlatformInit strategy.
3. OpenAI Reviewer reviews changed files only.
4. OWASP Reviewer performs read-only review for secret/scope leakage.
5. Docs Operator prepares closeout.

No DeepSeek implementation is needed unless validation finds a concrete file issue.

## Completion criteria

- Repo remains clean after validation or changes are committed on the batch branch.
- No infra workflows were triggered.
- No secret values appear in files or logs.
- Roo modes and skills are available after VS Code reload.
- Next batch recommendation is written.
