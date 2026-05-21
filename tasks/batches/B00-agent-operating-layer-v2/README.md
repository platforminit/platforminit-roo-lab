# B00 — Agent Operating Layer v2

## Goal

Install a PlatformInit-specific Roo agent team and skill library before running full-access dev workflows.

## Why

The lab repository can reach the same dev workflows and secrets as the working repository. That power is acceptable only if Roo is constrained by mode-specific rules, project skills, roadmap context, and Peximed failure lessons.

## Branch

```text
batch/roo-lab-first-validation
```

## Tasks

| ID | Task |
|---|---|
| B00-T01 | Add `.roomodes` with PlatformInit specialist modes |
| B00-T02 | Add global `.roo/rules.md` |
| B00-T03 | Add mode-specific rules |
| B00-T04 | Add architecture and roadmap context |
| B00-T05 | Add curated memory baseline and raw memory archive |
| B00-T06 | Add Peximed failure lessons |
| B00-T07 | Add Claude package review as reference-only note |
| B00-T08 | Add project skills |
| B00-T09 | Validate Roo mode/skill discovery |
| B00-T10 | Run repo-only validation, no infrastructure workflows |

## Acceptance criteria

- Roo custom modes are visible in the mode selector.
- Project skills are discoverable.
- `.roomodes` points to `platforminit-roo-lab`, not the stable repo.
- `tasks/active/NEXT_TASK.md` is self-contained.
- No infrastructure workflow is triggered.
- No secrets are printed.
- `development` and `n8n` environments exist.
- Current branch is not `dev`.
