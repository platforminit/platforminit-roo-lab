# PlatformInit Dev Recovery Chain

If the Roo lab repository breaks `platforminit-dev-01`, recovery must be performed from the stable `platforminit-platform` repository.

Stable recovery source:

```bash
cd /mnt/d/SYSADMIN/platforminit-platform
code .
```

Minimum recovery chain:

1. `01 - Create or Rebuild Host`
2. `02 - Apply Host Baseline`
3. `03 - Install Kubernetes Cluster`
4. `04 - Enable Platform`
5. `04.5 - Deploy Identity Foundation`
6. `05.x - Deploy/Validate Operations Stack`

The dev host is disposable. The stable `platforminit-platform` repository is the recovery source of truth.
