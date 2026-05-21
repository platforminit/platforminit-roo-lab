# Next Active Batch: B02 — Native Role Handoff Rehearsal Without Infrastructure Mutation

## Purpose

Rehearse the full PlatformInit native Roo `switch_mode` role handoff lifecycle with docs/task-only changes. Validate that each role can hand off to the next via native `switch_mode` without printing manual prompts, without triggering infrastructure workflows, and without mutating runtime infrastructure.

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

For this cycle, rehearse the native Roo role handoff without infrastructure mutation.
Update only task/docs files that are explicitly in scope.
Prepare changed-files reviewer handoff.
Do not trigger infrastructure workflows.
Do not run CH01-CH05.
Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime.
Do not modify GitHub secrets or environments.
Do not modify GitHub Actions workflows.
Do not resurrect deprecated CH05 directions as active work.
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
batch/roo-role-handoff-rehearsal-v2
```

Stop if:

- repo root is not `/mnt/d/SYSADMIN/platforminit-roo-lab`;
- WSL guard does not return `WSL_OK`;
- user is not `hattila`;
- current branch is not `batch/roo-role-handoff-rehearsal-v2`;
- unexpected files are modified;
- any instruction would trigger infrastructure workflows or mutate runtime infrastructure.

## Scope

Allowed files for this batch:

- `tasks/active/NEXT_TASK.md`
- `tasks/active/CURRENT_ACTIVE_TASKS.md`
- `tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md`
- `docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md`

Allowed work:

1. Create `tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md` with full batch definition.
2. Create `docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md` with handoff contract and validation checks.
3. Update `tasks/active/NEXT_TASK.md` to B02.
4. Update `tasks/active/CURRENT_ACTIVE_TASKS.md` to B02.
5. Validate changed files are limited to the allowed docs/task paths.
6. Request native `switch_mode` to `platforminit-openai-reviewer`.

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
- GitHub Actions workflow file changes.
- Production/customer scope.
- Resurrecting deprecated CH05 directions as active work.

## Role sequence

```text
PlatformInit Orchestrator
  -> switch_mode: platforminit-deepseek-coder

PlatformInit DeepSeek Coder
  -> switch_mode: platforminit-openai-reviewer

PlatformInit OpenAI Reviewer
  APPROVE -> switch_mode: platforminit-owasp-reviewer
  REQUEST_CHANGES -> switch_mode: platforminit-deepseek-coder

PlatformInit OWASP Reviewer
  PASS -> switch_mode: platforminit-release-manager
  MUST_FIX -> switch_mode: platforminit-deepseek-coder

PlatformInit Release Manager
  -> final human commit/PR/merge handoff
```

## Validation commands

Use read-only commands only:

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

Expected output includes:

```text
CHANGED_FILES_SCOPE_OK
```

## Changed-files reviewer handoff

Reviewer mode: `PlatformInit OpenAI Reviewer`.

Reviewer prompt:

```text
Review changed files only for B02 — Native Role Handoff Rehearsal Without Infrastructure Mutation.

Scope: docs/task-only changes that prepare the B02 native role handoff rehearsal.
Verify:
- branch and startup gates are documented correctly;
- allowed files are limited to task/docs paths;
- infrastructure workflows and CH01-CH05 are explicitly out of scope;
- deprecated component guardrails remain intact;
- validation commands are read-only;
- no secret values, production/customer targets, or runtime mutation instructions appear;
- the native switch_mode handoff contract is correctly documented.

End with APPROVE, REQUEST_CHANGES, or BLOCK.
```

## Completion criteria

- Only allowed task/docs files changed.
- No infrastructure workflow triggered.
- No CH01-CH05 command run.
- No Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime mutation.
- No GitHub secrets or environments modified.
- No GitHub Actions workflows modified.
- No secret values appear in files or logs.
- Reviewer handoff is ready.
- Repository remains on `batch/roo-role-handoff-rehearsal-v2`.

## Recovery

If scope drift occurs, stop immediately and restore only the unintended docs/task edits with a targeted reverse patch. Do not use broad destructive Git commands unless the human explicitly approves.
