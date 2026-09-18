# P-WF-T05 Security Review

## Verdict

**CLEAR** — no release-affecting security, privacy, or release-gate finding remains in the reviewed revision.

The prior D1 scope TOCTOU finding is closed for the actionable submit/complete paths. The residual non-atomic filesystem window is documented and remains an accepted limitation: the controller detects drift immediately after persistence and reverts a stale completion, while a mutation after that final read still requires the existing worktree/locking trust boundary.

## Reviewed scope

Changed paths reviewed against `origin/dev`:

- [`taskctl.py`](../../tools/task_controller/taskctl.py)
- [`test_taskctl.py`](../../tools/task_controller/test_taskctl.py)
- [`PLATFORM_WORKFLOW_REFACTOR.md`](../../docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md)

The active controller context reported task `P-WF-T05`, status `needs_security_review`, branch `chore/p-wf-t05-workflow`, and three changed files. Review remained limited to those paths and directly required trust boundaries.

## D1 closure and release-gate assessment

- [`change_snapshot()`](../../tools/task_controller/taskctl.py:383) gathers the non-state scope once and computes the fingerprint from that exact list through [`fingerprint_files()`](../../tools/task_controller/taskctl.py:361).
- [`enforce_scope()`](../../tools/task_controller/taskctl.py:521) applies both the allowed-files check and size check to the caller-supplied snapshot. It does not re-gather a competing scope.
- [`submit`](../../tools/task_controller/taskctl.py:651) performs a silent provisional hard gate before validators, then always gathers and gates a final snapshot before fingerprinting and persisting `workflow.submit.changedFiles` and `sourceFingerprint`. A late-added six-file scope therefore fails before submit evidence is written.
- [`complete`](../../tools/task_controller/taskctl.py:716) gates its initial snapshot, confirms reuse against a fresh fingerprint/scope, and re-gathers and re-gates the rerun path before constructing the completion record. The authoritative `changedFiles` and fingerprint are paired in the completion evidence.
- The post-persistence re-verification at [`taskctl.py`](../../tools/task_controller/taskctl.py:774) reverts the controller from `done` when the source differs immediately after the write. Thus the reviewed closeout path cannot intentionally yield a `done` record backed by an oversized scope observed before persistence; an unavoidable mutation after the last read remains the documented accepted residual risk.

The focused regression coverage includes late scope growth during submit and warning-band complete reruns in [`test_taskctl.py`](../../tools/task_controller/test_taskctl.py:601) and [`test_taskctl.py`](../../tools/task_controller/test_taskctl.py:655).

## Warning and hard-block flag review

No bypass was found in the new `emit_warning` / `emit_size_warning` plumbing:

- [`require_task_size()`](../../tools/task_controller/taskctl.py:473) always evaluates the hard threshold before consulting the warning flag. Suppressing output cannot suppress `TASK_TOO_LARGE_SPLIT_REQUIRED`.
- The silent calls are only the provisional gates in [`submit`](../../tools/task_controller/taskctl.py:657) and [`complete`](../../tools/task_controller/taskctl.py:725). Both are followed by an authoritative gate before persistence or closeout.
- The authoritative submit gate at [`taskctl.py`](../../tools/task_controller/taskctl.py:667) and the complete gates at [`taskctl.py`](../../tools/task_controller/taskctl.py:750) / [`taskctl.py`](../../tools/task_controller/taskctl.py:756) preserve hard-blocking and emit the warning at most once per command.
- The tests verify target, warning, hard-block, late-growth, and exactly-once behavior in [`test_taskctl.py`](../../tools/task_controller/test_taskctl.py:545).

## Privacy, injection, and release checks

No new secret, hostname, absolute local path, internal URL, or file-content disclosure was found. New messages expose only the task identifier, non-state file count, and threshold values. The reviewed code adds no shell interpolation, `eval`, `exec`, destructive command, sudo operation, network operation, or privilege change. Scope names are used only for the existing allowed-scope error and persisted repository-relative evidence.

The documentation change describes thresholds, snapshots, and accepted workflow behavior; it does not expose credentials or operational endpoints and does not provide a bypass instruction. The existing unauthenticated controller-state trust boundary remains pre-existing and is explicitly documented rather than widened by this task.

The test-harness addition of `sys.dont_write_bytecode = True` is legitimate fixture isolation: it prevents the growth-driver subprocess from creating bytecode cache entries and changing the fixture's measured scope. It does not change production [`taskctl.py`](../../tools/task_controller/taskctl.py) behavior, and real untracked artifacts remain counted by [`changed_files()`](../../tools/task_controller/taskctl.py:342).

## Evidence

Independently verified:

- MCP health and compact delivery context for the active task.
- Exact `git diff origin/dev --` output for the three changed paths.
- Prior security report and prior D1/D2 context.
- Call ordering and snapshot binding in [`taskctl.py`](../../tools/task_controller/taskctl.py:361), [`taskctl.py`](../../tools/task_controller/taskctl.py:383), [`taskctl.py`](../../tools/task_controller/taskctl.py:473), [`taskctl.py`](../../tools/task_controller/taskctl.py:521), [`taskctl.py`](../../tools/task_controller/taskctl.py:651), and [`taskctl.py`](../../tools/task_controller/taskctl.py:716).
- Focused changed tests, including the late-growth and warning-once regressions.

Reused from the handoff, prior review, and unchanged evidence:

- `python3 tools/task_controller/test_taskctl.py -v`: 44 tests, OK.
- `git diff --check`: clean.
- Functional approval in [`docs/reviews/P-WF-T05.md`](../../docs/reviews/P-WF-T05.md).
- Persisted authoritative submit evidence for P-WF-T05.

## Accepted residual risks

- The final source read and tracker replacement are not one atomic filesystem operation. Immediate post-persistence drift is detected and repaired; mutation after the final verification remains dependent on worktree control/locking and is outside this task's scope.
- Warning assertions are coupled to stderr wording.
- Untracked non-state artifacts outside isolated fixtures count toward scope by design.
- Controller-owned submit evidence is unauthenticated; this is a pre-existing trust boundary and was not redesigned here.
- Controller state remains intentionally uncommitted until release.

No residual risk is release-affecting for this task. The required controller verdict is `clear`.
