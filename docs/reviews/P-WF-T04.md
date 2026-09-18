# P-WF-T04 Review — Reuse unchanged validation evidence

## Verdict

**APPROVE**

No consolidated findings. The reworked TOCTOU control resolves P-WF-T04-REV-001 within the stated design boundary.

## Changed-files review

- [`tools/task_controller/taskctl.py`](../../tools/task_controller/taskctl.py) takes a late confirmation reading before constructing `workflow.complete`, persists both confirmation fields, then recomputes the source fingerprint after `save()`. Drift causes a non-zero failure, restores `ready_to_close`, removes the stale completion record, and leaves valid JSON through the controller's atomic tracker replacement.
- [`tools/task_controller/test_taskctl.py`](../../tools/task_controller/test_taskctl.py) injects drift by wrapping `pathlib.Path.replace` in the subprocess that runs the shipped controller. The test observes the real command's exit status, persisted status, orphan-record absence, validator count, and successful focused-validator rerun on retry; it is not a production bypass.
- [`docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`](../../docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md) accurately describes the confirmation interval, post-persistence verification, repair behavior, and residual window after the final verification read. It does not claim perfect atomicity and documents the trust boundary.

## Acceptance criteria

1. **Met.** `submit` records a versioned deterministic fingerprint and sorted changed-file scope. The fingerprint is stable for identical source and changes for relevant source changes.
2. **Met.** `complete` reuses passing evidence only when fingerprint, scope, evidence shape, and validator plan match; the focused validator is not rerun on the unchanged path.
3. **Met.** Source drift invalidates reuse and runs only the task's required focused validators. Persistence-boundary drift is repaired and requires a later focused rerun.

## Evidence

- `python3 tools/task_controller/test_taskctl.py` — 35 tests, **OK**.
- `git diff --check` — exit 0.
- `python3 tools/task_controller/taskctl.py fingerprint --base dev` — fingerprint `12bbbad9ab475937299496e10600c4825be147ce7d8c5507d6136b547689538b`; exactly 3 files: [`docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`](../../docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md), [`tools/task_controller/taskctl.py`](../../tools/task_controller/taskctl.py), and [`tools/task_controller/test_taskctl.py`](../../tools/task_controller/test_taskctl.py).
- Controller-reported changed scope excludes generated/controller state and contains exactly the three bounded product paths.

## Residual risk

The implementation cannot detect a source mutation that occurs after the post-persistence re-verification read; eliminating that final TOCTOU interval would require source locking or filesystem snapshots and is explicitly outside this task. Evidence remains trusted controller state rather than authenticated attestation, as documented. Neither residual risk blocks this task's three acceptance criteria.
