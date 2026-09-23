# P-WF-T12 OWASP Security Review

- **Task:** P-WF-T12 — Implement deterministic memory supersession
- **Stage:** security-review
- **Branch:** `feat/p-wf-t12-memory-supersession`
- **Scope:** [`tools/platforminit_mcp/memory.py`](../../tools/platforminit_mcp/memory.py) and [`tools/platforminit_mcp/test_memory.py`](../../tools/platforminit_mcp/test_memory.py)
- **Verdict:** CLEAR

## Review conclusion

CLEAR. The change is limited to advisory, repository-local memory parsing and retrieval. It does not touch infrastructure workflows, runtime configuration, secrets, RBAC, GitHub environments, authentication, authorization, TLS, DNS, or deployment behavior.

## Security and privacy checks

- **Secret handling and leakage:** No credentials, tokens, private-key material, or secret-bearing test fixtures were added. The focused source/test scan found no tested secret markers. Error responses intentionally collapse malformed JSONL details to the file basename and line number in [`load_jsonl()`](../../tools/platforminit_mcp/memory.py:170), rather than echoing record content. The CLI emits only a generic `ERROR:` plus bounded validation text.
- **Fail-closed behavior:** Record shape, field names, string lengths, ID format, supersession target format, self-targets, dangling targets, duplicate IDs, and cycles are rejected with [`MemoryError`](../../tools/platforminit_mcp/memory.py:58). Retrieval validates the complete combined graph before ranking; malformed input cannot produce partial or stale results. Authoring rejects unknown targets before append in [`append_project_record()`](../../tools/platforminit_mcp/memory.py:357).
- **Untrusted JSONL/path input:** JSON parsing is data-only; there is no dynamic evaluation, shell execution, interpolation into commands, or unsafe deserialization. Retrieval uses fixed repository paths. The CLI add path reads a caller-supplied file as JSON only; it does not use the value as a command or output path.
- **Traversal and denial-of-service:** Each record has a maximum of 12 supersession targets and IDs/fields are bounded. Cycle validation is linear in vertices plus edges using Kahn's algorithm in [`_assert_supersession_integrity()`](../../tools/platforminit_mcp/memory.py:248), and closure uses a visited set in [`superseded_record_ids()`](../../tools/platforminit_mcp/memory.py:284), preventing cyclic infinite traversal. Output remains capped by `HARD_MAX_ITEMS`.
- **Suppression integrity:** Active records suppress transitively before ranking, while historical/deprecated records do not suppress active records. Duplicate cross-scope IDs and malformed graph edges fail closed rather than allowing ambiguous replacement behavior.
- **Tests:** The 17-test focused suite covers suppression-before-ranking, transitive/deterministic chains, cycles, self/dangling/malformed targets, non-active replacement behavior, duplicate cross-scope IDs, and append rejection. Test fixtures contain documentation paths and synthetic facts only; no secret material.

## Evidence

- [`/tmp/platforminit-evidence/P-WF-T12-owasp-unittest.log`](../../../../tmp/platforminit-evidence/P-WF-T12-owasp-unittest.log) — 17 focused tests passed.
- [`/tmp/platforminit-evidence/P-WF-T12-owasp-diffcheck.log`](../../../../tmp/platforminit-evidence/P-WF-T12-owasp-diffcheck.log) — `git diff --check` passed.
- [`/tmp/platforminit-evidence/P-WF-T12-owasp-static.log`](../../../../tmp/platforminit-evidence/P-WF-T12-owasp-static.log) — source/test secret-marker scan clean and scope confirmed.
- [`/tmp/platforminit-evidence/P-WF-T12-review-corpus-smoke.log`](../../../../tmp/platforminit-evidence/P-WF-T12-review-corpus-smoke.log) — previously supplied focused real-corpus retrieval smoke passed.
- [`docs/reviews/P-WF-T12.md`](../reviews/P-WF-T12.md) — correctness review APPROVE and bounded residual-risk assessment.

## Residual risk

1. A pre-existing dangling or cyclic edge in either memory JSONL corpus makes all retrieval fail closed, creating an availability risk until the corpus is repaired. This is the intended security posture and not a fail-open exposure.
2. Cross-scope duplicate IDs and any malformed non-active edge now create a whole-retrieval failure. This is stricter than the prior behavior and should be monitored as an operational data-quality risk.
3. The graph is bounded per record but corpus file size is not globally capped; a maliciously large repository-local corpus could still consume proportionate parsing and graph memory. No new unbounded traversal or infinite-loop path was found, and retrieval output remains capped.
4. No commit or push was performed in this stage; release/branch hygiene remains for the controller-owned release stage.

No security blocker or review-required finding was identified. The response schema remains `memoryVersion: 1`.
