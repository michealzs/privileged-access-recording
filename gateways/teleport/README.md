# Teleport as a recording gateway

One process running the auth service, the proxy, the SSH service and the
Kubernetes service, recording at the proxy. `teleport.yaml` is the whole
configuration. [sso-and-tiers.md](sso-and-tiers.md) is the file that decides
whether Teleport is usable for you, and it should be read first.

## Why proxy recording

`session_recording: proxy` puts the recorder in the middle rather than on the
target. Two consequences, and both of them are the reason it is the mode
configured here:

- A target does not need a Teleport agent to be recorded. An ordinary OpenSSH
  host, reached through the proxy, is recorded.
- Somebody with root on the target cannot stop the recording or edit it, because
  it was never written there. With node recording, the agent on the compromised
  host is the writer.

What it costs: the proxy decrypts and re-encrypts every session, so it is the
bottleneck and the failure domain, and enhanced recording is not available.
Enhanced recording is eBPF on the node, capturing process execution, file opens
and network connections as structured events, so it needs the node to be the
recorder. `ssh_service.enhanced_recording.enabled` is `false` in `teleport.yaml`
for that reason and not by oversight. If those events matter more than
agent-free targets do, switch to `node-sync` and turn it on, and accept that a
root-compromised host is then recording itself.

## Where recordings land, and playing them back

Under `data_dir`, which is `/var/lib/teleport` here: the session recordings, the
audit log and both certificate authorities. That single directory is the backup
target, and losing it loses the trust roots as well as the evidence.

```bash
tsh login --proxy=gateway.example.com:443
tsh recordings ls                      # session ids, users, times
tsh play <session-id>                  # replay in the terminal
tsh play --format=json <session-id>    # the events, for a report

# Without tsh, on the gateway itself:
ls /var/lib/teleport/log/sessions/
```

Kubernetes sessions replay the same way. A `kubectl exec` through the Kubernetes
service is a recorded session with a session id, which is the capability an HTTPS
proxy in front of the API server does not have.

## First start

```bash
teleport configure --output=file:///etc/teleport/teleport.yaml   # then diff against this one
teleport configure validate --config=/etc/teleport/teleport.yaml
systemctl enable --now teleport

# Create the role first, then the user. Not --roles=editor: editor is Teleport's
# preset for read and write on all cluster configuration, which includes
# session_recording_config, so an operator holding it can turn the recording off
# on the gateway whose job is to record them.
tctl create -f recorded-access-role.yaml
tctl users add example.admin --roles=recorded-access --logins=svc-gateway
# prints a one time enrolment link; WebAuthn registration happens there
```

`recorded-access-role.yaml` is the role that makes the label discipline below
mean something. The `access` preset matches `node_labels: '*': '*'`, so on its own
it grants every host in the cluster regardless of how the labels are set:

```yaml
kind: role
version: v7
metadata:
  name: recorded-access
spec:
  allow:
    logins:
      - svc-gateway
    node_labels:
      environment:
        - example-environment
      tier:
        - example-tier
    kubernetes_labels:
      environment:
        - example-environment
    kubernetes_groups:
      - example-view-only
    rules:
      # Enough to list and replay your own sessions, and nothing that would let
      # this role change how sessions are recorded.
      - resources: [session]
        verbs: [list, read]
  deny: {}
  options:
    max_session_ttl: 8h
    client_idle_timeout: 15m
    disconnect_expired_cert: true
```

The labels in it have to match the ones `teleport.yaml` sets on
`ssh_service.labels` and `kubernetes_service.labels`. A host missing a label then
matches nothing rather than matching a broader rule than intended, which is the
failure direction to prefer.

Cluster administration is a separate account that holds `editor` and never opens
a recorded session, which is consistent with `../../docs/threat-model.md` treating
gateway administrators as inside the trust boundary.

`tctl` only works on the auth service host, which on a single instance is this
host. That is also the reason a single instance is a single point of
administration: if it is down, you cannot add a user to fix it.

## Variables you will want to change

- `auth_service.cluster_name`. It is baked into the certificate authorities on
  first start and **cannot be changed afterwards** without regenerating them,
  which invalidates every issued certificate. Get it right the first time.
- `authentication.webauthn.rp_id` and `proxy_service.public_addr`. Both must be
  the public hostname exactly. A mismatch fails WebAuthn registration with an
  error that does not mention the hostname.
- `session_recording`. `proxy` here. `proxy-sync` streams to the audit backend as
  the session happens, which removes the window where a recording exists only on
  the gateway. It costs a live connection to the backend for the duration of
  every session, and a session fails to start when that connection cannot be
  made.
- `ssh_service.labels`. Roles select hosts by label, and only if a role actually
  selects on them: the `access` preset matches every label, so the labels do
  nothing until a role like the one in First start above scopes them. A host
  missing a label is then a host that matches nothing, which is the failure
  direction to prefer, so keep them mechanical.
- `client_idle_timeout` and `disconnect_expired_cert`. Fifteen minutes and on.
  These are what stop a session outliving the certificate that authorised it.

## Known limitations

- **`editor` can turn the recording off.** The preset grants read and write on all
  cluster configuration, `session_recording_config` included, so
  `session_recording: proxy` is a setting rather than a constraint for anyone
  holding it. The comment on that setting in `teleport.yaml` is advice, not
  enforcement. Hold `editor` on a separate administrative account that never opens
  a recorded session, and treat a change to it as the event the whole design exists
  to notice.
- **Role scoping is a file in this README, not a resource in this repository.**
  `recorded-access-role.yaml` above is a snippet to apply with `tctl create`, and
  nothing here reconciles it afterwards. A role edited in place through `tctl`
  drifts from this document silently. `tctl get roles` is the check.
- **Single instance, so the audit log and availability share a failure domain.**
  One process holds the certificate authorities, the audit log and the
  recordings. A real deployment splits auth from proxy and puts the audit log in
  an external backend.
- **OIDC and SAML sign in are Enterprise.** `type: local` with WebAuthn is what
  the free edition has, and it means a second account lifecycle to run.
  [sso-and-tiers.md](sso-and-tiers.md) has the full tier table.
- **Enhanced recording is off and cannot be on in this mode.** Proxy recording
  and eBPF node recording are mutually exclusive.
- **TLS certificates are not managed here.** `https_keypairs` points at files
  that something else has to put there and renew.
- **Local accounts drift from the directory.** With `type: local`, a leaver
  keeps their Teleport account until someone removes it. Reconcile
  `tctl users ls` against the directory on a schedule.
