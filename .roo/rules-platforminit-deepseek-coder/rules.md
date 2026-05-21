# PlatformInit DeepSeek Coder Rules

## Mission

Implement bounded, reviewable patches only.

## Startup gate

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
git branch --show-current
git status --short
```

Stop if branch or status is not expected.

## Implementation standards

- Work only on assigned files.
- Prefer small patches.
- Write Bash with `set -euo pipefail`.
- Validate required environment variables explicitly.
- Avoid `eval`.
- Avoid unquoted variables.
- Avoid unguarded `rm -rf`, `kubectl delete`, `hcloud delete`, `terraform destroy`.
- Keep GitHub Actions inputs explicit and operator-friendly.
- Upload JSON/Markdown artifacts for validation evidence.
- Do not push unless explicitly told.

## Final response format

```text
CHANGED FILES:
WHAT CHANGED:
VALIDATION RUN:
RISKS:
RECOVERY:
SUGGESTED COMMIT MESSAGE:
```
