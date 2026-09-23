# P-WF-T14 OWASP security, privacy, and release review

- **Task:** P-WF-T14 — Define the continuous project memory lifecycle
- **Stage:** security-review round 2
- **Reviewer:** `platforminit-owasp-reviewer`
- **Branch/source reviewed:** `feat/p-wf-t14-project-memory-lifecycle` at `cfa35ef`
- **Changed scope:** [`tools/platforminit_mcp/memory.py`](../../tools/platforminit_mcp/memory.py:1), [`.roo/rules-platforminit-release-manager/rules.md`](../../.roo/rules-platforminit-release-manager/rules.md:1), [`docs/roo-lab/RAG_FUTURE.md`](../roo-lab/RAG_FUTURE.md:1)
- **Verdict:** **CLEAR**

## Evidence reviewed

- Fresh MCP delivery context reported `needs_security_review`, exact three-file bounded scope, and the required controller transition.
- The current implementation, release rules, RAG lifecycle documentation, and predecessor report were reviewed independently. The rework is present at `cfa35ef`; the predecessor report records the four round-one findings at `b4b8e85`.
- `python3 tools/platforminit_mcp/memory.py contract-check` passed **19/19** checks.
- `python3 -m py_compile tools/platforminit_mcp/memory.py` passed.
- `git diff --check` passed.
- `quarantine-report` reports two excluded legacy project rows: `project.workflow.zoo-baseline` and `project.memory.precedence`; `retrievalVisible` is false.
- An additional temporary-fixture adversarial probe confirmed refusal for non-approved controller status, forged review/security verdicts, and mismatched emitter actor. No repository or product files were modified by the probe.
- Supplied rework evidence/log paths were treated as supporting evidence only; no secret values were exposed or copied into this report.

## Finding disposition

### F1 — legacy provenance-less rows

**Resolved.** `is_retrieval_eligible()` admits project rows with validated provenance, or the narrowly documented compatibility exception where every cited source is under approved evidence prefixes. Other provenance-less rows are quarantined. Retrieval filters them after full-corpus supersession resolution, and `quarantine-report` exposes the excluded IDs. The shipped corpus confirms two rows are quarantined. The changed rule and RAG documentation explicitly describe the exception and do not claim that every project row is provenance-carrying.

The compatibility exception remains a bounded accepted design choice: it is not equivalent to controller provenance, but its source-prefix condition is enforced and its non-eligible rows are fail-closed.

### F2 — caller-supplied verdict/provenance claims

**Resolved with documented residuals.** Staging and promotion both invoke `assert_emission_bindings()`. The gate binds the task to authoritative `tasks/tracker.json`, requires `ready_to_close` or `done`, recorded `approve` and `clear` verdicts, and requires controller-recorded report paths among cited evidence. `assert_repository_evidence()` requires the source commit to resolve and every cited path to exist at that commit. `_assert_emitter_actor()` rejects an unapproved or mismatched actor. The focused contract gate and adversarial fixture probe verified refusal paths.

Accepted residuals are explicitly documented: the repository-local CLI attributes but does not authenticate the process/emitter, and the controller does not record the reviewer-approved source revision. Commit binding therefore proves existence of cited evidence at the cited commit, not reviewer identity or that the cited revision is the exact revision approved.

### F3 — raw transient output in summaries

**Resolved.** Provenanced records require a single bounded distilled line. The contract rejects multi-line payloads, control/ANSI sequences, shell transcripts, log-level and timestamped lines, tracebacks, diff excerpts, `/tmp/**`, and `*.log` references, while accepting distilled prose and enforcing the 400-character provenanced-summary bound. Secret-looking material is rejected separately.

This is input-pattern protection rather than semantic proof of the author's intent; the accepted residual is limited to the documented pattern-based contract and reviewed emitter boundary.

### F4 — lexical path denylist/source identity

**Resolved as defense-in-depth.** Unsafe and ambiguous paths are rejected lexically, including traversal, absolute paths, transient/log/key/secret locations and URL-ish segments. The implementation and documentation explicitly state that this is not a complete source-safety proof; commit/evidence existence binding is the stronger boundary. Focused checks cover both refused unsafe paths and accepted ordinary reviewed paths.

## Acceptance-criterion assessment

1. **Emission window:** Met. Candidate emission requires controller-approved completed state and both recorded verdicts; staging and promotion are separate from closure and do not write task state.
2. **Provenance/schema/dedup/advisory semantics:** Met. Provenance and evidence are bound to controller and repository state, schema and deduplication are enforced, promotion is explicit/idempotence-protected, and responses remain advisory.
3. **No raw logs/secrets; candidates not retrieved:** Met for the implemented contract. Candidates are excluded from retrieval; promoted project rows are screened for secret-looking content, unsafe paths, and raw-output patterns; legacy rows outside the compatibility exception are quarantined.
4. **Future distillation compatibility without task-state authority:** Met. A later distiller may stage only through the same provenance, screening, deduplication, actor, and promotion gates; task state remains owned by `tasks/tracker.json` and `taskctl`.

## Explicitly accepted residuals

- Provenance-less migration of the two quarantined legacy rows is deferred because `memory/**` is outside this task's allowed files.
- The emitter gate is attributed rather than process-authenticated.
- Source-commit binding does not prove reviewer identity or bind to a controller-recorded reviewed revision.
- Real staging-to-promotion emission remains unexercised outside temporary fixtures; the code path is covered by the 19/19 contract checks and re-binding tests.
- `memoryVersion` remains `2` while retrieval eligibility is strengthened; this is accepted because the response keys remain compatible and the behavior change is documented as a security tightening, not a schema incompatibility.

## Controller transition

This report is intended to be recorded once with verdict `clear`. The resulting controller status should be `ready_to_close`; the next transition is owned by the Release Manager, not this specialist.
