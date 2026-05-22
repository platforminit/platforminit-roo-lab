# CH01 Shared Start/Rebuild Task Contract

## Purpose

Define the contract that allows both `platform` and `n8n` tracks to consume CH01
host lifecycle logic without duplicating it. A track declares its CH01 consumption
through its project registry entry and the shared validation gates defined here.

## Scope

This contract covers the start and rebuild phases of a host lifecycle:

- **Start**: First-time host creation from a clean Hetzner server.
- **Rebuild**: Hetzner OS rebuild followed by re-application of the same lifecycle steps.

Both phases share the same contract: the track provides project metadata, the shared
CH01 lifecycle resolves the host, applies bootstrap, and validates the result.

## Track consumption model

A track consumes CH01 by:

1. Having a project YAML in [`platform/projects/`](../platform/projects/) with:
   - `project_id` — unique track identifier
   - `hetzner.token_secret` — project-scoped Hetzner API token secret name
   - `hetzner.server_prefix` — hostname prefix for the resolver contract
   - `volumes.layout` — one of `none`, `single`, `split`
2. Declaring `P-CH01-T01` and `P-CH01-T02` as shared foundation dependencies in its
   roadmap status file (`tasks/status/<track>.json`).
3. Passing the shared CH01 contract validation (see Validation section).

## What the shared CH01 lifecycle provides

| Capability | Description |
|---|---|
| Host resolution | Derives effective hostname from `server_prefix` + default server index |
| Volume layout | Creates/attaches volumes per `layout` setting |
| Bootstrap | Runs `bootstrap-host-access.sh` with layout-aware mount logic |
| Validation | Validates host state against the contract (users, SSH, mounts, audit) |
| Host context | Writes `/etc/platforminit/host-context.env` with resolved paths |

## Track-specific responsibilities

### Platform track (`development` project)

- `server_prefix`: `platforminit-dev`
- `volume_layout`: `split`
- Requires attached volumes for data, db, and observability.
- Consumed by CH02 (k3s install), CH04 (platform services), CH05 (observability).

### n8n track (`n8n` project)

- `server_prefix`: `platforminit-n8n`
- `volume_layout`: `none`
- Root-disk-only host; no attached Hetzner volume required.
- Consumed by n8n standalone runtime (Docker Compose, Caddy, PostgreSQL).
- Must not require k3s, platform CH03-CH05, or attached volumes.

### PlatformInit track (`platforminit` project, production scope)

- `server_prefix`: `platforminit-prod`
- `volume_layout`: `split`
- Production scope; not exercised during dev rehearsal.

## Validation

Run the shared start/rebuild contract validation:

```bash
./platform/host-baseline/validate/ch01-validate-shared-start-rebuild-contract.sh
```

This validates:
- Both platform and n8n tracks declare P-CH01-T02 as shared foundation
- Both tracks have project YAML with required fields
- Track-specific volume layouts are valid per contract
- No duplicate host lifecycle logic exists across tracks
- Orchestrator scripts are track-aware (--track flag)
- Shared contract document exists

The broader lifecycle contract validation also covers this contract document:

```bash
./platform/host-baseline/validate/ch01-validate-host-lifecycle-contract.sh
```

## Adding a new track

To add a new track that consumes CH01:

1. Create `platform/projects/<track>.yaml` with the required fields.
2. Add `P-CH01-T01` and `P-CH01-T02` to the track's `depends_on_platform_tasks` in
   `tasks/roadmap/<track>.json`.
3. Run the shared contract validation to confirm the new track is compatible.
4. No CH01 lifecycle code changes should be needed — the contract is generic.

## Failure modes

| Failure | Impact | Recovery |
|---|---|---|
| Missing project YAML | Track cannot resolve hostname or layout | Create the project YAML |
| Wrong `volume_layout` | Bootstrap mounts wrong paths or fails | Fix layout in project YAML |
| Missing `depends_on_platform_tasks` | Track does not wait for CH01 completion | Add dependency declaration |
| `volume_layout=none` with attached volume | Stale volume detected by validation | Detach volume in Hetzner console |
| `volume_layout=split` without volume-layout.tsv | Bootstrap fails with fatal error | Run 01 - Create or Rebuild Host first |
