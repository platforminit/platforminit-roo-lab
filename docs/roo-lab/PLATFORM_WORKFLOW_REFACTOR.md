# PlatformInit Workflow Refactor — Puma-Style Small Context

## Goal

Reduce Zoo Code token growth and HTTP 400 failures by making every lifecycle stage a fresh child,
keeping MCP payloads small, enforcing micro-task sizing, reusing unchanged evidence, and separating
n8n from the PlatformInit canonical queue.

## Required lifecycle

```text
orchestrator
  -> fresh implementation child
  -> orchestrator reloads MCP
  -> fresh review child
  -> orchestrator reloads MCP
  -> fresh OWASP child
  -> orchestrator reloads MCP
  -> fresh release child
```

No stage may depend on accumulated conversation history from a previous specialist. Handoffs contain
only task ID, stage, acceptance gaps, changed paths, evidence paths, unresolved risks, and the next
controller transition.

## Token budget

- MCP `get_delivery_context`: default 5 changed files, hard cap 8. The cap is both advertised in the
  tool schema and enforced by the shipped handler, so a large `maxFiles` request is clamped.
- Bounded tool inputs: `base` accepts only `dev`, `main`, `origin/dev`, or `origin/main`, with a
  64-character maximum and a conservative Git ref grammar; option-like revisions and `..` ranges are
  rejected before any Git argument vector is built. `taskId` is a bounded identifier and `maxFiles`
  must be an integer. Every rejection is a controlled JSON-RPC `-32602` error that carries no
  traceback and no host path.
- Suggested paths: removed. The compact payload no longer duplicates them; use the task's own
  `allowedFiles`.
- Focused tests: max 3.
- Task sizing: enforced by `taskctl` over the non-state changed-file scope, using the same thresholds
  the MCP delivery context advertises as `scope.budget` (`target` 3, `warning` 5, `hardSplitAbove` 5),
  which are the constants `TASK_SIZE_TARGET`, `TASK_SIZE_WARNING_MAX`, and `TASK_SIZE_HARD_SPLIT_ABOVE`
  in `tools/task_controller/taskctl.py`:
  - 1-3 non-state files: the target size for one tracked task; no sizing output.
  - 4-5 non-state files: `TASK_SIZE_WARNING` on stderr, non-blocking. `submit` still succeeds, and the
    handoff must carry the explicit justification for exceeding the target. The message is emitted
    exactly once per command, by that command's authoritative gate call over the snapshot it
    fingerprints and persists: the pre-validator gate in `submit` and the pre-decision gate in
    `complete` apply the hard verdict without warning, so a warning-band scope that grows from 4 to 5
    files while the validators run is reported once, with the final counted scope, instead of the same
    count twice (P-WF-T05-D2).
  - more than 5 non-state files: `TASK_TOO_LARGE_SPLIT_REQUIRED`. `submit` fails before any validator
    runs and before any controller state is written, so the task must be split first.
  - Enforcement points are `submit` and `complete`; `validate` and `start` never block on size, so an
    oversized scope stays diagnosable instead of stranding the task in a state it cannot leave.
  - Controller-owned state (`tasks/tracker.json`, `tasks/active/`), generated views, and review reports
    (`docs/reviews/`, `docs/security-reviews/`) never count toward the size.
  - Single-snapshot contract: every scope-based decision — the allowedFiles check, the size gate, the
    fingerprint, and the persisted `changedFiles` evidence — is taken over one list returned by
    `change_snapshot()`, which fingerprints exactly the list it gathered. `submit` gathers once before
    the gate (fail-fast, before any validator runs) and once more after the required validators ran; that
    second list is always re-gated before it is fingerprinted and persisted, also when it is unchanged,
    and it is the list whose size is warned about. `complete` applies the same gate to the snapshot it
    confirms, including the freshly gathered scope in the rerun path, and emits the one warning from the
    snapshot it records. A file that appears after a count therefore can never be fingerprinted or
    recorded without being counted too, so a late-added file cannot make an oversized scope pass the
    gate (P-WF-T05-D1), and no second warning is emitted for the same command (P-WF-T05-D2).
- Full-repository validation is forbidden by default.
- Passing unchanged evidence is reused instead of rerun.

## Validation evidence reuse contract

`submit` records a deterministic source fingerprint next to the passing validator evidence, and the
release stage (`complete`) reuses that evidence instead of rerunning validators when the source scope
is provably unchanged.

Source fingerprint:

- SHA-256 over a fixed domain separator plus the sorted changed-file scope with one content hash per
  file, so identical source always yields the same digest and any relevant source change yields a
  different one.
- Scope is the committed delta from the resolved comparison base (`dev`, `origin/dev`, `main`,
  `origin/main`, first that resolves) plus index and worktree, so committing already-reviewed source
  does not invalidate evidence.
- Excludes controller-owned state and generated material (`tasks/tracker.json`, `tasks/active/`,
  `docs/reviews/`, `docs/security-reviews/`) and contains no timestamp, actor, or HEAD identity, so
  regenerated views and state writes can never cause false invalidation.
- Deleted files contribute a fixed `<deleted>` marker so deletions change the digest.
- Snapshot binding: `change_snapshot()` gathers the scope once and `fingerprint_files()` digests exactly
  that returned list, so a fingerprint never describes a scope that was re-read after the decision it
  belongs to. `submit` persists that list as `workflow.submit.changedFiles` next to the matching
  `sourceFingerprint`, and `complete` records the confirmed list and fingerprint together.
- When the repository has no commits at all, index plus worktree is the complete source and is used
  as the whole scope. When commits exist but no comparison base resolves, the command fails loudly
  instead of fingerprinting a partial source scope.

Reuse decision (fail-safe):

- Validators are reused only when the recorded evidence is present, carries the supported
  `evidenceVersion`, matches the current fingerprint, matches the current changed-file scope, records
  only exit code 0 for every required validator, covers exactly the task's current
  `requiredValidators`, and carries no unknown fields.
- Consistency checks run before reuse: the recorded submit actor must match the task's
  `implementationMode`, the recorded timestamp must be a non-empty string, and every validator entry
  must be exactly a `command` vector plus an integer `exitCode` of 0. A boolean or non-integer exit
  code, an extra validator-entry field, or a malformed command vector is treated as unusable evidence.
- The fingerprint and the changed-file scope are recomputed immediately before the reuse decision, and
  once more immediately before the completion record is built. That last reading is the one persisted,
  and drift observed at any of those readings falls through to a focused rerun; the residual window that
  remains is described in the confirmation window section below.
- Any missing, legacy, corrupt, partial, unknown-field, inconsistent, or mismatched evidence reruns the
  task's `requiredValidators` only — never full-repository validation — and records the reason in
  `workflow.complete.evidenceDecision`.
- Absent evidence is never treated as a pass.

Confirmation window and residual TOCTOU window:

- `complete` persists the confirmed reading explicitly: `workflow.complete` carries
  `sourceFingerprint`/`changedFiles` for the confirmed source plus `confirmedFingerprint`/
  `confirmedFiles`, the fingerprint and the fingerprint inputs that were checked immediately before the
  completion record was built.
- That confirmation is not atomic with the atomic replacement of `tasks/tracker.json`. After `save()`
  returns, the controller recomputes the fingerprint and compares it with the recorded confirmation. When
  it drifted, the transition fails loudly with a non-zero exit status and the persisted state is
  repaired: the task returns to `ready_to_close` and the stale `workflow.complete` record is removed, so a
  `done` task is never left backed by evidence that no longer describes the source. Rerunning `complete`
  then reruns the task's focused validators.
- Residual window: a source change that lands after the post-persistence re-verification read is not
  detected by this design. Closing that window needs source locking or filesystem snapshot semantics,
  which P-WF-T04 deliberately does not add. The guarantee is detection of the reuse race up to the
  post-persistence read, not perfect atomicity.
- Compensating controls: fail-loud exit status, automatic repair of controller state, controller-owned
  state (only `taskctl` transitions write `tasks/tracker.json`, and that file must never be hand-edited),
  and a focused regression test that injects source drift exactly at the persistence boundary in
  `tools/task_controller/test_taskctl.py`.

Evidence trust boundary (residual risk):

- Reuse is a fail-closed comparison, not an authenticity proof. Submit evidence is stored in
  `tasks/tracker.json`, which is controller-owned state and must never be hand-edited; the controller
  cannot cryptographically distinguish a genuine record from a forged one.
- An actor with unrestricted write access to `tasks/tracker.json` can already bypass this gate: it can
  call `complete` with forged `workflow.review`/`workflow.security` records, or write a submit record
  whose every field (version, timestamp, actor, validator commands, zero exit codes, fingerprint, and
  changed-file scope) is consistent with the current tree. Such a fully consistent forged record is
  intentionally treated as reusable and the focused validators are not rerun. This is a documented
  limitation of P-WF-T04, not a security guarantee.
- Every single-field tamper is still detected and forces a real rerun of the focused validators:
  fingerprint, changed-file scope, validator exit code, validator command/plan, validator entry shape,
  `evidenceVersion`, a removed field, an added field, the recorded actor, and the recorded timestamp are
  each covered by focused regression tests in `tools/task_controller/test_taskctl.py`.
- Release evidence recorded by this controller is therefore trusted-state evidence, not independently
  verifiable security evidence. Its integrity rests on the repository rule that controller state is
  written only by `taskctl` transitions and is never edited by hand.

Authenticated evidence follow-up (out of scope for P-WF-T04):

- Authenticated or append-only evidence is the correct long-term fix and is deliberately not implemented
  here: controller-side signing of the submit record, a keyed MAC bound to a secret the implementation
  actor cannot read, an append-only run ledger outside the task-editable tree, or CI attestation. Each
  option needs new trust infrastructure (secret storage, key distribution, or external state), which is
  outside this task's allowed files and forbidden actions; treat it as a separate tracked task.

Observability:

- `workflow.submit` and `workflow.complete` record `evidenceVersion`, `sourceFingerprint`,
  `changedFiles`, `validators`, `reusedSubmitEvidence`, and (at completion) `evidenceDecision`,
  `confirmedFingerprint`/`confirmedFiles` for the persisted confirmation, plus a `trustBoundary` note
  that restates the residual authenticity limitation next to the decision.
- `python3 tools/task_controller/taskctl.py fingerprint --base dev` prints the resolved base, the
  fingerprint, and the fingerprinted file list for independent inspection by review, security, and
  release roles.

## Delivery context contract (contextVersion 3)

`get_delivery_context` returns exactly these top-level fields and nothing else:

| Field | Content |
|---|---|
| `contextVersion` | `3` — bumped when the compact payload shape changes |
| `project` | `platforminit` |
| `track` | `platform` — the only track this MCP serves |
| `task` | active task summary: `id`, `track`, `status`, `title`, `scope`, `branch`, `dependsOn`, `acceptanceCriteria`, `allowedFiles`, `requiredValidators`, `forbiddenActions`, `stage`, `nextMode`, `command` |
| `scope` | bounded changed scope: `base`, `platformOnly`, `fileCount`, `files`, `truncated`, `focusedTests`, `foreignPathsExcluded`, `budget` |
| `handoff` | `payload` list only: task id, stage, acceptance gaps, changed paths, evidence paths, unresolved risks, controller transition |
| `authoritativeTaskSource` | `tasks/tracker.json` |

Removed from the payload on purpose: the prose `handoff.rule` string, the `indexing` block, and the
duplicated `suggestedPaths`. Those rules belong to this document, not to every MCP response. When no
platform task is runnable the `task` field carries a `state` marker (`no-runnable-platform-task`, or
`unknown-platform-task` for a task ID that is not a platform task) instead of a full summary.

Platform-only rules:

- task selection reads only `track == "platform"` entries; no other track is ever selected, summarised,
  or routed;
- `scope.platformOnly` is always `true` and `foreignPathsExcluded` counts paths owned by the separate
  n8n track (`n8n/`, `docs/n8n/`) that were deliberately dropped from the window;
- controller-owned state (`tasks/tracker.json`, `tasks/active/`, review and security-review reports)
  stays excluded from the changed scope.

## MCP access contract

Every PlatformInit Zoo mode must declare the `mcp` group and must be able to call `health` plus
`get_active_task` after a fresh `new_task` handoff. `.roo/commands/mcp-smoke.md` is the smoke
procedure and documents both layers:

- static: `python3 tools/platforminit_mcp/validate_mode_access.py` rejects a `platforminit-*` mode
  without the `mcp` group, without a fresh-child `get_delivery_context` bootstrap, missing from the
  smoke procedure, or backed by MCP config/server that no longer exposes the required tools. It also
  rejects a soft changed-scope hard cap, a non-default clamp fallback, a `maxFiles` schema that does
  not advertise the small-task bound, a non-platform delivery track, and any bounded-input hole:
  an unvalidated entry point, a `base` schema without the allowlist/length, or a rejection that is
  not a controlled error;
- runtime: `python3 tools/platforminit_mcp/validate_mode_access.py --runtime` boots the stdio server
  and proves `health` plus `get_active_task` return the authoritative tracker task, that
  `get_delivery_context` holds only the contract fields above, and that an oversized
  `get_changed_scope` request is still clamped to the hard cap. It also replays the invalid-input
  matrix (oversized, option-like, `..`, unsupported, and non-string `base`; non-integer and boolean
  `maxFiles`; oversized and non-string `taskId`; unknown tool; unexpected, non-object, and
  non-object-`params` arguments; malformed JSON) and asserts each case is a controlled JSON-RPC
  error without a traceback or a host path.

A mode change is only valid when MCP state is re-derived from the controller after the handoff, so no
specialist stage depends on conversation-carried context.

## Fresh-child pipeline smoke

`.roo/commands/pipeline-smoke.md` is the end-to-end procedure and
`python3 tools/platforminit_mcp/validate_pipeline_smoke.py` is its deterministic contract layer. The
smoke checks the three acceptance gates of the fresh-child pipeline and nothing else:

- gate 1 — every specialist stage is one fresh Zoo `new_task` child in the tracker-declared mode
  (`implementationMode`, `reviewMode`, `securityMode`, `releaseMode`), and each of those modes is a
  declared `platforminit-*` mode that starts as a fresh child;
- gate 2 — every stage mode declares the `mcp` group and boots `health` plus `get_delivery_context`
  after the handoff, and the payload re-derives `stage`/`nextMode`/`command` from authoritative state
  rather than from conversation-carried context;
- gate 3 — the handoff payload is exactly the seven bounded fields, and no stale stage is routable: an
  unknown task id returns a state marker without a stage, and an unmapped or `blocked`/`done` status
  routes to nothing.

The contract layer is read-only, starts no infrastructure workflow, and writes no task state. It reuses
the MCP-access runtime layer (`validate_mode_access.py --runtime`) for the post-handoff
`get_delivery_context` proof instead of booting a second stdio server, so unchanged MCP-access evidence
is not rerun.

## Workflow-hardening task sequence

| Task | Purpose |
|---|---|
| `P-WF-T01` | Enforce fresh-child lifecycle handoffs |
| `P-WF-T02` | Verify MCP access across every Zoo mode |
| `P-WF-T03` | Shrink MCP delivery context budget |
| `P-WF-T04` | Reuse unchanged validation evidence |
| `P-WF-T05` | Enforce micro-task sizing |
| `P-WF-T06` | Detach n8n from PlatformInit canonical task state |
| `P-WF-T07` | Create standalone n8n roadmap and task registry |
| `P-WF-T08` | Smoke-test fresh-child delivery pipeline |

These tasks run after `P-CH04.5-T02` and before `P-CH04.5-T03`.

## n8n separation

PlatformInit and n8n are separate delivery tracks, not two tracks in one lifecycle queue. The
PlatformInit MCP therefore contains no project/track branching: it serves the platform queue only and
removes n8n-owned paths from the changed-scope window (`foreignPathsExcluded`) instead of duplicating
n8n task state or n8n routing inside PlatformInit.

PlatformInit owns:

- `tasks/tracker.json`
- `tasks/active/**`
- `/next-task`
- PlatformInit MCP

n8n owns:

- `docs/n8n/N8N_ROADMAP.md`
- `n8n/tasks/tracker.json`
- its future dedicated next-task/controller surface

Shared infrastructure contracts may be referenced as external prerequisites, but n8n must not use
PlatformInit task IDs as mutable controller dependencies.

## Recovery on API 400

Stop the current child. Start a fresh child in the controller-selected mode, call MCP `health` and
`get_delivery_context`, and resume only from compact evidence paths. Never reconstruct the failed
conversation by rereading the repository broadly.
