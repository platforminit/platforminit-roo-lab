# P-WF-T14 correctness and integration review

- **Task:** P-WF-T14 — Define the continuous project memory lifecycle
- **Stage:** review round 2
- **Reviewer:** `platforminit-openai-reviewer`
- **Branch/source reviewed:** `feat/p-wf-t14-project-memory-lifecycle` at `cfa35ef`
- **Changed scope:** [`tools/platforminit_mcp/memory.py`](../../tools/platforminit_mcp/memory.py:1), [`.roo/rules-platforminit-release-manager/rules.md`](../../.roo/rules-platforminit-release-manager/rules.md:1), [`docs/roo-lab/RAG_FUTURE.md`](../roo-lab/RAG_FUTURE.md:1)
- **Verdict:** **APPROVE**

## Review result

No correctness, integration, regression, idempotence, workflow-UX, scope, or acceptance-criteria blocker was found in the current three-file scope. The rework addresses the four round-one security findings without broadening controller authority or adding runtime infrastructure behavior.

## Validation evidence

- `python3 -m py_compile tools/platforminit_mcp/memory.py` — PASS.
- `git diff --check` — PASS.
- `python3 tools/platforminit_mcp/memory.py contract-check` — PASS, 19/19 checks.
- The contract gate covers quarantine/retrieval, controller and evidence binding, actor binding, distilled-summary rejection, and path-safety checks. The existing focused unittest harness was not changed or rerun because it is outside the task's allowed files; this is an accepted task-scope limitation, not a claim that the harness was extended.
- Shipped-corpus audit in [`memory.py`](../../tools/platforminit_mcp/memory.py:935) reports two provenance-less project rows quarantined, and retrieval over the shipped corpus returns no project rows. Framework retrieval remains available, so the compatibility policy does not silently empty legitimate framework context.
- A live emission attempt while the controller task was `in_progress` was refused by the controller-status binding; no candidate file was written.

## Acceptance criteria

1. **Emission window — satisfied.** Release guidance permits emission only after `ready_to_close` with OpenAI `approve` and OWASP `clear` and from committed evidence ([`rules.md`](../../.roo/rules-platforminit-release-manager/rules.md:55)). Code rechecks controller status/verdicts, required controller report citations, source commit resolution, evidence existence at that commit, and emitter attribution ([`memory.py`](../../tools/platforminit_mcp/memory.py:462)). Promotion rechecks the same bindings ([`memory.py`](../../tools/platforminit_mcp/memory.py:743)).
2. **Provenance/schema/dedup/advisory semantics — satisfied.** Candidate validation requires provenance and approved evidence paths ([`memory.py`](../../tools/platforminit_mcp/memory.py:594)); normalized duplicate content, duplicate IDs, and per-task bounds are refused ([`memory.py`](../../tools/platforminit_mcp/memory.py:706)); promotion is explicit and candidate status is not retrieval-visible ([`memory.py`](../../tools/platforminit_mcp/memory.py:743)). Advisory envelopes retain `tasks/tracker.json` as authority ([`memory.py`](../../tools/platforminit_mcp/memory.py:650)).
3. **No raw logs/secrets and no unpromoted retrieval — satisfied.** Distilled summaries reject multiline/control/raw log and transient-path patterns ([`memory.py`](../../tools/platforminit_mcp/memory.py:189)); unsafe paths and secret-looking values are rejected ([`memory.py`](../../tools/platforminit_mcp/memory.py:205)); candidate storage is absent from retrieval, which loads only framework memory and promoted records ([`memory.py`](../../tools/platforminit_mcp/memory.py:967)). Provenance-less legacy project rows outside the approved evidence compatibility window are quarantined and observable through `quarantine-report` ([`memory.py`](../../tools/platforminit_mcp/memory.py:935)).
4. **Future distillation compatibility and authority boundary — satisfied.** The later `evidence-distillation` emitter uses the same candidate/provenance/promotion seam, while memory remains advisory and cannot write task state ([`RAG_FUTURE.md`](../roo-lab/RAG_FUTURE.md:107)). `memoryVersion: 2` is documented as an unchanged response-key contract with optional provenance on promoted records ([`RAG_FUTURE.md`](../roo-lab/RAG_FUTURE.md:97)); this is an honest observable-contract note, not an over-claim of API-version compatibility.

## F1–F4 disposition

- **F1:** Resolved coherently. Legacy project rows without acceptable provenance are excluded from ranking but remain in the full corpus for supersession-graph integrity; quarantine is reported rather than hidden. The shipped corpus result confirms only framework rows are returned.
- **F2:** Resolved for the repository-local trust model. Controller/evidence/actor bindings are enforced at both staging and promotion and are covered by the 19-check gate.
- **F3:** Resolved for the stated bounded input contract. Raw run-output patterns and oversized provenanced summaries fail closed; distilled prose is accepted.
- **F4:** Resolved as documented defense-in-depth. Lexical path filtering is strengthened and correctly not represented as complete source authentication.

## Non-blocking residual risks

- The emitter check is attribution, not process authentication; this is explicitly documented in [`rules.md`](../../.roo/rules-platforminit-release-manager/rules.md:95).
- Commit binding proves cited evidence exists at the cited commit, not that the controller stores the exact reviewer-approved revision; this is explicitly documented ([`RAG_FUTURE.md`](../roo-lab/RAG_FUTURE.md:102)).
- Real staging/promotion with a fully approved task was not exercised; the negative live probe and fixture coverage demonstrate the refusal and binding paths, while release-time emission remains a separate reviewed source change.
- `memoryVersion` remains 2 despite the provenance-gated behavior change; the documentation honestly records unchanged response keys and optional provenance, so this is an observable consumer consideration rather than a review blocker.
- The shipped unittest harness and legacy `memory/**` migration remain deferred outside this task's allowed scope. Current retrieval quarantine makes the legacy state safe by default.

## Controller transition

The required review transition is recorded once with verdict `approve` using `taskctl review`. The controller result is reported with the completion handoff.
