# CH05.8B - Checkmk Alert Noise Cleanup

CH05.8B is the cleanup layer after the Checkmk Alert Manager dashboard becomes usable.

It addresses the remaining non-actionable noise observed after CH05.8:

- stale `Systemd Service Summary` CRIT state caused by previously failed static units;
- `Check_MK Discovery` WARN caused by unmonitored/vanished service drift after native agent discovery and filesystem ignore-rule changes.

## Workflow

```text
00 - Build Platform Artifacts
05.8B - Clean Checkmk Alert Noise
```

## Behavior

The workflow performs the following steps:

1. Captures `systemctl --failed` and status/journal context for configured stale-failed units.
2. Runs `systemctl reset-failed` for those units without disabling or masking them.
3. Refreshes the Checkmk agent cache from the deterministic host IPv4 TCP/6556 path.
4. Runs full Checkmk service discovery reconcile from cache.
5. Reloads Checkmk and validates generated configuration.
6. Validates that transient k3s/containerd overlay rootfs filesystem services remain ignored.
7. Validates that `Check_MK Discovery` is no longer non-OK.
8. Validates that configured stale-failed systemd units no longer appear as active Checkmk problems.
9. Updates the PlatformInit Alert Manager current-problem snapshot.

## Stale failed units

Default units:

```text
cloud-init-hotplugd.service dailyaidecheck.service
```

These are treated as stale state candidates only. CH05.8B does not mask them. If either unit immediately fails again after `reset-failed`, the workflow fails and the artifact contains systemd status and journal context.

## Reports

Generated on the host:

```text
/srv/platforminit/reports/ch05-8b-alert-noise-cleanup.txt
```

Generated inside the Checkmk site:

```text
/omd/sites/cmk/local/share/platforminit/checkmk-alert-noise-cleanup.txt
/omd/sites/cmk/local/share/platforminit/checkmk-alert-manager-current.txt
/omd/sites/cmk/local/share/platforminit/checkmk-discovery-reconcile.txt
```

## Non-goals

CH05.8B does not:

- create custom raw Checkmk dashboard objects;
- hide active failed units;
- change Authentik or Checkmk SSO behavior;
- replace CH02/FIM remediation for a genuinely broken `dailyaidecheck` service.
