# Multi-project host discovery and volume layout

## Branch

`feat/multi-project-host-discovery-volume-layout`

## Commit

`feat(infra): add label-based host discovery and volume layouts`

## Design summary

PlatformInit no longer needs to rely on one global `INFRA_SERVER_ID` for every workflow.

Resolution order is now:

1. `server_id_override`
2. Hetzner label discovery using `project` + `host_name`
3. legacy `secrets.INFRA_SERVER_ID` fallback

Every created server receives these labels:

```text
platforminit.project=<project>
platforminit.host=<host_name>
platforminit.role=primary
platforminit.volume_layout=<none|single|split>
```

## Volume layouts

### `none`

No extra Hetzner volume is created.

### `single`

Creates one persistent volume:

```text
platforminit-<project>-<host_name>-srv -> /srv
```

### `split`

Creates three persistent volumes:

```text
platforminit-<project>-<host_name>-data          -> /srv/data
platforminit-<project>-<host_name>-db            -> /srv/db
platforminit-<project>-<host_name>-observability -> /srv/observability
```

Important runtime contract:

- `split` must not leave a direct `/srv` persistent volume mount behind.
- `/srv/data`, `/srv/db`, and `/srv/observability` must each be separate mounted filesystems.
- `01 - Create or Rebuild Host` creates and attaches the volumes and writes `/etc/platforminit/volume-layout.tsv`.
- `01.1 - Host Bootstrap` reconciles `/etc/fstab` and mounts the volumes.
- CH01 validation fails if the host context says `split` but any split mount is missing, or if a stale direct `/srv` mount exists.

## Host context

`01 - Create or Rebuild Host` writes:

```text
/etc/platforminit/host-context.env
/etc/platforminit/volume-layout.tsv
```

Other workflows should not guess the layout. They should resolve the host through `.github/actions/resolve-target-host` and, on the host, source:

```bash
source /etc/platforminit/host-context.env
```

## Workflow impact

All operational workflows now expose `project` and `host_name` inputs and pass them into the shared resolver action.

This keeps old single-host operation working while enabling multiple hosts/projects without multiplying repository secrets.


## 2026-05-06 update: volume-aware platform foundation

Branch: `feat/volume-aware-platform-foundation`

This branch finalizes the transition from a single static server model to a project-scoped, role-aware and volume-layout-aware platform foundation.

### Host resolution order

`resolve-target-host` now resolves a target in this order:

1. `server_id_override`
2. `platforminit.project` + `platforminit.host` labels
3. `platforminit.project` + `platforminit.role` labels
4. legacy `INFRA_SERVER_ID` fallback

Supported roles are intentionally generic: `primary`, `worker`, `db`, `observability`.

### Required Hetzner labels

Servers created by `01 - Create or Rebuild Host` are labeled with:

```text
platforminit.project=<project>
platforminit.host=<host_name>
platforminit.role=<host_role>
platforminit.volume_layout=none|single|split
```

### Project-scoped GitHub environments

Deploy workflows now use the selected `project` as the GitHub Actions `environment`. This allows the same secret names to be reused safely per project/environment, for example:

```text
Environment: homelab
Environment: dev
Environment: staging
Environment: prod

Secrets per environment:
INFRA_API_TOKEN
AUTOMATION_SSH_PRIVATE_KEY
AUTOMATION_SSH_PUBLIC_KEY
HOST_LOGIN_USER
DNS_API_TOKEN
PLATFORM_BASE_DOMAIN
GRAFANA_ADMIN_PASSWORD
```

`INFRA_SERVER_ID` remains supported only as a backward-compatible fallback. New project workflows should prefer label discovery.

### Volume layout propagation

The host lifecycle writes `/etc/platforminit/host-context.env`, consumed by CH02 and CH05 validations.

```bash
PLATFORMINIT_PROJECT=...
PLATFORMINIT_HOST_NAME=...
PLATFORMINIT_ROLE=primary
PLATFORMINIT_VOLUME_LAYOUT=single|split
PLATFORMINIT_SRV_PATH=/srv
PLATFORMINIT_DATA_PATH=/srv/data
PLATFORMINIT_DB_PATH=/srv/db
PLATFORMINIT_OBSERVABILITY_PATH=/srv/observability
```

### CH02 layout awareness

CH02 uses the PlatformInit k3s storage contract:

```text
/srv/data/k3s
```

This is intentional even when legacy single-layout hosts exist, because the k3s local-path provisioner stores PVC backing data below the k3s data directory. Validation fails when the actual k3s config does not match the expected data-dir.

### CH05 layout awareness

CH05 uses `PLATFORMINIT_OBSERVABILITY_PATH` as its release/report base path and validation now checks that the path exists and is writable.

### Drift validation

The drift checker now validates the selected volume layout:

```text
none   -> /srv directory exists
single -> /srv is a writable mountpoint
split  -> /srv/data, /srv/db and /srv/observability are writable mountpoints
```
