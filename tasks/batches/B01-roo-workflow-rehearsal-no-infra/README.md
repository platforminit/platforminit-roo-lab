# B01 — Roo Workflow Rehearsal Without Infrastructure Mutation

## Purpose

Rehearse the PlatformInit Roo workflow using task/docs-only changes before any infrastructure workflow rehearsal is allowed.

## Scope

This batch is limited to orchestration documentation, active task state, a validation-report template, and changed-files reviewer handoff.

Allowed files:

- `tasks/active/NEXT_TASK.md`
- `tasks/active/CURRENT_ACTIVE_TASKS.md`
- `tasks/batches/B01-roo-workflow-rehearsal-no-infra/README.md`
- `docs/roo-lab/VALIDATION_REPORT_TEMPLATE.md`

## Branch

```text
batch/roo-workflow-rehearsal-no-infra
```

## Prerequisites

- Roo is running from VS Code Remote WSL.
- Workspace path is `/mnt/d/SYSADMIN/platforminit-roo-lab`.
- User is `hattila`.
- Current mode is `PlatformInit Orchestrator`.
- B00 agent operating layer validation is complete.

## Mandatory startup commands

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
pwd
grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK
id -un
git branch --show-current
git status --short
git remote -v
```

Expected key output:

```text
/mnt/d/SYSADMIN/platforminit-roo-lab
WSL_OK
hattila
batch/roo-workflow-rehearsal-no-infra
```

## Tasks

| ID | Task |
|---|---|
| B01-T01 | Update `tasks/active/NEXT_TASK.md` to B01 |
| B01-T02 | Update `tasks/active/CURRENT_ACTIVE_TASKS.md` to B01 while preserving guardrails |
| B01-T03 | Create this batch README |
| B01-T04 | Create or update `docs/roo-lab/VALIDATION_REPORT_TEMPLATE.md` |
| B01-T05 | Prepare changed-files-only reviewer handoff |
| B01-T06 | Validate changed files are limited to allowed task/docs paths |

## Explicit non-goals

- Do not trigger GitHub infrastructure workflows.
- Do not run CH01, CH02, CH03, CH04, CH04.5, or CH05.
- Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime.
- Do not modify GitHub secrets or environments.
- Do not target production/customer infrastructure.

## Validation

Run read-only validation only:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
git status --short
git diff --name-only
git diff --check
python3 - <<'PY'
from pathlib import Path
import subprocess

allowed = {
    'tasks/active/NEXT_TASK.md',
    'tasks/active/CURRENT_ACTIVE_TASKS.md',
    'tasks/batches/B01-roo-workflow-rehearsal-no-infra/README.md',
    'docs/roo-lab/VALIDATION_REPORT_TEMPLATE.md',
}

status_lines = subprocess.check_output(['git', 'status', '--short'], text=True).splitlines()
changed = set()
for line in status_lines:
    path = line[3:].strip()
    if path.endswith('/'):
        for found in subprocess.check_output(['find', path, '-type', 'f'], text=True).splitlines():
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

Expected output:

```text
CHANGED_FILES_SCOPE_OK
```

## Changed-files reviewer handoff

Use `PlatformInit OpenAI Reviewer`.

Prompt:

```text
Review changed files only for B01 — Roo Workflow Rehearsal Without Infrastructure Mutation.

Verify the patch is limited to task/docs files, preserves deprecated component guardrails, avoids infrastructure mutation instructions, avoids CH01-CH05 execution, avoids GitHub secret/environment mutation, and includes read-only validation plus recovery notes.

End with APPROVE, REQUEST_CHANGES, or BLOCK.
```

## Failure modes

- Wrong branch: stop and switch to the correct batch branch only with human-approved Git steps.
- Non-WSL runtime: stop and reopen from VS Code Remote WSL.
- Unexpected changed files: stop and remove only unintended docs/task edits with targeted patches.
- Secret value appears: stop, do not copy it, and request security review.
- Infrastructure mutation instruction appears: stop and remove the instruction before review.

## Recovery

Use targeted reverse patches for unintended documentation edits. Do not use broad destructive Git commands such as `git reset --hard` or `git clean -fdx` unless explicitly approved by the human operator.

## Next step

After local validation passes, hand the changed files to `PlatformInit OpenAI Reviewer` for changed-files-only review.
