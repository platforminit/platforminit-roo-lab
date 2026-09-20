# Review: P-CH04.5-T05

- **Review round:** re-review after rework
- **Verdict:** approve
- **Resulting controller status:** `needs_security_review`
- **Scope reviewed:** the three controller-listed product files only; controller-owned task-state modifications were excluded from the product-scope judgment.
- **Branch:** `batch/platform-ch04-5-validation-recovery`

## Consolidated findings

No blocking or non-blocking defects found in the reworked three-file scope.

The previous blocking fail-open path is corrected. In [`ch04-5-validate-identity-cross-consumer.sh`](../../platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh:99), the embedded checker is invoked without an executable `|| true` suppression; its status is captured by `cross_rc`. The integrity gate at [`CHECKER_EXIT`](../../platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh:422), [`CHECKER_EMPTY`](../../platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh:424), and [`CHECKER_TRUNCATED`](../../platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh:426) increments `FAIL` before [`summary_exit()`](../../platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh:61), so abnormal, empty, or partial checker output cannot reach a clean exit. The only remaining `|| true` text is explanatory comment text, not shell control flow.

## Acceptance criteria

1. **Focused repository contract and runtime health signals — satisfied with runtime boundary explicit.** [`ch04-5-validate-focused.sh`](../../platform/identity/validate/ch04-5-validate-focused.sh:49) has a closed static/runtime inventory. Static mode covers the identity model, Authentik ingress/TLS, and cross-consumer contracts. Runtime mode explicitly lists and checks expected namespace, rollout, image, ingress/TLS, bootstrap API, group, and membership health signals, while requiring read-only cluster access. Runtime health remains unproven in this stage because `--runtime` requires approved cluster access; the documentation correctly says repository-only evidence must not be presented as runtime proof.
2. **Cross-consumer agreement and retired-identity rejection — satisfied.** The reworked checker validates CH04.5 agreement with the active CH04.6 Argo CD and CH05 Checkmk consumers, lookup-only/ownership boundaries, bootstrap references, and retired active identities. Positive evidence reports `27/0/0`, `18` checker verdict lines, and focused `passed=3 failed=0`.
3. **Break-glass and recovery prerequisites — satisfied.** [`ch04-5-identity-recovery-and-break-glass.md`](../../platform/identity/docs/ch04-5-identity-recovery-and-break-glass.md:14) names credential sources without secret values, preserves local application recovery, defines read-only prerequisites and explicit mutation approval, records checkpoint fields, documents ordering and stale look-alike recovery, and distinguishes static from runtime proof.
4. **No unrelated full-repository checks — satisfied.** The focused entrypoint allowlists only the declared CH04.5 validators plus the explicitly included CH05 consumer boundary, rejects unsupported arguments and non-allowlisted steps, and does not invoke repository-wide validation. `--list` is non-executing.

## Fail-closed re-review evidence

The supplied negative evidence demonstrates the corrected path:

- **N1:** injected checker exit 3 produced `CHECKER_EXIT`, standalone exit `1`.
- **N2:** injected empty output produced `CHECKER_EMPTY`, standalone exit `1`.
- **N3:** injected two-line output produced `CHECKER_TRUNCATED` against the `MIN_CROSS_CHECKS=18` floor, standalone exit `1`.
- **N4:** focused entrypoint propagated the injected checker failure and reported `passed=2 failed=1`, exit `1`.
- **N5:** positive control reported `passed=3 failed=0`, exit `0`.

The positive re-runs also report cross-consumer `pass=27 warn=0 fail=0`, `CHECKER_INTEGRITY` with `18` verdict lines, and seven PASS results for the CH05 static consumer boundary. Both changed shell scripts pass `bash -n`. Direct inspection confirms the only `|| true` occurrences are explanatory comments at lines 26 and 95; no suppression remains in the execution path.

## Scope, integration, and operator review

- Scope is within the controller budget: exactly three product files, all within allowed paths. The working tree also contains controller-owned task-state changes and the review report; those were not treated as product scope.
- The scripts are read-only and repository-only in static mode, use strict shell settings, and do not expose secret values or perform infrastructure mutation. Runtime mode is opt-in and guarded by `kubectl`, kubeconfig, namespace, and read-access checks.
- The `upsert-no-prune` stale-group behavior, CH04.6's separate `ensure_authentik_group` write path, focused retired-identity guard, absent workflow wiring, and unproven runtime signals remain documented boundaries/risks rather than blockers for this task.

## Explicit follow-up candidate

The same previously observed fail-open class remains at [`ch04-5-validate-identity-model-contract.sh`](../../platform/identity/validate/ch04-5-validate-identity-model-contract.sh:129). That validator is outside this task's controller-listed changed scope and was deliberately not modified; it is an explicit follow-up candidate for a separate task, not a blocker for P-CH04.5-T05 acceptance.

## Evidence paths

- `/tmp/platforminit-evidence/P-CH04.5-T05-fail-closed-negative.log`
- `/tmp/platforminit-evidence/P-CH04.5-T05-focused-static-rework.log`
- `/tmp/platforminit-evidence/P-CH04.5-T05-cross-consumer-rework.log`
- `/tmp/platforminit-evidence/P-CH04.5-T05-ch05-static-consumer-rework.log`
- Prior passing evidence reused: `P-CH04.5-T05-focused-static.log`, `P-CH04.5-T05-cross-consumer.log`, `P-CH04.5-T05-ch05-static-consumer.log`, `P-CH04.5-T05-focused-list.log`

## Required controller transition

```bash
python3 tools/task_controller/taskctl.py review P-CH04.5-T05 --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/P-CH04.5-T05.md
```
