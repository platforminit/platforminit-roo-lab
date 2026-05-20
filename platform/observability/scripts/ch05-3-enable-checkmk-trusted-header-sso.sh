#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
AUTHENTIK_LOCAL_PORT="${AUTHENTIK_LOCAL_PORT:-19080}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-http://127.0.0.1:${AUTHENTIK_LOCAL_PORT}}"
AUTHENTIK_OPERATIONS_ADMIN_USERNAME="${AUTHENTIK_OPERATIONS_ADMIN_USERNAME:-akadmin}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
CHECKMK_LOCAL_PORT="${CHECKMK_LOCAL_PORT:-18085}"
CHECKMK_REMOTE_USER_HEADER="${CHECKMK_REMOTE_USER_HEADER:-X-Remote-User}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
need kubectl
need curl
need python3
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl get ns "$IDENTITY_NAMESPACE" >/dev/null 2>&1 || die "Missing identity namespace. Run 04.5 first."
kubectl -n "$IDENTITY_NAMESPACE" rollout status deploy/authentik-server --timeout=90s >/dev/null || die "Authentik server is not ready"
kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"

read_secret_key(){ kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true; }
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
if [[ -z "$AUTHENTIK_BOOTSTRAP_TOKEN" ]]; then
  AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "$IDENTITY_NAMESPACE" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
fi
[[ -n "$AUTHENTIK_BOOTSTRAP_TOKEN" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; re-run 04.5 - Deploy Identity Foundation"

AUTHENTIK_PORT_FORWARD_PID=""
CHECKMK_PORT_FORWARD_PID=""
cleanup(){
  [[ -n "${AUTHENTIK_PORT_FORWARD_PID:-}" ]] && kill "$AUTHENTIK_PORT_FORWARD_PID" >/dev/null 2>&1 || true
  [[ -n "${CHECKMK_PORT_FORWARD_PID:-}" ]] && kill "$CHECKMK_PORT_FORWARD_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Starting Authentik API port-forward on 127.0.0.1:${AUTHENTIK_LOCAL_PORT}"
kubectl -n "$IDENTITY_NAMESPACE" port-forward --address 127.0.0.1 svc/authentik-server "${AUTHENTIK_LOCAL_PORT}:80" >/tmp/ch05-checkmk-authentik-port-forward.log 2>&1 &
AUTHENTIK_PORT_FORWARD_PID="$!"
for _ in $(seq 1 30); do
  curl -fsS "${AUTHENTIK_BASE_URL}/api/v3/core/users/me/" -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "${AUTHENTIK_BASE_URL}/api/v3/core/users/me/" -H "Authorization: Bearer ${AUTHENTIK_BOOTSTRAP_TOKEN}" >/dev/null || { cat /tmp/ch05-checkmk-authentik-port-forward.log >&2 || true; die "Authentik API was not reachable"; }

log "Reconciling Authentik application/provider contract for Checkmk forward auth"
export BASE_DOMAIN AUTHENTIK_BASE_URL AUTHENTIK_BOOTSTRAP_TOKEN AUTHENTIK_OPERATIONS_ADMIN_USERNAME CHECKMK_SITE
python3 - <<'PY_AUTHENTIK'
import json, os, sys, urllib.parse, urllib.request, urllib.error
base_domain=os.environ['BASE_DOMAIN']
base_url=os.environ['AUTHENTIK_BASE_URL'].rstrip('/')
token=os.environ['AUTHENTIK_BOOTSTRAP_TOKEN']
admin_username=os.environ.get('AUTHENTIK_OPERATIONS_ADMIN_USERNAME','akadmin')
checkmk_url=f"https://checkmk.{base_domain}"
headers={"Authorization":f"Bearer {token}","Accept":"application/json","Content-Type":"application/json"}

def request(method,path,payload=None,tolerate_404=False):
    data=json.dumps(payload).encode() if payload is not None else None
    req=urllib.request.Request(f"{base_url}{path}",data=data,method=method,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=30) as resp:
            raw=resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body=exc.read().decode(errors='replace')
        if tolerate_404 and exc.code==404:
            return None
        raise RuntimeError(f"{method} {path} failed HTTP {exc.code}: {body}")

def paginated(path):
    out=[]; nxt=path
    while nxt:
        obj=request('GET',nxt)
        if isinstance(obj,dict) and 'results' in obj:
            out.extend(obj.get('results') or [])
            nxt=(obj.get('pagination',{}) or {}).get('next') or obj.get('next')
            if nxt and str(nxt).startswith(base_url): nxt=str(nxt)[len(base_url):]
        elif isinstance(obj,list):
            out.extend(obj); break
        else: break
    return out

def first_by(path,field,value):
    enc=urllib.parse.quote(str(value)); sep='&' if '?' in path else '?'
    for q in (f"{field}={enc}",f"search={enc}"):
        for item in paginated(f"{path}{sep}{q}"):
            if str(item.get(field,''))==str(value) or str(item.get('name',''))==str(value) or str(item.get('slug',''))==str(value):
                return item
    return None

def flow(slug):
    item=first_by('/api/v3/flows/instances/','slug',slug)
    if not item: raise RuntimeError(f"Required Authentik flow not found: {slug}")
    return item['pk']

def ensure_group(name):
    existing=first_by('/api/v3/core/groups/','name',name)
    payload={"name":name,"is_superuser":False,"parent":None,"attributes":{}}
    if existing:
        request('PATCH',f"/api/v3/core/groups/{existing['pk']}/",payload); return existing['pk']
    return request('POST','/api/v3/core/groups/',payload)['pk']

def group_pks(raw):
    vals=[]
    for x in raw or []:
        if isinstance(x,str): vals.append(x)
        elif isinstance(x,dict):
            v=x.get('pk') or x.get('id') or x.get('uuid')
            if v: vals.append(v)
    return vals

def ensure_user_in_group(username, group_pk):
    user=first_by('/api/v3/core/users/','username',username)
    if not user:
        print(f"WARN: Authentik user {username!r} not found; Checkmk SSO group exists but user was not added", file=sys.stderr); return
    detail=request('GET',f"/api/v3/core/users/{user['pk']}/")
    groups=group_pks(detail.get('groups',[]))
    if group_pk not in groups:
        groups.append(group_pk)
        request('PATCH',f"/api/v3/core/users/{user['pk']}/",{"groups":groups})
        print(f"Added {username} to PlatformInit Operations")

def provider_payload(mode):
    # Authentik proxy providers require both authorization and invalidation flows.
    # Keep this explicit because newer Authentik versions reject create/update
    # requests without invalidation_flow with HTTP 400.
    payload={
        "name":"PlatformInit Checkmk",
        "authorization_flow":flow('default-provider-authorization-implicit-consent'),
        # Checkmk has no native Authentik/OIDC logout. When the user clicks the
        # Checkmk logout endpoint, the auth-shim and public ingress redirect to
        # the global Authentik invalidation flow so the Authentik
        # browser session is ended as well, which returns the next visit to the
        # Authentik login flow instead of silently re-using the existing SSO
        # session.
        "invalidation_flow":flow('default-invalidation-flow'),
        "external_host":checkmk_url,
        "internal_host":"http://checkmk.operations.svc.cluster.local",
        "mode":mode,
        "cookie_domain":base_domain,
        "intercept_header_auth":False,
        "basic_auth_enabled":False,
    }
    try:
        payload["authentication_flow"]=flow('default-authentication-flow')
    except Exception:
        pass
    return payload

def ensure_proxy_provider():
    existing=first_by('/api/v3/providers/proxy/','name','PlatformInit Checkmk')
    errors=[]
    for mode in ('forward_single','forward_domain'):
        payload=provider_payload(mode)
        try:
            if existing:
                request('PATCH',f"/api/v3/providers/proxy/{existing['pk']}/",payload)
                print(f"Updated Authentik proxy provider PlatformInit Checkmk mode={mode}")
                return existing['pk']
            created=request('POST','/api/v3/providers/proxy/',payload)
            print(f"Created Authentik proxy provider PlatformInit Checkmk mode={mode}")
            return created['pk']
        except Exception as exc:
            errors.append(f"{mode}: {exc}")
    raise RuntimeError('Could not create/update Authentik proxy provider: ' + ' | '.join(errors))

def ensure_application(provider_pk):
    slug='platforminit-checkmk'
    payload={"name":"PlatformInit Checkmk","slug":slug,"provider":provider_pk,"open_in_new_tab":True,"meta_launch_url":f"{checkmk_url}/cmk/","meta_description":"PlatformInit Checkmk Community operations console","meta_publisher":"PlatformInit"}
    existing=first_by('/api/v3/core/applications/','slug',slug)
    if existing:
        request('PATCH',f"/api/v3/core/applications/{slug}/",payload)
        print('Updated Authentik application platforminit-checkmk')
    else:
        request('POST','/api/v3/core/applications/',payload)
        print('Created Authentik application platforminit-checkmk')
    return slug

def ref_id(value):
    if isinstance(value,str):
        return value
    if isinstance(value,dict):
        for key in ('pk','id','uuid','slug','name'):
            if value.get(key):
                return str(value[key])
    return None

def ref_list(raw):
    refs=[]
    for item in raw or []:
        rid=ref_id(item)
        if rid and rid not in refs:
            refs.append(rid)
    return refs

def find_proxy_outpost():
    outposts=paginated('/api/v3/outposts/instances/?page_size=100')
    candidates=[]
    for o in outposts:
        name=str(o.get('name','')).lower()
        typ=str(o.get('type','')).lower()
        if 'embedded' in name:
            return o
        if typ == 'proxy' or 'proxy' in name:
            candidates.append(o)
    if candidates:
        return candidates[0]
    return outposts[0] if outposts else None

def verify_outpost_assignment(outpost_pk, provider_pk, slug):
    detail=request('GET',f"/api/v3/outposts/instances/{outpost_pk}/")
    providers=ref_list(detail.get('providers'))
    providers_obj=ref_list(detail.get('providers_obj'))
    applications=ref_list(detail.get('applications'))
    provider_s=str(provider_pk)
    used = provider_s in providers or provider_s in providers_obj or slug in applications
    if not used:
        # Some authentik versions expose provider assignment reliably via the list
        # filter before the embedded outpost detail payload refreshes. Treat this
        # as authoritative only when it returns the same outpost UUID.
        try:
            for item in paginated(f"/api/v3/outposts/instances/?providers_by_pk={provider_pk}"):
                if str(item.get('pk')) == str(outpost_pk):
                    used = True
                    break
        except Exception:
            pass
    return used, providers, providers_obj, applications, detail

def outpost_provider_refs(detail):
    refs=[]
    for raw in (detail.get('providers') or [], detail.get('providers_obj') or []):
        for item in raw:
            rid=ref_id(item)
            if rid and rid not in refs:
                refs.append(rid)
    return refs

def outpost_service_connection_ref(detail):
    raw=detail.get('service_connection')
    rid=ref_id(raw)
    if rid:
        return rid
    raw=detail.get('service_connection_obj')
    return ref_id(raw)

def outpost_put_payload(detail, provider_pk):
    # Full PUT is more reliable than partial PATCH for the embedded outpost on
    # some authentik versions. The OpenAPI schema requires name, type,
    # providers, service_connection and config for OutpostRequest.
    refs=outpost_provider_refs(detail)
    provider_s=str(provider_pk)
    if provider_s not in refs:
        refs.append(provider_s)
    providers=[]
    for ref in refs:
        try:
            providers.append(int(ref))
        except Exception:
            # Provider IDs are integer in the current API schema. Keep a clear
            # failure instead of sending malformed mixed IDs.
            raise RuntimeError(f"Unexpected non-integer outpost provider reference: {ref!r}")
    payload={
        'name': detail.get('name') or 'authentik Embedded Outpost',
        'type': detail.get('type') or 'proxy',
        'providers': providers,
        'service_connection': outpost_service_connection_ref(detail),
        'config': detail.get('config') or {},
    }
    if detail.get('managed') is not None:
        payload['managed']=detail.get('managed')
    return payload

def patch_outpost_field(outpost_pk, provider_pk):
    # Try the minimal documented PATCH first. Then fall back to a full PUT with
    # the complete OutpostRequest shape because the embedded outpost can ignore
    # or not immediately reflect partial provider updates in some releases.
    detail=request('GET',f"/api/v3/outposts/instances/{outpost_pk}/")
    refs=outpost_provider_refs(detail)
    provider_s=str(provider_pk)
    if provider_s not in refs:
        request('PATCH',f"/api/v3/outposts/instances/{outpost_pk}/",{'providers':[int(x) for x in refs] + [int(provider_pk)]})
    used, providers, providers_obj, applications, _ = verify_outpost_assignment(outpost_pk, provider_pk, 'platforminit-checkmk')
    if used:
        return 'patch', providers, providers_obj, applications

    detail=request('GET',f"/api/v3/outposts/instances/{outpost_pk}/")
    request('PUT',f"/api/v3/outposts/instances/{outpost_pk}/",outpost_put_payload(detail, provider_pk))
    used, providers, providers_obj, applications, _ = verify_outpost_assignment(outpost_pk, provider_pk, 'platforminit-checkmk')
    if used:
        return 'put', providers, providers_obj, applications
    return None, providers, providers_obj, applications

def ensure_outpost_provider(provider_pk, slug):
    # Authentik admin UI warning "Provider is not used by any Outpost" is cleared
    # only when the proxy provider itself is assigned to a proxy outpost. The API
    # schema exposes this as the outpost `providers` integer list, not an
    # application slug list.
    outpost=find_proxy_outpost()
    if not outpost:
        raise RuntimeError('No Authentik outpost found; create/enable the embedded proxy outpost before Checkmk forwardAuth can work')
    outpost_pk=outpost['pk']
    used, providers, providers_obj, applications, _ = verify_outpost_assignment(outpost_pk, provider_pk, slug)
    if used:
        print(f"Provider already attached to Authentik outpost {outpost.get('name', outpost_pk)}")
        return

    errors=[]
    try:
        method, providers, providers_obj, applications = patch_outpost_field(outpost_pk, provider_pk)
        if method:
            print(f"Attached PlatformInit Checkmk provider to Authentik outpost {outpost.get('name', outpost_pk)} via {method.upper()}")
            return
    except Exception as exc:
        errors.append(str(exc))

    used, providers, providers_obj, applications, detail = verify_outpost_assignment(outpost_pk, provider_pk, slug)
    if not used:
        raise RuntimeError(
            'Could not attach PlatformInit Checkmk provider to Authentik outpost. '
            f'outpost={outpost.get("name", outpost_pk)} provider_pk={provider_pk} slug={slug} '
            f'providers={providers} providers_obj={providers_obj} applications={applications} '
            f'outpost_type={detail.get("type")} service_connection={outpost_service_connection_ref(detail)} '
            f'errors={errors}'
        )
request('GET','/api/v3/core/users/me/')
ops_group=ensure_group('PlatformInit Operations')
ensure_user_in_group(admin_username, ops_group)
provider=ensure_proxy_provider()
slug=ensure_application(provider)
ensure_outpost_provider(provider, slug)
print('Checkmk Authentik forward-auth contract reconciled')
PY_AUTHENTIK

log "Using Argo CD-owned Checkmk auth-shim ConfigMap from operations-stack manifest"
log "If the auth-shim mapping changed in Git, run 05.2 - Sync Operations Stack before CH05.3"

log "Enabling Checkmk trusted-header authentication for ${CHECKMK_REMOTE_USER_HEADER}"
CHECKMK_POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$CHECKMK_POD" ]] || die "Could not resolve Checkmk pod"

kubectl -n "$NAMESPACE" exec -i "$CHECKMK_POD" -c checkmk -- bash -s -- "$CHECKMK_REMOTE_USER_HEADER" <<'CHECKMK_HEADER_AUTH'
set -euo pipefail
HEADER="$1"
SITE="cmk"
CONF_DIR="/omd/sites/${SITE}/etc/check_mk/multisite.d/wato"
GLOBAL_CONF="${CONF_DIR}/global.mk"
LEGACY_CONF="${CONF_DIR}/platforminit_header_auth.mk"
mkdir -p "$CONF_DIR"
touch "$GLOBAL_CONF"
python3 - "$GLOBAL_CONF" "$HEADER" <<'PY_HEADER_AUTH'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
header = sys.argv[2]
text = path.read_text(errors="replace") if path.exists() else ""
text = re.sub(r"(?m)^# Managed by PlatformInit CH05\.3 trusted-header auth\.\n", "", text)
text = re.sub(r"(?m)^auth_by_http_header\s*=.*\n?", "", text)
if text and not text.endswith("\n"):
    text += "\n"
text += "\n# Managed by PlatformInit CH05.3 trusted-header auth.\n"
text += f"auth_by_http_header = {header!r}\n"
path.write_text(text)
PY_HEADER_AUTH
rm -f "$LEGACY_CONF"
chown "${SITE}:${SITE}" "$GLOBAL_CONF" 2>/dev/null || true
chmod 0644 "$GLOBAL_CONF"
omd restart "$SITE" >/tmp/platforminit-checkmk-header-auth-restart.log 2>&1 || {
  cat /tmp/platforminit-checkmk-header-auth-restart.log >&2 || true
  exit 1
}
CHECKMK_HEADER_AUTH

log "Starting temporary Checkmk direct port-forward on 127.0.0.1:${CHECKMK_LOCAL_PORT}"
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/checkmk "${CHECKMK_LOCAL_PORT}:5000" >/tmp/ch05-checkmk-port-forward.log 2>&1 &
CHECKMK_PORT_FORWARD_PID="$!"
for _ in $(seq 1 45); do
  code="$(curl -fsS -H "${CHECKMK_REMOTE_USER_HEADER}: cmkadmin" -o /tmp/ch05-checkmk-health.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" 2>/dev/null || true)"
  [[ "$code" =~ ^(200|302)$ ]] && break
  sleep 2
done
code="$(curl -fsS -H "${CHECKMK_REMOTE_USER_HEADER}: cmkadmin" -o /tmp/ch05-checkmk-health.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" 2>/dev/null || true)"
[[ "$code" =~ ^(200|302)$ ]] || { cat /tmp/ch05-checkmk-port-forward.log >&2 || true; die "Checkmk frontend did not accept X-Remote-User trusted-header auth through direct port-forward; HTTP=${code}"; }
kill "$CHECKMK_PORT_FORWARD_PID" >/dev/null 2>&1 || true
CHECKMK_PORT_FORWARD_PID=""

auth_conf="$(kubectl -n "$NAMESPACE" exec "$CHECKMK_POD" -c checkmk -- bash -lc "grep -n 'auth_by_http_header' /omd/sites/${CHECKMK_SITE}/etc/check_mk/multisite.d/wato/global.mk 2>/dev/null || true")"
echo "$auth_conf" | grep -q "X-Remote-User" || die "Checkmk trusted-header auth configuration was not persisted in WATO global.mk"

log "Validating Checkmk auth-shim path through service port 80"
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/checkmk "${CHECKMK_LOCAL_PORT}:80" >/tmp/ch05-checkmk-auth-shim-port-forward.log 2>&1 &
CHECKMK_PORT_FORWARD_PID="$!"
for _ in $(seq 1 45); do
  shim_code="$(curl -fsS     -H "Host: checkmk.${BASE_DOMAIN}"     -H "X-authentik-username: platforminit-test"     -H "X-authentik-email: platforminit-test@${BASE_DOMAIN}"     -H "Cookie: auth_cmk=stale-test-cookie"     -o /tmp/ch05-checkmk-auth-shim.html     -w '%{http_code}'     "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" 2>/dev/null || true)"
  [[ "$shim_code" =~ ^(200|302)$ ]] && break
  sleep 2
done
shim_code="$(curl -fsS   -H "Host: checkmk.${BASE_DOMAIN}"   -H "X-authentik-username: platforminit-test"   -H "X-authentik-email: platforminit-test@${BASE_DOMAIN}"   -H "Cookie: auth_cmk=stale-test-cookie"   -o /tmp/ch05-checkmk-auth-shim.html   -w '%{http_code}'   "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" 2>/dev/null || true)"
if [[ ! "$shim_code" =~ ^(200|302)$ ]]; then
  cat /tmp/ch05-checkmk-auth-shim-port-forward.log >&2 || true
  kubectl -n "$NAMESPACE" logs "$CHECKMK_POD" -c auth-shim --tail=120 >&2 || true
  kubectl -n "$NAMESPACE" exec "$CHECKMK_POD" -c checkmk -- bash -lc 'tail -n 160 /omd/sites/cmk/var/log/web.log /omd/sites/cmk/var/log/apache/error_log 2>/dev/null || true' >&2 || true
  die "Checkmk auth-shim path did not answer; HTTP=${shim_code}"
fi

kubectl -n "$NAMESPACE" create secret generic checkmk-sso \
  --from-literal=CHECKMK_SITE="$CHECKMK_SITE" \
  --from-literal=CHECKMK_REMOTE_USER_HEADER="$CHECKMK_REMOTE_USER_HEADER" \
  --from-literal=CHECKMK_PUBLIC_URL="https://checkmk.${BASE_DOMAIN}/${CHECKMK_SITE}/" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log "Checkmk trusted-header SSO contract reconciled with auth_by_http_header managed in WATO global.mk."
