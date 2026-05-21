# Next Active Batch: B01 — Roo Workflow Rehearsal Without Infrastructure Mutation

## Purpose

Rehearse the PlatformInit Roo batch lifecycle with documentation-only changes before allowing any infrastructure mutation.

This batch validates that the agent operating layer can coordinate a scoped change, preserve branch gates, prepare reviewer handoff, and close out with evidence while avoiding Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, n8n runtime, GitHub secrets, and GitHub environments.

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

For this cycle, rehearse the Roo workflow without infrastructure mutation.
Update only task/docs files that are explicitly in scope.
Prepare changed-files reviewer handoff.
Do not trigger infrastructure workflows.
Do not run CH01-CH05.
Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime.
Do not modify GitHub secrets or environments.
```

## Mandatory startup checks

Run before any file change or delegation:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
pwd
grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK
id -un
git branch --show-current
git status --short
git remote -v
```

Expected:

```text
/mnt/d/SYSADMIN/platforminit-roo-lab
WSL_OK
hattila
batch/roo-workflow-rehearsal-no-infra
```

Stop if:

- repo root is not `/mnt/d/SYSADMIN/platforminit-roo-lab`;
- WSL guard does not return `WSL_OK`;
- user is not `hattila`;
- current branch is not `batch/roo-workflow-rehearsal-no-infra`;
- unexpected files are modified;
- any instruction would trigger infrastructure workflows or mutate runtime infrastructure.

## Scope

Allowed files for this batch:

- `tasks/active/NEXT_TASK.md`
- `tasks/active/CURRENT_ACTIVE_TASKS.md`
- `tasks/batches/B01-roo-workflow-rehearsal-no-infra/README.md`
- `docs/roo-lab/VALIDATION_REPORT_TEMPLATE.md`

Allowed work:

1. Confirm B00 agent operating layer validation is complete from current task state.
2. Define B01 as a docs/task-only Roo workflow rehearsal.
3. Preserve active context and deprecated component guardrails.
4. Provide a reusable short validation-report template.
5. Prepare changed-files-only reviewer handoff.
6. Validate that changed files are limited to the allowed docs/task paths.

## Out of scope

- CH01 host rebuild.
- CH02 baseline.
- CH03 k3s.
- CH04 platform enablement.
- CH04.5 identity.
- CH05 Checkmk.
- n8n runtime.
- Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, or k3s changes.
- GitHub workflow dispatch, GitHub environment mutation, or GitHub secret mutation.
- Production/customer scope.

## Role sequence

1. Orchestrator validates branch/status/task scope.
2. Orchestrator updates only the allowed task/docs files.
3. OpenAI Reviewer performs changed-files-only review.
4. OWASP Reviewer performs read-only security/privacy/release review only if the changed-files reviewer finds scope or secret-risk concerns.
5. Docs Operator is optional; use only if closeout docs need cleanup after review.

No DeepSeek implementation is needed unless the human explicitly asks for a coder handoff. This is a docs/task rehearsal only.

## Validation commands

Use read-only commands only:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
git status --short
git diff --name-only
git diff --check
python3 - <<'PY'
from pathlib import Path
allowed = {
    'tasks/active/NEXT_TASK.md',
    'tasks/active/CURRENT_ACTIVE_TASKS.md',
    'tasks/batches/B01-roo-workflow-rehearsal-no-infra/README.md',
    'docs/roo-lab/VALIDATION_REPORT_TEMPLATE.md',
}
status_lines = __import__('subprocess').check_output(['git', 'status', '--short'], text=True).splitlines()
changed = set()
for line in status_lines:
    path = line[3:].strip()
    if path.endswith('/'):
        for found in __import__('subprocess').check_output(['find', path, '-type', 'f'], text=True).splitlines():
            if found.strip():
                changed.add(found.strip())
    elif path:
        changed.add(path)
extra = sorted(changed - allowed)
if extra:
    raise SystemExit('Unexpected changed files: ' + ', '.join(extra))
print('CHANGED_FILES_SCOPE_OK')
PY
```

Expected output includes:

```text
CHANGED_FILES_SCOPE_OK
```

## Changed-files reviewer handoff

Reviewer mode: `PlatformInit OpenAI Reviewer`.

Reviewer prompt:

```text
Review changed files only for B01 — Roo Workflow Rehearsal Without Infrastructure Mutation.

Scope: docs/task-only changes that prepare the next Roo rehearsal cycle.
Verify:
- branch and startup gates are documented correctly;
- allowed files are limited to task/docs paths;
- infrastructure workflows and CH01-CH05 are explicitly out of scope;
- deprecated component guardrails remain intact;
- validation commands are read-only;
- no secret values, production/customer targets, or runtime mutation instructions appear.

End with APPROVE, REQUEST_CHANGES, or BLOCK.
```

## Completion criteria

- Only allowed task/docs files changed.
- No infrastructure workflow triggered.
- No CH01-CH05 command run.
- No Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime mutation.
- No GitHub secrets or environments modified.
- No secret values appear in files or logs.
- Reviewer handoff is ready.
- Repository remains on `batch/roo-workflow-rehearsal-no-infra`.

## Recovery

If scope drift occurs, stop immediately and restore only the unintended docs/task edits with a targeted reverse patch. Do not use broad destructive Git commands unless the human explicitly approves.
