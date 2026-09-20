# Security Review: P-CH04.5-T05

- **Stage:** security-review
- **Reviewer:** `platforminit-owasp-reviewer`
- **Task:** `P-CH04.5-T05 — Create CH04.5 focused validation and recovery checkpoint`
- **Branch:** `batch/platform-ch04-5-validation-recovery`
- **Verdict:** CLEAR

## Scope and evidence

Reviewed only the controller-confirmed changed paths:

- [`platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh`](../../platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh:1)
- [`platform/identity/validate/ch04-5-validate-focused.sh`](../../platform/identity/validate/ch04-5-validate-focused.sh:1)
- [`platform/identity/docs/ch04-5-identity-recovery-and-break-glass.md`](../../platform/identity/docs/ch04-5-identity-recovery-and-break-glass.md:1)

Directly required trust-boundary sources were considered only through the changed validator assertions and the supplied identity consumer evidence. No product files were modified.

Evidence reviewed:

- [`/tmp/platforminit-evidence/P-CH04.5-T05-fail-closed-negative.log`](/tmp/platforminit-evidence/P-CH04.5-T05-fail-closed-negative.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-focused-static-rework.log`](/tmp/platforminit-evidence/P-CH04.5-T05-focused-static-rework.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-cross-consumer-rework.log`](/tmp/platforminit-evidence/P-CH04.5-T05-cross-consumer-rework.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-ch05-static-consumer-rework.log`](/tmp/platforminit-evidence/P-CH04.5-T05-ch05-static-consumer-rework.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-focused-static.log`](/tmp/platforminit-evidence/P-CH04.5-T05-focused-static.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-cross-consumer.log`](/tmp/platforminit-evidence/P-CH04.5-T05-cross-consumer.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-ch05-static-consumer.log`](/tmp/platforminit-evidence/P-CH04.5-T05-ch05-static-consumer.log)
- [`/tmp/platforminit-evidence/P-CH04.5-T05-focused-list.log`](/tmp/platforminit-evidence/P-CH04.5-T05-focused-list.log)
- [`docs/reviews/P-CH04.5-T05.md`](../reviews/P-CH04.5-T05.md:1)
- [`docs/security-reviews/P-CH04.5-T04B.md`](P-CH04.5-T04B.md:1)

## Review checks

- MCP health and delivery-context reload confirmed task `P-CH04.5-T05` at `needs_security_review`, with exactly three changed paths and the bounded target budget.
- Changed files contain only credential and secret names, not secret values, tokens, kubeconfigs, credentials, encoded blobs, personal data, tenant identifiers, internal IPs, or operator PII.
- The break-glass document explicitly says values must never be printed/copied and keeps local recovery access until SSO is proven. It places all mutation behind an explicit human-approval gate, including Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, and GitHub environments.
- The cross-consumer validator asserts the CH04.6 admin group resolves to a non-superuser group, exactly one Argo CD admin mapping exists, the CH05 canonical operations group is non-superuser, and exactly one `application:operations` group is formalized. It rejects retired identities and competing CH05 group writers.
- Static validation is repository-only and does not invoke runtime tools. Runtime mode is explicit opt-in and fails closed when `kubectl`, the configured kubeconfig, cluster read access, or the identity namespace is unavailable. No infrastructure workflow or mutation command is triggered by the changed paths.
- Checker integrity is fail-closed: non-zero checker exit, empty output, or fewer than 18 verdict lines causes failure. The supplied negative evidence records N1-N5 failure propagation, including hard checker failure, silent output, truncated output, and focused-entrypoint propagation.
- Supplied positive evidence records focused static success, cross-consumer success, CH05 static consumer-boundary success, and focused inventory listing. No new workflow permission, outbound network dependency, vendor lock-in, or required secret was introduced.

## Consolidated findings by severity

### Critical / High: none

No critical or high security, privacy, release-safety, or privilege-boundary finding was identified in the bounded change.

### Medium: none

The validators are read-only in static mode, runtime checks are opt-in and read-only, and the recovery procedures do not provide an automatic privilege-escalation shortcut. The `upsert-no-prune` stale-group behavior is documented as an operator-reviewed cleanup risk rather than silently automated deletion.

### Low / Informational: none requiring rework

The unresolved risks are appropriately retained as scope facts: runtime health remains unproven without approved cluster read access; stale look-alike groups may require separately reviewed manual removal; CH04.6 retains its own write path; retired-identity protection is location-scoped; and the related fail-open class outside this task remains a follow-up candidate.

## Residual risks accepted for this bounded task

1. Runtime health is not established by repository-only evidence; `--runtime` requires read-only cluster access and human approval.
2. `upsert-no-prune` does not delete stale groups or memberships; manual cleanup requires separate review and approval to avoid accidental lockout or data loss.
3. CH04.6 still has its own `ensure_authentik_group` write path, outside this task's changed scope.
4. Retired-identity guards remain limited to the focused consumer paths.
5. The related validator issue at `ch04-5-validate-identity-model-contract.sh:129` is outside the changed scope and remains a follow-up candidate.

## Verdict rationale

The bounded change establishes a closed focused validation entrypoint, preserves repository-only static behavior, gates runtime checks behind explicit opt-in and read access, and adds effective fail-closed protection against checker failure, silence, and truncation. Secret handling is name-only, the recovery document includes an explicit human-approval mutation boundary, and the cross-consumer checks preserve non-superuser and single-admin-group semantics. Verdict: **CLEAR**.
