import os,sys,yaml
project=sys.argv[1]
cfg=yaml.safe_load(open(f'platform/projects/{project}.yaml'))
token_env=cfg['hetzner']['token_secret']
token=os.getenv(token_env)
if not token:
    raise SystemExit(f'Missing token: {token_env}')
print(f"HCLOUD_TOKEN={token}")
print(f"REGION={cfg['hetzner']['region']}")
print(f"SERVER_PREFIX={cfg['hetzner']['server_prefix']}")
print(f"SSH_KEY_NAME={cfg['ssh']['key_name']}")
print(f"VOLUME_NAMESPACE={cfg['volumes']['namespace']}")
print(f"VOLUME_LAYOUT={cfg['volumes']['layout']}")
