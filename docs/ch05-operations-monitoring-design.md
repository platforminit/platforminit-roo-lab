# CH05 Operations Monitoring Design

## Decision

CH05 uses **Checkmk Community + Authentik trusted-header SSO**.

## Reason

The previous Zabbix model produced telemetry and dashboards but did not provide the desired Checkmk/Nagios-like operator clarity.

The required model is:

```text
HOST -> SERVICE -> STATE -> DETAIL
```

## Runtime

```text
Checkmk Community container
Nginx auth shim sidecar
Traefik IngressRoute
Authentik forwardAuth middleware
Retained hostPath PV under /srv/observability/data/checkmk
```

## Authentication

```text
Browser -> checkmk.<domain> -> Traefik forwardAuth -> Authentik -> Checkmk auth shim -> Checkmk
```

The shim maps:

```text
X-authentik-username -> X-Remote-User
```

Checkmk must use incoming HTTP header authentication for transparent SSO.
