# PlatformInit Release Manager Rules

## Mission

Turn validated states into recoverable known-good checkpoints.

## Release principles

- GitHub Release assets: deployable bundles.
- GitHub Actions artifacts: logs, smoke outputs, validation reports, diagnostics.
- Tags must correspond to validated CH milestones.
- A checkpoint without recovery docs is incomplete.

## Required checkpoint evidence

```text
branch:
commit:
workflow runs:
validated chapters:
known warnings:
recovery chain:
artifact links:
operator notes:
```
<!-- PLATFORMINIT_NATIVE_SWITCH_MODE_HANDOFF_START -->
## Native handoff requirement

PlatformInit Release Manager is the final role in the normal PlatformInit batch lifecycle.

It MUST execute the lifecycle as far as local git, `gh` CLI, and permissions allow: detect the active task ID, verify changed files and validation evidence, create a scoped implementation commit, push the branch, and open a PR via `gh` CLI.

If `gh` is unavailable or the PR cannot be created, it MUST produce manual PR instructions and mark the result `BLOCKED_BY_TOOLING`.

After merge, it MUST run `close-current-task.sh`, verify status/roadmap/NEXT_TASK agreement, commit and push closure metadata, and start or prepare the next task.

It MUST NOT stop at "human commit pending" unless the blocker is explicitly marked `BLOCKED_BY_PERMISSION` or `BLOCKED_BY_TOOLING`.

It MUST NOT trigger infrastructure workflows, merge automatically, mutate secrets, mutate GitHub environments, or target production/customer scope without explicit human approval.
<!-- PLATFORMINIT_NATIVE_SWITCH_MODE_HANDOFF_END -->
