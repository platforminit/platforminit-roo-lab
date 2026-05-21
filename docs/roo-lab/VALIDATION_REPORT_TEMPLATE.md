# PlatformInit Roo Validation Report Template

Use this short template for Roo batch validation reports. Keep evidence concise and do not paste secret values.

## TASK

- Batch:
- Operator prompt:
- Scope summary:

## BRANCH

- Expected branch:
- Actual branch:
- Repo root:
- WSL guard:
- User:

## CURRENT STATE

- Changed files:
- Clean/dirty status:
- Infrastructure workflows triggered: no
- Runtime infrastructure mutated: no
- Secret values exposed: no

## ROLE SEQUENCE

- Orchestrator:
- Coder:
- Changed-files reviewer:
- OWASP reviewer:
- Diagnostics:
- Docs/release closeout:

## ALLOWED FILES

- List allowed paths for the batch.

## DO NOT TOUCH

- Hetzner.
- Cloudflare.
- Kubernetes.
- Authentik.
- Checkmk.
- DNS.
- k3s.
- n8n runtime.
- GitHub secrets.
- GitHub environments.
- Production/customer scope.

## VALIDATION

Commands run:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
pwd
grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK
id -un
git branch --show-current
git status --short
git diff --name-only
git diff --check
```

Expected key output:

```text
/mnt/d/SYSADMIN/platforminit-roo-lab
WSL_OK
hattila
```

Result:

- PASS/FAIL:
- Notes:

## RECOVERY

- Recovery action needed:
- If needed, use targeted reverse patches only.
- Do not use broad destructive Git commands without explicit human approval.

## REVIEWER HANDOFF

Reviewer mode: `PlatformInit OpenAI Reviewer`

Prompt:

```text
Review changed files only for the active PlatformInit Roo batch.

Verify changed-file scope, branch discipline, read-only validation, no secret exposure, no production/customer scope, no infrastructure mutation, and preservation of deprecated component guardrails.

End with APPROVE, REQUEST_CHANGES, or BLOCK.
```

## NEXT PROMPT

- Recommended next prompt or closeout action:
