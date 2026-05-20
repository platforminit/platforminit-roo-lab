# CH01

GitHub-kompatibilis, repo-ready CH01 váz.

## Design goals
- code/runtime szétválasztás
- secret-free repository
- release tarball kompatibilis futtatás
- host-local és későbbi CI/SSH execution model támogatás

## Code vs runtime
- Code root: tetszőleges extract path
- Runtime root: `/srv/ch01-runtime` alapértelmezés szerint

## Hivatalos entrypoint
```bash
sudo CH01_RUNTIME_ROOT=/srv/ch01-runtime ./scripts/run-restore-and-validate.sh
```
