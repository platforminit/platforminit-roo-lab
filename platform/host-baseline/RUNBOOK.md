# CH01 Runbook

## Kötelező runtime struktúra
```text
/srv/ch01-runtime/
  reports/
  state/
  secrets/
```

## Kötelező secret fájl
```text
/srv/ch01-runtime/secrets/devops_authorized_keys
```

## Futtatás
```bash
sudo CH01_RUNTIME_ROOT=/srv/ch01-runtime ./scripts/run-restore-and-validate.sh
```

## Reportok
- `restore-smoke-<ts>.md`
- `restore-smoke-latest.md`
- `validate-host-<ts>.md`
- `validate-host-<ts>.json`
- `validate-host-latest.md`
- `validate-host-latest.json`


## Baseline workflow

- `baseline/capture-state.sh` writes the current host snapshot to the runtime state directory.
- `baseline/drift-check.sh` compares runtime current state against `baseline/state-known-good.json`.
- `baseline/promote-known-good.sh` copies the current runtime state into `baseline/state-known-good.json` in the working tree.

`state-known-good.json` is versioned baseline data. Runtime reports belong in `reports/` for a persistent checkout, or in the configured runtime root for release execution.
