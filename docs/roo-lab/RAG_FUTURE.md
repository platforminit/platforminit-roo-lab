# Future RAG architecture scaffold

This repository is prepared for retrieval-augmented context, but this refactor intentionally does **not** build a production RAG stack.

## Boundary

RAG may enrich agent context; it must never become task state.

Authoritative mutable task state remains:

```text
tasks/tracker.json
```

Generated task views remain controller-owned. Retrieval output is advisory context only.

## Project-memory lifecycle (implemented)

Project memory is the only memory layer with a write path, and it is deliberately two-step. Nothing
enters retrieval-visible memory through a runtime side effect.

| Step | File | Retrieval-visible | Requires provenance |
|---|---|---|---|
| Candidate staging | `memory/project/candidates.jsonl` | no | yes |
| Promotion | `memory/project/records.jsonl` | yes | yes |

### When a completed task may emit memory

Only a completed task that reached `ready_to_close` with an OpenAI `approve` verdict and an OWASP
`clear` verdict may emit bounded candidates, and only from already committed approved evidence. A
candidate is a short reusable lesson with provenance, never a transcript of a run.

### Candidate schema and provenance

A candidate uses the record schema (`id`, `scope`, `type`, `component`, `task`, `summary`, `tags`,
`sources`, `supersedes`) with `status: candidate`, plus a `provenance` object:

| Field | Meaning |
|---|---|
| `taskId` | Completed task id; must match the record `task` |
| `stage` | `release` |
| `sourceCommit` | Reviewed source commit sha |
| `reviewVerdict` | `approve` |
| `securityVerdict` | `clear` |
| `emitter` | `platforminit-release-manager` or `evidence-distillation` |
| `evidencePaths` | Bounded, deduplicated repository-relative paths under approved evidence locations |

Candidate `sources` must also reference approved evidence. Unknown fields, an unapproved emitter, a
non-approving verdict, a malformed commit, an oversized evidence list, a duplicate id, and duplicate
normalized content all fail closed instead of being written.

### Promotion

```bash
python3 tools/platforminit_mcp/memory.py add-candidate <candidate.json>
python3 tools/platforminit_mcp/memory.py list-candidates
python3 tools/platforminit_mcp/memory.py promote <MEMORY-ID>
```

Promotion re-validates the candidate and appends an `active` project record. Both files are
repository-visible JSONL written by reviewed changes, never hidden runtime state, and memory writes
must not be mixed into the controller-owned closure commit.

### Safety and authority boundaries

- Retrieval loads framework memory plus promoted project records only; an unpromoted candidate is
  never returned, not even at the hard cap.
- New project-memory writes now require provenance. Pre-P-WF-T14 records remain readable as legacy
  history, but the candidate path and the CLI require provenance for every new write.
- Raw transient logs, terminal output, `/tmp/**` payloads, absolute paths, `../` traversal, key
  material, `.local_secrets/**`, and secret-looking values or paths are rejected before anything is
  written.
- Promoted memory stays advisory. `tasks/tracker.json` and `taskctl` remain the only authoritative
  delivery state; the lifecycle grants no new authority over task state, branches, allowed files,
  validators, or lifecycle transitions.
- Retrieval advertises `memoryVersion: 2`; the response keys are unchanged, and promoted records may
  additionally carry a `provenance` object.

### Evidence-distillation compatibility

A later evidence-distillation feature may reuse this seam without new authority: it may stage
candidates with `emitter: evidence-distillation`, and every candidate must still pass the same
provenance, deduplication, secret-screening, and explicit promotion gate. Distillation may never write
task state, and unstaged or unpromoted distillation output is not memory.

## Candidate corpus

A future index may include:

- architecture decisions and chapter docs;
- operator runbooks and recovery procedures;
- validation contracts;
- non-secret workflow documentation;
- task evidence and review reports after they become historical;
- deprecated-component records as negative context.

Exclude raw secrets, local secret bootstrap files, generated task dashboards, transient terminal logs, binary artifacts, vendored dependencies, and large generated payloads.

## Chunking metadata

Chunks should carry at least:

- repository path;
- document type;
- chapter/track when known;
- task ID when applicable;
- commit/ref used for indexing;
- heading/symbol context;
- deprecation state;
- source timestamp or commit time.

Prefer semantic sections and code symbols over fixed-size blind chunks where practical.

## Retrieval flow

1. Load compact delivery context from `tools/platforminit_mcp/`.
2. Use task title, allowed paths, changed files, and acceptance criteria to construct a narrow query.
3. Prefer codebase indexing/search for current code and symbols.
4. Query RAG only for architecture/history/runbook context not efficiently available through path-scoped code search.
5. Open the smallest set of source files needed to verify retrieved claims.

## Future components

A later task may add:

```text
rag/
  config/
  ingestion/
  retrieval/
  tests/
  README.md
```

Possible backends may be evaluated later, but the repository should keep the retrieval interface backend-agnostic.

## Required future safety tests

Before enabling production RAG, add tests for secret-path exclusion, stale/deprecated document ranking, source-path traceability, deterministic chunk IDs, bounded retrieval size, deletion/reindex behavior, and protection against retrieval content overriding controller-owned task state.
