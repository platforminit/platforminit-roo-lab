# Suggested commit sequence

1. `bootstrap(monorepo): import CH01 baseline into platform/host-baseline`
2. `bootstrap(monorepo): import CH02 cluster automation into platform/cluster`
3. `bootstrap(monorepo): import CH03 platform services into platform/platform-services`
4. `refactor(workflows): add numbered user-facing deploy flow`
5. `feat(build): auto-build component artifacts on push with inventory printouts`
6. `feat(host): add create-or-rebuild host workflow with volume size input`
7. `refactor(secrets): switch workflows to generic secret contract`
8. `refactor(tls): make platform services domain-aware via PLATFORM_BASE_DOMAIN`
