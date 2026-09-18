# Security Review — P-WF-T04

## Verdict

**CLEAR**

The remediation closes the earlier single-field evidence-tampering bypass: reuse is fail-closed for missing, legacy, malformed, partial, unknown-field, timestamp, actor, fingerprint, changed-file-scope, validator-shape, exit-code, and validator-plan mismatches. Completion independently recomputes the source fingerprint and scope before recording confirmation and re-verifies after persistence; detected drift fails loudly and repairs controller state to `ready_to_close` without leaving a stale `done` record.

The remaining limitation is accurately documented: `tasks/tracker.json` evidence is unauthenticated controller state, so an actor with unrestricted write access can forge a fully internally consistent record and cause validator reuse. That is an accepted, explicitly out-of-scope residual risk for this task, with authenticated or append-only evidence identified as a separate follow-up. The tests demonstrate both the fail-closed single-field properties and this limitation without claiming authentication.

## Scope and evidence

Reviewed only the controller-selected changed scope:

- [`tools/task_controller/taskctl.py`](../../tools/task_controller/taskctl.py)
- [`tools/task_controller/test_taskctl.py`](../../tools/task_controller/test_taskctl.py)
- [`docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`](../../docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md)

Entry evidence:

- [`health`](../../.roo/rules-platforminit-owasp-reviewer/rules.md:9): `ok=true`, project `platforminit`, context version `3`.
- [`get_delivery_context`](../../.roo/rules-platforminit-owasp-reviewer/rules.md:9): task `P-WF-T04`, status `needs_security_review`, branch `chore/p-wf-t04-workflow`, exactly three changed paths.
- Environment gate: `WSL_OK`; user `hattila`; branch `chore/p-wf-t04-workflow`.
- Git inspection: configured remote `origin`; no push, infrastructure workflow, runtime, GitHub-environment, or secret mutation performed.
- Reused controller-provided focused evidence: `python3 tools/task_controller/test_taskctl.py` reported `35 tests OK`; prior correctness review verdict was `approve`; unchanged broad checks were not rerun.

## Security assessment

### Evidence reuse and tampering

[`reusable_submit_evidence()`](../../tools/task_controller/taskctl.py:410) rejects unknown or missing fields, unsupported versions, empty timestamps, actor mismatches, fingerprint/scope drift, malformed validator entries, boolean or non-zero exit codes, and validator-plan changes. It recomputes the fingerprint and file scope inside the reuse decision. [`complete`](../../tools/task_controller/taskctl.py:644) performs an additional confirmation immediately before building the completion record, and persists matching `sourceFingerprint`/`changedFiles` and `confirmedFingerprint`/`confirmedFiles`.

The 11 single-field tampering tests use a validator ledger outside the repository, preventing the validator's recording side effect from changing the fingerprint. They assert one execution at submit and two after tampering, demonstrating that the release path reruns rather than silently accepting each tampered field. The explicit fully consistent forged-record test is correctly a documented limitation test: it proves the unauthenticated-state residual remains and does not mislabel it as mitigation.

### Persistence drift and denial/inconsistency behavior

The post-save check recomputes the source fingerprint and scope. If drift is detected, [`complete`](../../tools/task_controller/taskctl.py:699) restores the previous `ready_to_close` status, removes only `workflow.complete`, saves controller-owned state, and exits non-zero. This can deny or delay completion under concurrent source changes, but it cannot leave the task in the attacker-favourable `done` state backed by the stale completion record. A subsequent completion reruns the focused validator, as covered by [`test_source_drift_during_persistence_fails_loud_and_never_records_done()`](../../tools/task_controller/test_taskctl.py:344).

The documentation is honest about the residual TOCTOU window: a source change after the post-persistence read is not detected; source locking or filesystem snapshots would be required for stronger atomicity and are explicitly out of scope. The repair path writes only `tasks/tracker.json` and generated task views through the existing controller save path; no source, secret, runtime, or external environment is modified.

### Done-state and execution safety

The `done` path requires the legal `ready_to_close` state, approved correctness review, clear security review, release actor, branch/scope/task-size checks, and either validated reusable evidence or a fresh `run_validators()` execution. The completion record's confirmation fields are assigned from the same fingerprint/scope values used for the decision and are rechecked after persistence. Validator commands remain argument vectors passed to `subprocess.run`, with no new shell interpolation or workflow-input command construction.

Fingerprinting hashes changed-file content and names only; excluded controller/generated paths are documented. No secrets are printed or copied. Report path validation remains repository-confined. The change adds no cloud/Kubernetes deletion, sudo, identity/header trust, TLS/DNS token, GitHub permission, live-installer, or supply-chain mutation surface.

## Residual risk accepted/out of scope

Authenticated or append-only evidence remains unresolved and is intentionally accepted as a follow-up. The controller cannot cryptographically distinguish a fully consistent forged [`workflow.submit`](../../tools/task_controller/taskctl.py:600) record in controller-owned [`tasks/tracker.json`](../../tools/task_controller/taskctl.py:15) from genuine evidence. This is a trusted-state integrity limitation, not an authentication guarantee; it does not block this task because it is explicitly documented, tested as a limitation, and outside the allowed scope.
