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

### Provenance binding

A claimed verdict is not evidence. Staging and promotion resolve authoritative controller state
(`tasks/tracker.json`): the task must exist, its recorded status must be `ready_to_close` or `done`, its
recorded review/security verdicts must be `approve`/`clear`, and the controller-recorded review and
security report paths must be among the cited `provenance.evidencePaths`. The cited `sourceCommit` must
resolve in this repository and every cited evidence path must exist at that commit. The writing actor
must match `provenance.emitter`. Memory only reads controller state; `taskctl` remains the only writer.

### Promotion

```bash
python3 tools/platforminit_mcp/memory.py add-candidate <candidate.json> --actor platforminit-release-manager
python3 tools/platforminit_mcp/memory.py list-candidates
python3 tools/platforminit_mcp/memory.py promote <MEMORY-ID> --actor platforminit-release-manager
python3 tools/platforminit_mcp/memory.py quarantine-report
python3 tools/platforminit_mcp/memory.py contract-check
```

Promotion re-validates the candidate, re-resolves the actor/controller/commit bindings, and appends an
`active` project record. Both files are repository-visible JSONL written by reviewed changes, never
hidden runtime state, and memory writes must not be mixed into the controller-owned closure commit.

### Safety and authority boundaries

- Retrieval loads framework memory plus promoted project records only; an unpromoted candidate is
  never returned, not even at the hard cap.
- Project memory is provenance-gated. A project row without provenance is retrieval context only while
  every source it cites already lies inside the approved evidence locations; any other provenance-less
  row is quarantined (`quarantine-provenance-less-project-records`) until a separately reviewed
  migration re-emits it with provenance. `quarantine-report` names the excluded rows, so this
  compatibility window is reported rather than claimed away. The shipped corpus is clean: its
  pre-lifecycle rows are quarantined and therefore not served as memory.
- Distilled records only. A summary must be one bounded line of prose: multi-line payloads, control or
  ANSI sequences, shell transcripts, log-level and timestamped log lines, tracebacks, diff excerpts,
  `/tmp/**` references, and `*.log` references are rejected as raw run output, and a
  provenance-carrying summary has a tighter length bound (400 characters) than legacy history.
- Raw transient logs, terminal output, `/tmp/**` payloads, absolute paths, `../` traversal, URL-ish or
  empty path segments, key material, `.local_secrets/**`, `.git/**`, `.ssh/**`, and secret-looking
  values or paths are rejected before anything is written. Path filtering is a lexical denylist kept as
  defense-in-depth behind the commit/evidence binding.
- `contract-check` replays the quarantine, binding, distilled-record, and path-safety checks on
  throwaway fixtures and exits non-zero on any failure. It is the focused regression gate for this
  module, because the unittest harness file lives outside the bounded scope this lifecycle was
  implemented under.
- Promoted memory stays advisory. `tasks/tracker.json` and `taskctl` remain the only authoritative
  delivery state; the lifecycle grants no new authority over task state, branches, allowed files,
  validators, or lifecycle transitions.
- Retrieval advertises `memoryVersion: 2`; the response keys are unchanged, and promoted records may
  additionally carry a `provenance` object.
- Accepted residuals, stated honestly: the repository-local CLI cannot authenticate a process, so the
  emitter gate is an attributed-actor check inside a reviewed source change; and no controller field
  records the reviewed revision, so the commit binding proves the cited evidence exists at the cited
  commit without proving reviewer identity.

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
