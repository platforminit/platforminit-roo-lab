# B02 — Native Role Handoff Rehearsal (v2)

## Purpose

Validate the automatic native Roo `switch_mode` handoff contract across all PlatformInit roles without infrastructure mutation. This rehearsal proves that each role can hand off to the next via `switch_mode` without printing manual prompts, without triggering infrastructure workflows, and without mutating runtime infrastructure.

## Required role flow

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

## Contract rules

1. Each role MUST use native Roo `switch_mode` to hand off to the next role.
2. Manual next-prompt printing is forbidden during normal role flow.
3. If `switch_mode` is unavailable or blocked, the role MUST explicitly report:

   ```text
   SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
   ```

   Only then may it print the next role prompt.

4. Human approval remains mandatory before:
   - CH01-CH05 workflow execution;
   - infrastructure mutation;
   - GitHub secret or environment mutation;
   - production/customer scope;
   - Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime changes.

## What this rehearsal validates

| Check | Expected |
|---|---|
| Orchestrator -> Coder handoff | `switch_mode` to `platforminit-deepseek-coder` |
| Coder -> Reviewer handoff | `switch_mode` to `platforminit-openai-reviewer` |
| Reviewer -> OWASP handoff (on APPROVE) | `switch_mode` to `platforminit-owasp-reviewer` |
| OWASP -> Release Manager handoff (on PASS) | `switch_mode` to `platforminit-release-manager` |
| No infrastructure workflow triggered | All changes are docs/task-only |
| No CH01-CH05 command run | Only read-only validation commands used |
| No runtime mutation | No kubectl, hcloud, cloudflare, argocd, authentik, checkmk, DNS, k3s, n8n commands |
| No GitHub secret/environment mutation | No workflow dispatch, no environment edits |
| Fallback marker used if switch_mode blocked | `SWITCH_MODE_UNAVAILABLE_FALLBACK_USED` reported |

## Allowed files

- `tasks/active/NEXT_TASK.md`
- `tasks/active/CURRENT_ACTIVE_TASKS.md`
- `tasks/batches/B02-roo-role-handoff-rehearsal-v2/README.md`
- `docs/roo-lab/ROLE_HANDOFF_REHEARSAL_V2.md`

## Forbidden

- Do not run CH01-CH05.
- Do not trigger infrastructure workflows.
- Do not modify GitHub Actions workflows.
- Do not modify infrastructure code.
- Do not modify Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, n8n runtime.
- Do not modify GitHub secrets or environments.
- Do not resurrect deprecated CH05 directions as active work.

## Validation

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

## Recovery

If scope drift occurs, stop immediately and reverse only unintended docs/task edits with targeted patches. Do not use `git reset --hard`, `git clean -fdx`, force push, or broad destructive commands without explicit human approval. If a secret value appears, stop and do not repeat it.

## Source

- [`docs/roo-lab/NATIVE_SWITCH_MODE_HANDOFF.md`](../NATIVE_SWITCH_MODE_HANDOFF.md)
- [`.roo/rules.md`](../../.roo/rules.md) (lines 90-120, native handoff contract)
