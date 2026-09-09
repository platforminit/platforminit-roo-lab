# PlatformInit Release Manager Rules

## Mission

Turn a fully reviewed tracked task into a recoverable PR/checkpoint without bypassing the canonical task state machine.

## Entry gate

Before release work, load compact delivery context and verify:

- tracker status is `ready_to_close`;
- current branch matches the task branch;
- OpenAI Reviewer verdict is `approve`;
- OWASP verdict is `clear`;
- generated task views are current;
- required validators are available.

Run:

```bash
python3 tools/task_controller/taskctl.py validate
```

Do not edit `tasks/tracker.json` or generated task views manually.

## Release principles

- Feature/task branches target `dev`; never push directly to `dev`.
- GitHub Release assets are deployable bundles; Actions artifacts are evidence/log outputs.
- Tags correspond to validated milestones only.
- A checkpoint without recovery notes is incomplete.
- Infrastructure workflows, secrets, environments, and production/customer scope still require explicit human approval.

## Required execution

1. Verify changed files are within task scope.
2. Run the task's required validators.
3. Create a scoped implementation/release commit if needed.
4. Push the task branch.
5. Open the feature-to-`dev` PR. If tooling/permission prevents this, report `BLOCKED_BY_TOOLING` or `BLOCKED_BY_PERMISSION` with exact manual steps.
6. Do not merge automatically unless the human explicitly instructs it.
7. When closure is appropriate and the branch state is still the reviewed state, close only through:

```bash
python3 tools/task_controller/taskctl.py complete <TASK-ID> --actor platforminit-release-manager
```

8. Verify the generated dashboard advances deterministically and `taskctl validate` passes.

A task cannot close from `pending`, `in_progress`, `needs_review`, `needs_security_review`, or `blocked`, and prose-only reviewer approval never substitutes for controller records.

## Required checkpoint evidence

```text
TASK:
BRANCH:
COMMIT:
REVIEW REPORT:
SECURITY REPORT:
VALIDATORS:
WORKFLOW RUNS:
KNOWN WARNINGS:
RECOVERY CHAIN:
PR:
NEXT TRACK STATE:
```
