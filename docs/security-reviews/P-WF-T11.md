# P-WF-T11 Security Review — Harden project memory relevance ranking

## Verdict

**CLEAR**

The bounded change does not introduce a security or privacy regression. The project-scope bonus is ordering-only, while non-empty queries require positive lexical, task, or component relevance. This prevents an unrelated project record from being exposed merely because it is project-scoped.

## Scope and evidence

- Task: `P-WF-T11`; branch: `feat/p-wf-t11-memory-ranking`.
- Reviewed changed files: [`tools/platforminit_mcp/memory.py`](../../tools/platforminit_mcp/memory.py) and [`tools/platforminit_mcp/test_memory.py`](../../tools/platforminit_mcp/test_memory.py).
- Prior correctness report: [`docs/reviews/P-WF-T11.md`](../reviews/P-WF-T11.md), APPROVE.
- Focused evidence: `/tmp/platforminit-evidence/P-WF-T11-memory-ranking.log`.
- Controller-reported scope contains only the two product/test files; generated task views and tracker changes were excluded from this review scope.

## Security and privacy assessment

### Project/scope isolation — PASS

[`get_relevant_memory()`](../../tools/platforminit_mcp/memory.py:203) computes relevance independently from the project-scope bonus. For a non-empty token set, selection at [`memory.py:233-234`](../../tools/platforminit_mcp/memory.py:233) requires `relevance > 0`; the project bonus is used only by the deterministic ordering key at [`memory.py:228`](../../tools/platforminit_mcp/memory.py:228). Therefore a zero-overlap project record cannot displace or leak into an unrelated query result solely due to project scope.

The focused regression coverage in [`test_irrelevant_project_record_is_not_eligible_for_non_empty_query()`](../../tools/platforminit_mcp/test_memory.py:200) verifies exclusion of an unrelated project record while retaining matching framework and project records. Exact task/component matches remain explicit relevance signals, so a record can be returned when the caller supplies a matching identity even without summary-word overlap; this is intended behavior, not scope-bonus leakage.

The empty-query behavior is intentionally different: it returns a bounded active baseline across both scopes. This is a documented baseline, not a non-empty query isolation bypass, and is capped by `maxItems`.

### Secret exposure and output content — PASS

The changed ranking logic only reads validated JSONL fields already used by the memory layer and returns normalized records. No secret source, environment variable, credential lookup, or new logging path was added. The implementation does not print query text or record contents during retrieval. Existing record validation bounds summaries, tags, sources, identifiers, and other fields before return; unsupported fields are rejected rather than surfaced.

### Query tokenization and injection surface — PASS with residual behavior

[`TOKEN_RE`](../../tools/platforminit_mcp/memory.py:46) is a fixed regular expression used for lexical token extraction, not dynamic pattern construction or evaluation. Query, task, and component inputs are type- and length-validated before tokenization at [`memory.py:210-219`](../../tools/platforminit_mcp/memory.py:210). No shell, SQL, template, or code-evaluation sink is involved, so query text cannot introduce command or expression injection through this change.

The known adjacency behavior is unchanged: punctuation characters included by [`TOKEN_RE`](../../tools/platforminit_mcp/memory.py:46) can remain attached to a token, so a sentence-final `merge.` may not match bare `merge`. This is a pre-existing recall limitation, not a confidentiality or injection issue, and is outside this task.

### Bounded retrieval and denial-of-service exposure — PASS

`maxItems` is normalized and clamped to [`HARD_MAX_ITEMS`](../../tools/platforminit_mcp/memory.py:32) by [`validate_max_items()`](../../tools/platforminit_mcp/memory.py:64). Both non-empty selection and empty-query baseline apply the limit at [`memory.py:234-236`](../../tools/platforminit_mcp/memory.py:234), so callers cannot request an unbounded result set. Query length is capped at [`MAX_QUERY_LENGTH`](../../tools/platforminit_mcp/memory.py:34), and record field/list bounds are enforced during validation.

Focused evidence reports all 10 memory tests passing, including irrelevant-record exclusion, deterministic ties, empty-query baseline, input bounds, and default/requested/hard maximum enforcement. `git diff --check` also passed.

## Findings

No security, privacy, release, or scope-isolation findings requiring remediation were identified.

## Residual risks

1. Token adjacency can reduce lexical recall for punctuation-adjacent words; unchanged and non-security-impacting.
2. A non-empty query can legitimately return zero items when no record has lexical or exact task/component relevance; this is the intended fail-closed exposure behavior.
3. Empty-query retrieval still exposes a small cross-scope active baseline by design, but it remains bounded and does not claim project-only isolation.

## Controller decision

Security verdict: **CLEAR**. The verdict is recorded through `taskctl security` after this report is written. The next lifecycle transition is owned by the orchestrator and is release routing, not performed by this reviewer.
