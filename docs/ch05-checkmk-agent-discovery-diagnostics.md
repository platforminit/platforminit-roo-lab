# CH05.7D - Checkmk Agent Discovery Diagnostics

This document defines the stop-loss diagnostic path for the paused CH05.7 native
Checkmk agent discovery work.

Current stable checkpoint:

```text
05.5 - Provision Checkmk Operations Model              OK
05.6 - Configure Checkmk Operations Entry Point        OK
Checkmk logout through Authentik global logout flow    OK
CH05.7 native Checkmk agent discovery                  paused
```

Do **not** continue speculative CH05.7 host-model or raw Checkmk overlay
patches until the diagnostic bundle has been reviewed.

## Workflow

Run:

```text
00 - Build Platform Artifacts
05.7D - Diagnose Checkmk Agent Discovery
```

Default mode is read-only for Checkmk service discovery: it does not run
`cmk -I`, because that command can write autochecks. The workflow still collects
all relevant inputs for the next design decision:

```text
Checkmk version / edition
site process status
site config dump
platforminit Checkmk config files
host object state
agent output from host-local TCP path
agent output from Checkmk pod direct TCP path
agent output through cmk -d
agent cache state
cmk --debug -vvn output
cmk --debug --cache -vvn output
autochecks and autodiscovery state
core config / cmk -N / cmk-validate-config output
```

Only enable `run_discovery_probe=true` when you intentionally want a
state-changing discovery probe. That mode runs `cmk --debug --cache -vvI` and
`cmk --debug -vvI`, but still does not reload the monitoring core.

## Manual command checklist

On the host:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
POD="$(kubectl -n operations get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
HOST_IPV4="$(hostname -I | awk '{print $1}')"

systemctl status check-mk-agent.socket --no-pager || true
ss -ltnp | grep ':6556' || true
timeout 10 bash -lc 'exec 3<>/dev/tcp/127.0.0.1/6556; head -n 80 <&3'

kubectl -n operations exec "$POD" -c checkmk -- bash -lc "timeout 10 bash -lc 'exec 3<>/dev/tcp/${HOST_IPV4}/6556; head -n 120 <&3'"
```

Inside the Checkmk container/site:

```bash
kubectl -n operations exec -it "$POD" -c checkmk -- bash
su - cmk

omd status
cmk -V
cmk -l
cmk -D platforminit-dev-01
cmk -N platforminit-dev-01
cmk-validate-config
cmk -d platforminit-dev-01
cmk --debug -vvn platforminit-dev-01
cmk --debug --cache -vvn platforminit-dev-01
find ~/var/check_mk/autochecks -maxdepth 3 -type f -ls
find ~/tmp/check_mk/cache -maxdepth 1 -type f -ls
```

Optional state-changing probe:

```bash
cmk --debug --cache -vvI platforminit-dev-01
cmk --debug -vvI platforminit-dev-01
```

## What to decide from the diagnostic bundle

Use the logs to decide which of these is actually broken:

| Evidence | Likely problem |
|---|---|
| direct TCP probe works, `cmk -d` fails | Checkmk host datasource / host tags / resolver model |
| `cmk -d` works, `cmk --debug -vvn` shows no Linux services | agent sections are missing or Checkmk cannot parse them |
| `cmk --debug -vvn` shows Linux services, autochecks stay empty | discovery/autocheck write path issue |
| `cmk -N` fails | invalid Checkmk config or stale overlay |
| native services exist but graphs fail | graphing/metric rendering issue after discovery |

### CH05.7 root-cause note

The 05.7D artifact showed that raw TCP access to the host agent worked, but `cmk -D platforminit-dev-01` still reported `Agent mode: No agent` and `cmk -d` returned empty output. The fix is to keep CH05.5 on the stable synthetic service model while writing the host with explicit raw Checkmk agent tags: `cmk-agent|tcp|prod|lan`. The `tcp` tag is required so Checkmk treats the host as a normal TCP agent target instead of a piggyback/PING-only object.


### 2026-05-16 diagnostic finding

The CH05.7D artifact confirmed that the host is now a real TCP Checkmk agent target: `cmk -D` shows a TCP agent on `62.238.5.243:6556`, `cmk -d platforminit-dev-01` returns Linux agent sections, and `cmk --debug -vvn` fetches/parses data via the TCP datasource. Do not add pre-discovery assertions that expect native Linux service status lines before `cmk -I` has created autochecks.
