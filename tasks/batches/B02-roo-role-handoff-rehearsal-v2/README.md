# B02 — Native Role Handoff Rehearsal Without Infrastructure Mutation

## Purpose

Rehearse the full PlatformInit native Roo `switch_mode` role handoff lifecycle using docs/task-only changes. Validate that each role can hand off to the next via native `switch_mode` without printing manual prompts, without triggering infrastructure workflows, and without mutating runtime infrastructure.

## Scope

This batch is limited to task/docs files that define the B02 rehearsal. No infrastructure code, no GitHub Actions workflows, no CH01-CH05 scripts, no runtime mutation.

Allowed files:

- `tasks/active/NEXT_TASK.md`
- `tasks/active/CURRENT_ACTIVE_TASKS.md`
- `tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md`
- `docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md`

## Branch

```text
batch/roo-role-handoff-rehearsal-v2
```

## Prerequisites

- Roo is running from VS Code Remote WSL.
- Workspace path is `/mnt/d/SYSADMIN/platforminit-roo-lab`.
- User is `hattila`.
- Current mode is `PlatformInit DeepSeek Coder`.
- Startup gate passed: WSL_OK, correct branch, clean working tree.

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
batch/roo-role-handoff-rehearsal-v2
```

## Tasks

| ID | Task |
|---|---|
| B02-T01 | Create `tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md` |
| B02-T02 | Create `docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md` |
| B02-T03 | Update `tasks/active/NEXT_TASK.md` to B02 |
| B02-T04 | Update `tasks/active/CURRENT_ACTIVE_TASKS.md` to B02 |
| B02-T05 | Validate changed files are limited to allowed task/docs paths |
| B02-T06 | Request native `switch_mode` to `platforminit-openai-reviewer` |

## Role sequence

```text
PlatformInit Orchestrator
  -> switch_mode: platforminit-deepseek-coder  (this phase)

PlatformInit DeepSeek Coder
  -> switch_mode: platforminit-openai-reviewer  (next phase)

PlatformInit OpenAI Reviewer
  APPROVE -> switch_mode: platforminit-owasp-reviewer
  REQUEST_CHANGES -> switch_mode: platforminit-deepseek-coder

PlatformInit OWASP Reviewer
  PASS -> switch_mode: platforminit-release-manager
  MUST_FIX -> switch_mode: platforminit-deepseek-coder

PlatformInit Release Manager
  -> detect active task ID
  -> verify changed files and validation evidence
  -> create scoped implementation commit
  -> push branch
  -> open PR via gh CLI (or BLOCKED_BY_TOOLING if unavailable)
  -> after merge: run close-current-task.sh
  -> verify status/roadmap/NEXT_TASK agreement
  -> commit/push closure metadata
  -> start or prepare next task
  -> never stop at "human commit pending" unless BLOCKED_BY_PERMISSION or BLOCKED_BY_TOOLING
```

## Explicit non-goals

- Do not trigger GitHub infrastructure workflows.
- Do not run CH01, CH02, CH03, CH04, CH04.5, or CH05.
- Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime.
- Do not modify GitHub secrets or environments.
- Do not modify GitHub Actions workflows.
- Do not resurrect deprecated CH05 directions as active work.
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
    'tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md',
    'docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md',
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
Review changed files only for B02 — Native Role Handoff Rehearsal Without Infrastructure Mutation.

Verify the patch is limited to task/docs files, preserves deprecated component guardrails, avoids infrastructure mutation instructions, avoids CH01-CH05 execution, avoids GitHub secret/environment mutation, and includes read-only validation plus recovery notes.

End with APPROVE, REQUEST_CHANGES, or BLOCK.
```

## Failure modes

- Wrong branch: stop and switch to the correct batch branch only with human-approved Git steps.
- Non-WSL runtime: stop and reopen from VS Code Remote WSL.
- Unexpected changed files: stop and remove only unintended docs/task edits with targeted patches.
- Secret value appears: stop, do not copy it, and request security review.
- Infrastructure mutation instruction appears: stop and remove the instruction before review.
- Native `switch_mode` unavailable: use fallback marker `SWITCH_MODE_UNAVAILABLE_FALLBACK_USED` and print the next role prompt manually.

## Recovery

Use targeted reverse patches for unintended documentation edits. Do not use broad destructive Git commands such as `git reset --hard` or `git clean -fdx` unless explicitly approved by the human operator.

## Next step

After local validation passes, request native `switch_mode` to `platforminit-openai-reviewer` for changed-files-only review.
