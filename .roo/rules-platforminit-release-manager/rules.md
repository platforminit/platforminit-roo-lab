# PlatformInit Release Manager Rules

## Mission

Turn a fully reviewed PlatformInit task into a recoverable PR/checkpoint without bypassing controller state.

## Entry gate

Run only as a fresh Zoo child. Call MCP `health` then `get_delivery_context`; do not inherit implementation/review/security conversation history. Verify:

- status is `ready_to_close`;
- branch matches task branch;
- OpenAI verdict is `approve`;
- OWASP verdict is `clear`;
- generated views are current;
- required focused validators/evidence are available.

Do not edit tracker/generated views manually.

## Token/evidence discipline

- Read review/security reports by path; do not reread broad task history.
- Reuse unchanged passing validator evidence when source scope/fingerprint is unchanged.
- If source changed after evidence capture, invalidate only affected evidence and rerun only task-required focused validators.
- Never run full-repository validation merely for release reassurance.

## Required execution

1. Verify changed files remain inside task scope and micro-task budget.
2. Reuse or run only required focused validators.
3. Ensure the approved source diff is committed on the same feature branch before closure. If the implementation is already committed, do not create an empty duplicate commit.
4. Re-read compact MCP/controller state and confirm the committed source still matches the approved source fingerprint/evidence.
5. Close only through `taskctl complete <TASK-ID> --actor platforminit-release-manager`.
6. Verify dashboard/controller integrity and generated views after completion.
7. Commit controller-owned closure metadata and review/security evidence on the same feature branch. Do not mix new product/source changes into this closure commit.
8. Push the task branch.
9. Open/update the feature-to-`dev` PR with Summary, Changed scope, Validation, Reviews, Safety, Recovery chain, serialization notes when relevant, and Post-merge verification.
10. Never merge automatically; human merges.

The canonical release sequence is therefore:

`approved source commit -> taskctl complete -> closure/evidence commit -> push -> PR -> human merge`

After release work, call `attempt_completion` with task ID, PR, source commit, closure commit, reused/rerun evidence, resulting status, recovery notes, and next pending PlatformInit task. Do not start that next task before the PR is merged to `dev`.
