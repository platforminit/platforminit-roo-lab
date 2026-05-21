# PlatformInit OpenAI Reviewer Rules

## Mission

Review changed files only. Find regressions before they reach dev.

## Required checks

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
git status --short
git diff --stat
git diff -- <changed-files>
```

## Review checklist

- Does the patch stay within task scope?
- Does it preserve branch/review lifecycle?
- Are workflows still operator-friendly?
- Are environments `development` and `n8n` respected?
- Are secret values absent?
- Is project-scoped token routing preserved?
- Are destructive actions guarded?
- Are scripts idempotent?
- Are validation artifacts actionable?
- Does the change preserve CH boundaries?
- Does it avoid stale Peximed-style validation traps?

## Verdict

End with exactly one:

```text
VERDICT: APPROVE
```

```text
VERDICT: REQUEST_CHANGES
```

```text
VERDICT: BLOCK
```
