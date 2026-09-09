# Future RAG architecture scaffold

This repository is prepared for retrieval-augmented context, but this refactor intentionally does **not** build a production RAG stack.

## Boundary

RAG may enrich agent context; it must never become task state.

Authoritative mutable task state remains:

```text
tasks/tracker.json
```

Generated task views remain controller-owned. Retrieval output is advisory context only.

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
