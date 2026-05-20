# Full Dev Rehearsal Model

`platforminit-roo-lab` is a full-access development rehearsal repository.

It may run or modify development workflows that target `platforminit-dev-01`.

## Repository roles

- `platforminit-platform`: stable source of truth and recovery source.
- `platforminit-roo-lab`: disposable workflow rehearsal and Roo Code orchestration testbed.
- `platforminit-dev-01`: disposable development target.

## Accepted risk

Breaking the development host is acceptable. The success criterion is not that the lab never breaks dev, but that the recovery path remains known, documented, and executable.

## Forbidden scope

- production Hetzner project
- customer hosts
- customer DNS zones
- committed secrets
- secret values in logs or artifacts
