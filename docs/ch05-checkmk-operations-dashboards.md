# CH05 Checkmk Operations Dashboards

CH05.8 configures the Checkmk operations dashboard landing experience after the stable Checkmk checkpoint, graph AJAX Content-Type fix and session/CSRF fix.

## Purpose

The workflow promotes Checkmk-native dashboards and stable drill-down views instead of writing internal Checkmk dashboard object files. This keeps the dashboard layer compatible with Checkmk Community while still giving operators a clear starting point.

The primary operator page is the PlatformInit Alert Manager dashboard, backed by Checkmk's built-in `Host & service problems` dashboard.

## Workflow

```text
00 - Build Platform Artifacts
05.8 - Configure Checkmk Operations Dashboards
```

Prerequisites:

```text
05.5 - Provision Checkmk Operations Model
05.7 - Install Checkmk Agent and Discover Services
05.6 - Configure Checkmk Operations Entry Point
05.4 - Validate Operations Stack
```

## Alert Manager dashboard

The workflow sets the Checkmk user/global start URL to:

```text
dashboard.py?name=simple_problems&owner=
```

This dashboard shows current host/service problems such as:

```text
WARN
CRIT
UNKNOWN
DOWN
UNREACHABLE
```

It does not serve as a historical event dashboard and it does not list OK services as the primary operator concern.

## Noise policy

The workflow applies a targeted noise policy for transient k3s/containerd overlay filesystems:

```text
^Filesystem /run/k3s/containerd/.*/rootfs$
```

These services are ignored because they represent short-lived container runtime overlay mounts. They can vanish after normal pod/container lifecycle events and should not dominate the alert page.

The workflow reconciles discovery after the rule is written and validates that those services are not present in the generated core configuration.

## Dashboard entrypoints

The workflow records a PlatformInit dashboard catalog inside the Checkmk site:

```text
/omd/sites/cmk/local/share/platforminit/checkmk-operations-dashboards.txt
```

The catalog contains:

- PlatformInit Alert Manager / Host & service problems dashboard
- Main dashboard
- Checkmk dashboard
- PlatformInit host status view
- PlatformInit host graphs view
- All hosts view
- All services view
- Service problems view

A lightweight current problem snapshot is also written to:

```text
/omd/sites/cmk/local/share/platforminit/checkmk-alert-manager-current.txt
```

## Validation

CH05.8 validates that:

- `platforminit-dev-01` is a TCP Checkmk agent target.
- the host has at least the expected number of generated services after CH05.7 discovery.
- transient k3s/containerd overlay rootfs filesystem services are absent from generated core config.
- the Alert Manager dashboard start URL exists.
- dashboard and drill-down URLs respond through the trusted-header WebUI path.
- graph pages no longer contain `graph_recipe` errors.

## Design note

Checkmk Community already ships standard dashboards and view widgets suitable for this stage. CH05.8 therefore avoids creating version-sensitive raw dashboard object definitions. A later advanced UI layer can build custom dashboards after the Checkmk-native dashboard contract remains stable.
