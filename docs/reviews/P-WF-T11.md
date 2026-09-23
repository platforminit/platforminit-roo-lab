# P-WF-T11 Review — Harden project memory relevance ranking

## Verdict

**APPROVE**

The bounded patch satisfies the acceptance criteria and remains within the two-file changed scope. No correctness, integration, regression, idempotence, or workflow-UX defects were found.

## Scope and evidence

- Branch: `feat/p-wf-t11-memory-ranking`
- Reviewed product files: [`tools/platforminit_mcp/memory.py`](../../tools/platforminit_mcp/memory.py), [`tools/platforminit_mcp/test_memory.py`](../../tools/platforminit_mcp/test_memory.py)
- The controller-reported changed scope contains exactly those two files; the pre-existing generated task-view/tracker modifications were not treated as part of this patch.
- Focused validation passed: `python3 -m unittest tools.platforminit_mcp.test_memory -v` — 10 tests passed.
- Formatting validation passed: `git diff --check` — clean.
- Implementation evidence log: `/tmp/platforminit-evidence/P-WF-T11-memory-ranking.log`

## Acceptance criteria

### 1. Project bonus cannot make zero-overlap records eligible — PASS

[`get_relevant_memory()`](../../tools/platforminit_mcp/memory.py:203) computes relevance separately from the project-scope bonus. For a non-empty token set it selects only records with `relevance > 0` at [`memory.py:233-236`](../../tools/platforminit_mcp/memory.py:233). The project bonus is used only in the ordering key at [`memory.py:228`](../../tools/platforminit_mcp/memory.py:228), so a project record with no lexical, task, or component match cannot enter the result even at the hard cap.

The focused regression test [`test_irrelevant_project_record_is_not_eligible_for_non_empty_query()`](../../tools/platforminit_mcp/test_memory.py:200) verifies both exclusion of an unrelated project record and retention of matching framework/project records.

### 2. Exact matches and lexical overlap are deterministic and bounded — PASS

[`_relevance_and_scope_bonus()`](../../tools/platforminit_mcp/memory.py:182) gives lexical overlap and exact task/component matches explicit bounded weights, while returning the project signal separately. Active records are ranked with a complete deterministic key (relevance, project tie-break, scope, and record ID) at [`memory.py:228`](../../tools/platforminit_mcp/memory.py:228). Exact task/component matching remains independent of summary overlap, as covered by [`test_exact_task_and_component_matches_stay_lexical_independent()`](../../tools/platforminit_mcp/test_memory.py:258).

The project bonus remains an ordering-only tie-break as intended; [`test_equal_relevance_records_are_tie_broken_deterministically()`](../../tools/platforminit_mcp/test_memory.py:237) verifies repeatability, project preference for equal relevance, and ID stabilization.

### 3. Focused coverage — PASS

The added tests cover all requested dimensions:

- irrelevant project records and project tie-breaking: [`test_irrelevant_project_record_is_not_eligible_for_non_empty_query()`](../../tools/platforminit_mcp/test_memory.py:200);
- deterministic tie-breaking: [`test_equal_relevance_records_are_tie_broken_deterministically()`](../../tools/platforminit_mcp/test_memory.py:237);
- empty-query active baseline and bounded output: [`test_empty_query_baseline_is_bounded_and_active_only()`](../../tools/platforminit_mcp/test_memory.py:286) and [`test_empty_query_returns_small_active_baseline()`](../../tools/platforminit_mcp/test_memory.py:131);
- default, requested, and hard maximum limits: [`test_max_items_limit_and_hard_cap_are_enforced()`](../../tools/platforminit_mcp/test_memory.py:325).

## Explicit risk assessment

- `TOKEN_RE` adjacency behavior is unchanged. Sentence-final punctuation can remain attached to a token, so `merge.` does not match bare `merge`; this is a pre-existing lexical-tokenization limitation and is outside this ranking hardening scope. It is documented as an unresolved, non-regressing risk rather than a release blocker.
- A non-empty query can now correctly return zero items. The retrieval response remains structurally stable (`itemCount` plus `items`), and no downstream consumer was found in the bounded tools search that assumes a non-empty result. The behavior is appropriate for an advisory retrieval API and is covered by the eligibility logic; no defect found.
- The project-scope bonus is retained only as a deterministic tie-break, with eligibility still controlled by positive relevance. This matches the acceptance criteria and avoids unnecessary behavior loss.

## Integration and lifecycle checks

- No product/source files were modified by this review.
- No secrets, destructive operations, infrastructure workflows, or competing task-state sources are introduced.
- The implementation is read-only on retrieval and preserves `tasks/tracker.json` as authoritative, as stated by the module contract.
- Review verdict is recorded through the controller after this report is written.
