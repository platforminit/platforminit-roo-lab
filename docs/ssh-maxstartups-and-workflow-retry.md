# SSH MaxStartups and workflow retry contract

PlatformInit workflows connect to the host over SSH. Public VPS hosts are frequently hit by unauthenticated SSH scanners, which can exhaust OpenSSH pre-auth connection slots and cause transient errors such as:

```text
kex_exchange_identification: read: Connection reset by peer
Connection reset by <host> port 22
sshd: error: beginning MaxStartups throttling
sshd: drop connection #10 ... past MaxStartups
```

## Host-side baseline

The host SSH hardening baseline sets:

```text
LoginGraceTime 20
MaxStartups 50:30:200
```

This keeps root/password login disabled while giving CI workflows enough room to connect during scanner bursts.

## Workflow-side behavior

CH05 workflows wrap SSH and SCP operations with bounded retry/backoff:

- `BatchMode=yes`
- `ConnectTimeout=20`
- `ConnectionAttempts=1`
- 6 attempts
- exponential backoff capped at 45 seconds

This retry layer is only for transport-level instability. It must not hide application failures, Argo CD health failures or validation failures.

## Diagnosis

On the host:

```bash
sudo journalctl -u ssh --since "30 min ago" --no-pager | grep -Ei 'maxstartups|drop connection|reset|disconnect'
sudo ss -tnp | grep ':22' | wc -l
```
