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
   - PR-body repository links must be valid from the GitHub PR page; never copy review/security-report-relative links directly into the PR body.
   - Link repository files as `../blob/<PR_HEAD_SHA>/<repo-relative-path>` so evidence points at the reviewed PR head revision.
   - Link commits as `../commit/<commit-sha>`.
   - Local/transient evidence paths such as `/tmp/**` are not GitHub resources: render them as inline code/path text only, never as Markdown hyperlinks.
   - Before finishing the release stage, inspect every Markdown link in the PR body and reject/fix links that begin with filesystem paths or report-relative `../..` navigation.
10. Never merge automatically; human merges.

The canonical release sequence is therefore:

`approved source commit -> taskctl complete -> closure/evidence commit -> push -> PR -> human merge`

## Project-memory candidates (advisory only)

Project memory is advisory retrieval context. `tasks/tracker.json` plus `taskctl` remain the only
authoritative delivery state, and this optional step grants no authority over branch, allowed files,
validators, verdicts, or lifecycle transitions. Memory emission never blocks closure.

- **Emission window.** A completed task may only emit project-memory candidates after it reached
  `ready_to_close` with an OpenAI `approve` verdict and an OWASP `clear` verdict, and only from
  already committed approved evidence (`docs/reviews/<TASK-ID>.md`,
  `docs/security-reviews/<TASK-ID>.md`, controller-recorded task evidence).
- **Bounded and evidence-derived.** A candidate is a short reusable lesson with provenance, not a
  transcript. Emission is bounded per task, and raw transient logs, terminal output, `/tmp/**`
  payloads, key material, and secret values must never be copied into memory. The memory validator
  rejects absolute or traversing paths, secret-looking paths or values, and unapproved evidence paths.
- **Staging then explicit promotion.** Stage with
  `python3 tools/platforminit_mcp/memory.py add-candidate <json>`; promote with
  `python3 tools/platforminit_mcp/memory.py promote <MEMORY-ID>`. Both write repository-visible JSONL
  under `memory/project/`, so they are reviewed source changes and never a runtime side effect.
- **Never inside the closure commit.** Memory writes must not be mixed into the controller-owned
  closure/evidence commit, and must not be appended to the reviewed diff after review. Emit them as a
  separate, explicitly reviewed follow-up change on the task branch, or defer them to a dedicated
  memory task.
- **Deduplication and idempotence.** A duplicate candidate id, duplicate promoted content, or a
  second promotion of the same id is refused, so one fact is never emitted twice.
- **Retrieval boundary.** Unpromoted candidates are invisible to `get_relevant_memory`; only promoted
  records are retrieval context. Memory must never overwrite or substitute for controller state.

After release work, call `attempt_completion` with task ID, PR, source commit, closure commit, reused/rerun evidence, resulting status, recovery notes, and next pending PlatformInit task. Do not start that next task before the PR is merged to `dev`.
