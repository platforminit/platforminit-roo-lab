# P-WF-T12 OpenAI Review

- **Task:** P-WF-T12 — Implement deterministic memory supersession
- **Stage:** review
- **Branch:** `feat/p-wf-t12-memory-supersession`
- **Base:** `dev`
- **Verdict:** APPROVE

## Scope and lifecycle

The implementation diff against `dev` contains only the two claimed product/test paths:

- [`tools/platforminit_mcp/memory.py`](../../tools/platforminit_mcp/memory.py)
- [`tools/platforminit_mcp/test_memory.py`](../../tools/platforminit_mcp/test_memory.py)

The working tree also contains the expected controller-generated `tasks/**` changes; no foreign product paths were found. No infrastructure workflow, runtime, secret, GitHub environment, or destructive operation was used or changed. The review is limited to the bounded platform-only scope.

## Acceptance review

1. **Suppression before ranking — satisfied.** [`get_relevant_memory()`](../../tools/platforminit_mcp/memory.py:310) loads both scopes, computes suppression at line 327, and filters suppressed IDs at line 332 before relevance ranking and before both the non-empty-query and empty-query selection paths. [`test_active_replacement_suppresses_superseded_record_before_ranking()`](../../tools/platforminit_mcp/test_memory.py:354) verifies query retrieval, bounded empty-query retrieval, and that the stored obsolete record remains active data rather than being returned.
2. **Deterministic chains and fail-closed malformed graphs — satisfied.** [`_supersession_graph()`](../../tools/platforminit_mcp/memory.py:226) rejects duplicate IDs and canonicalizes adjacency. [`_assert_supersession_integrity()`](../../tools/platforminit_mcp/memory.py:248) rejects dangling/self edges and detects cycles with deterministic traversal. [`superseded_record_ids()`](../../tools/platforminit_mcp/memory.py:284) follows the transitive closure from active records. [`test_supersession_chains_are_transitive_and_deterministic()`](../../tools/platforminit_mcp/test_memory.py:385), [`test_supersession_cycle_fails_closed()`](../../tools/platforminit_mcp/test_memory.py:424), and [`test_malformed_self_supersession_and_dangling_targets_fail_closed()`](../../tools/platforminit_mcp/test_memory.py:447) cover these behaviors.
3. **Bounded retrieval and historical/deprecated context — satisfied.** [`test_non_active_replacements_never_suppress_active_memory()`](../../tools/platforminit_mcp/test_memory.py:495) proves non-active records do not suppress an active record and remain loadable as stored non-active context. The existing bounded, empty-query, tie-break, task/component, and hard-cap tests remain passing.

## Validation independently run

- `python3 -m unittest tools.platforminit_mcp.test_memory -v` — **17 tests OK**, including the 10 pre-existing P-WF-T11 tests and the new supersession coverage. Evidence: `/tmp/platforminit-evidence/P-WF-T12-review-unittest.log`.
- `git diff --check` — **pass**, no output. Evidence: `/tmp/platforminit-evidence/P-WF-T12-review-diffcheck.log`.
- Real corpus retrieval smoke — **pass**, 3 active items returned and no non-active status. Evidence: `/tmp/platforminit-evidence/P-WF-T12-review-corpus-smoke.log`.
- Changed-path check against `dev` — product diff restricted to the two allowed paths; controller state is under `tasks/**`.

## Integration and regression assessment

- The response schema remains `memoryVersion: 1`; this is a semantics-only change and does not alter the MCP response shape.
- Existing consumers of [`get_relevant_memory()`](../../tools/platforminit_mcp/memory.py:310) continue to receive the same bounded advisory response and active-only items, with invalid supersession data now failing closed as intended.
- [`append_project_record()`](../../tools/platforminit_mcp/memory.py:357) validates targets before writing and preserves append-only behavior. The focused test confirms unknown targets are not persisted and valid existing targets are accepted.
- Ranking order remains deterministic through the existing relevance/scope/id sort; suppression is applied before ranking, including max-item bounds and empty-query baseline behavior.
- No idempotence regression was found in the append path: duplicate project IDs remain rejected and failed unknown-target validation occurs before file creation/write.

## Remaining bounded risks

- A dangling or cyclic `supersedes` edge already present in either memory JSONL file makes the complete retrieval fail closed. This is consistent with the required malformed-graph behavior, but it is an operational availability risk until the corpus is repaired.
- Cross-scope duplicate IDs now fail closed because suppression would otherwise be ambiguous. This is a deliberate integrity guard and is covered by [`test_duplicate_across_scope_ids_fail_closed()`](../../tools/platforminit_mcp/test_memory.py:535); any future contract that permits duplicate IDs would require an explicit identity rule.
- Integrity validation covers the full declared graph, including edges declared by non-active records. This is stricter than only traversing active edges, but it preserves deterministic corpus integrity and is consistent with the fail-closed invariant.
- The focused tests establish deterministic behavior for synthetic corpora and the current real corpus; they do not constitute a general performance benchmark for very large memory corpora. The existing bounded output cap remains enforced.

No merge-blocking correctness, integration, regression, scope, or acceptance gap was found. APPROVE.
