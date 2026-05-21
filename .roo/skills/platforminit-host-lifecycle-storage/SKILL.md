---
name: platforminit-host-lifecycle-storage
description: Use when working on CH01 host lifecycle, Hetzner rebuild, volume layout, root-disk-only mode, or /srv contracts.
---


# PlatformInit Host Lifecycle and Storage Skill

## Scope

CH01 owns:

- Hetzner server create/rebuild;
- host naming;
- SSH automation access;
- storage layout resolution;
- volume attachment/mount validation;
- host context generation;
- bootstrap audit evidence.

## Active contracts

- Host: `platforminit-dev-01`.
- Do not resolve to `deprecated long-form development host alias`.
- `development`, `n8n`, `platforminit` are separate project scopes.
- `volume_layout=none` must mean no attached volume.
- Root-disk-only hosts must not fail baseline because `/srv` is not an attached mount.

## Storage rules

For normal platform host, split storage may exist. For n8n/minimal host, root-disk-only can be valid.

A workflow must distinguish:

```text
requested layout
effective layout
attached volume count
mount state
host context env
```

## Failure modes

- stale retained volume attached to a layout that should be `none`;
- wrong project token creates resource in wrong Hetzner project;
- host baseline assumes `/srv` is always a separate mount;
- hidden volume mutation deletes data.

## Required evidence

- `hostname`
- `lsblk`
- `findmnt`
- `/etc/platforminit/host-context.env`
- effective `volume_layout`
- Hetzner labels
