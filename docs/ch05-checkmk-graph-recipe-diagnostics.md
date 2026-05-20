# CH05 Checkmk graph_recipe diagnostics

## Purpose

`05.8D - Diagnose Checkmk Graph Rendering` is a read-only diagnostic workflow for the deferred Checkmk UI issue:

```text
Loading graph failed: (Status: 1)
'graph_recipe'
```

The CH05 checkpoint is already stable for host/service state, Authentik logout, native Checkmk agent discovery and runtime validation. This diagnostic workflow must be used before changing Checkmk graphing, metric definitions, RRD cleanup or service templates.

## Workflow

```text
00 - Build Platform Artifacts
05.8D - Diagnose Checkmk Graph Rendering
```

Required inputs:

```text
artifact_run_id = run ID from 00 - Build Platform Artifacts
artifact_id     = observability artifact ID
```

Useful optional input:

```text
sample_service_limit = 25
```

## What it collects

The workflow collects:

```text
Checkmk version and site status
cmk -D platforminit-dev-01
cmk -N platforminit-dev-01
cmk --cache -nv platforminit-dev-01
cmk --debug --cache -vvn platforminit-dev-01
generated service descriptions
local and bundled graphing/metric plugin files
local PlatformInit graph/metric references
RRD, PNP and graph cache paths for platforminit-dev-01
Checkmk logs containing graph_recipe / graph failures
sample Checkmk service page probes through X-Remote-User trusted header
host_graphs page probe
post-probe Checkmk logs
```

## Interpretation guide

| Finding | Likely meaning | Next direction |
|---|---|---|
| `graph_recipe` appears in Checkmk logs after service-page probes | Real GUI backend exception | Inspect traceback and graph plugin/metric name from the same log block |
| service pages contain `graph_recipe` in HTML | Error is server-rendered or embedded in response | Fix graphing/metric template mapping or service template |
| only synthetic PlatformInit services show graph errors | Synthetic checks still reference graph-capable template despite no perfdata | Move synthetic services to a non-graph service template or remove graph sidebar exposure |
| only native Linux services show graph errors | Native agent RRD/metric graphing issue | Inspect RRD file names, metric definitions and Checkmk 2.5 graphing plugins |
| no logs and no HTML error from curl probes | Browser-only async graph endpoint | Extract graph ajax endpoints from page HTML and probe those specific endpoints next |

## Current rule

Do not modify CH05.5, CH05.6 or CH05.7 runtime behavior while diagnosing this issue. The stable checkpoint should remain recoverable through the tag:

```text
ch05-checkmk-stable-2026-05-16
```


## CH05.8D artifact conclusion

The diagnostic artifact showed repeated Checkmk WebUI crashes in `ajax_render_graph_content.py` with `KeyError: graph_recipe`. The host is a valid TCP Checkmk agent target and native services exist, so the issue is not agent discovery. The likely ingress/auth-shim root cause is that the shim stripped request headers broadly and did not preserve `Content-Type`, causing Checkmk graph AJAX JSON POST bodies to reach the backend without the parser contract needed to populate `graph_recipe`.

## Dashboard AJAX and session/CSRF extension

CH05.8D also diagnoses the related symptom where built-in Checkmk dashboards can return HTTP 200 but render an empty selector/spinner, and where UI form saves can fail with `Invalid CSRF token`.

The workflow now collects:

```text
dashboard.py route probes for main/checkmk/problems/simple_problems
index.py start_url probes for the same dashboards
direct Checkmk backend responses on 127.0.0.1:5000
auth-shim responses on 127.0.0.1:8080
candidate AJAX endpoint references from returned HTML
cmkadmin web/profile/dashboard/sidebar files
session cookie continuity across repeated GETs
CSRF/token/session markers from returned forms
Checkmk logs containing dashboard, AJAX, cookie, session or CSRF errors
auth-shim runtime nginx header/session contract
```

The intent is to distinguish these cases:

| Finding | Likely meaning |
|---|---|
| Direct backend works but auth-shim route shows empty dashboard | auth-shim header/cookie policy breaks dashboard AJAX/session behavior |
| Repeated auth-shim GETs create new cookies/session markers | Checkmk session cookie is not preserved through the shim |
| Form page renders but POST later fails with invalid CSRF | browser session used for GET is not the same session seen by Checkmk on save |
| Dashboard HTML references AJAX endpoints that fail only through shim | preserve additional Checkmk-required request headers or cookies selectively |

CH05.8D remains read-only. It does not submit form POSTs or change Checkmk settings.


### Session / CSRF note

Checkmk trusted-header SSO still requires normal Checkmk WebUI session cookies for dashboard AJAX and CSRF-protected WATO form submissions. The auth-shim keeps `proxy_pass_request_headers off`, but explicitly preserves `Cookie`, `Accept`, `X-Requested-With`, `Referer`, `Origin`, and `Content-Type` while continuing to strip `Authorization` and unlisted request headers. CH05.3 owns the `auth_by_http_header = 'X-Remote-User'` setting in `global.mk`.
