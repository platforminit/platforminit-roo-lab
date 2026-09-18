# Review: P-WF-T05 — Enforce micro-task sizing

## Verdict

**APPROVE**

Independent changed-files-only re-review, third review pass. The implementation satisfies the sizing contract and closes D2 without regressing D1.

## Scope reviewed

Changed paths reviewed against `origin/dev`:

- `tools/task_controller/taskctl.py`
- `tools/task_controller/test_taskctl.py`
- `docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`

No product code, tests, tracker state, or generated task views were modified by this review. This report is the only review artifact written.

## Findings

No release-blocking findings.

### Acceptance criteria

1. **1–3 primary product files:** satisfied. The target is represented by `TASK_SIZE_TARGET = 3`; the gate applies to the non-state changed-file snapshot.
2. **4–5 files:** satisfied. `require_task_size()` emits `TASK_SIZE_WARNING` only when requested, remains non-blocking, and the authoritative submit/complete gate emits it once per command.
3. **More than 5 files:** satisfied. The unconditional hard branch raises `TASK_TOO_LARGE_SPLIT_REQUIRED`; submit and complete gate the final/authoritative snapshot before persistence.

### D2: warning-band growth and duplicate warnings

**Closed.** `submit` uses a silent provisional gate before validators and always re-gates the post-validator snapshot with warnings enabled. A 4-file scope growing to 5 is warned once, for 5 files, and persisted evidence uses that final snapshot.

`complete` follows the same pattern. The reused-evidence path warns at the confirmed snapshot; the rerun path warns at the fresh post-validator snapshot. The provisional gate is silent, and focused tests assert exactly one warning for submit growth and complete rerun behavior. No reviewed submit or complete path can emit a second warning from the provisional gate.

The unchanged-scope always-re-gate is intentional: the warning describes the snapshot fingerprinted and persisted rather than relying on a conditional shortcut. The extra gate is bounded validation work and does not alter final scope semantics.

### D1: snapshot binding and hard-block behavior

**Preserved.** `change_snapshot()` returns one file list and a fingerprint computed from exactly that list. The allowed-scope and size helpers consume the caller-provided list; neither re-gathers it. Submit fingerprints and persists the post-validator list only after that same list passes the authoritative gate. Complete likewise gates the list used for reuse confirmation or the rerun persistence record. A late file cannot be fingerprinted or persisted without being included in the gate decision.

The hard block remains unconditional when warning emission is disabled. Provisional submit/complete gates still fail fast above five, and authoritative final gates reject a scope growing above five during validators or completion processing. Existing D1 regression coverage passed.

### Tests and harness

The new tests are genuine integration-style subprocess regression guards: they exercise the command entry point, temporary Git repository, tracker transitions, validator execution, stderr, persisted evidence, and final status. They verify warning cardinality, final count, fingerprint/evidence alignment, and late-growth hard blocking rather than merely calling a helper.

`sys.dont_write_bytecode = True` is defensible test isolation in the growth driver. The driver dynamically imports the production module inside the temporary fixture; suppressing import bytecode prevents the harness from creating an unrelated generated non-state file and invalidating the intended file-count interleaving. This does not mask production scope detection: real untracked generated artifacts remain counted outside the controlled fixture, consistent with the documented residual risk.

## Evidence

Independently verified:

- WSL/runtime and repository identity checks passed: workspace is `/mnt/d/SYSADMIN/platforminit-roo-lab`, WSL detected, user `hattila`, branch `chore/p-wf-t05-workflow`.
- Changed-file diff against `origin/dev` reviewed for all three handoff paths.
- `python3 tools/task_controller/test_taskctl.py -v`: **44 tests, OK**.
- `git diff --check`: clean.
- Source inspection of submit/complete gating, snapshot/fingerprint functions, new D2/D1 tests, and documentation.

Reused from the handoff as authoritative or unchanged evidence:

- Persisted submit evidence for P-WF-T05.
- Security review `docs/security-reviews/P-WF-T05.md` confirming D1 closure.
- Prior review report and prior D2 request-changes context.

## Residual risks accepted

- Non-atomic source window between final gather and tracker write remains documented and is outside this task's locking scope.
- Untracked generated non-state artifacts count outside the isolated fixture.
- Warning tests couple to `TASK_SIZE_WARNING` and count wording.
- Controller-written submit evidence remains unauthenticated by design.
- Controller state remains uncommitted until release.
- The hard-threshold constant rename has no stale in-repository references found in the reviewed scope.

## Controller transition

```text
python3 tools/task_controller/taskctl.py review P-WF-T05 --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/P-WF-T05.md
```
