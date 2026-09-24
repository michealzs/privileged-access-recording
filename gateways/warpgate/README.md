# Warpgate as a recording gateway

One static binary, one configuration file, one SQLite database. Warpgate is the
smallest thing in this repository that can front SSH, HTTPS and a Kubernetes API
server behind directory sign in and record what happened. It is also the one
whose recording coverage is most uneven, and that unevenness is the reason it is
here next to Guacamole and Teleport rather than instead of them.

## Which protocols record, and which do not

This is the table to read before choosing Warpgate. Recording is switched on for
the whole instance under `recordings:`, so there is no per target setting to
forget, but it does not apply to every protocol it proxies.

| Target kind | What reaches the target | What is recorded |
| --- | --- | --- |
| `Ssh` | Interactive shell, in a terminal | Terminal input and output as an asciicast, plus a session log entry with the Warpgate user, the target and the times |
| `Ssh`, SFTP or `scp` subsystem | File transfer over the same connection | The session log entry only. No file contents and no per file list in the recording |
| `Ssh` with port forwarding | A TCP tunnel | The session log entry only. Bytes inside the tunnel are not recorded, and cannot be |
| `Http` | HTTPS requests, proxied | Request level log entries. No session recording, and no response bodies |
| `Http`, Kubernetes API server | `kubectl` against the proxy URL | Request level log entries. `kubectl exec` into a pod is a request to the API server here, so the shell inside the pod is not recorded |
| `MySQL` | SQL over the MySQL protocol | Session log entry. Disabled in this configuration |
| `WebAdmin` | Warpgate's own admin UI | Request level log entries, same as any HTTP target |

The line that matters: **only SSH sessions produce a replayable recording.** For
HTTPS and Kubernetes you get an access log, which answers "who reached what and
when" and does not answer "what did they do". If `kubectl exec` has to be
recorded, the gateway is the wrong layer for it and a Kubernetes aware proxy such
as Teleport's Kubernetes service is what does that.

The Kubernetes target above is an `Http` target pointed at the API server. That
works, and it is honest about what it is: TLS terminated at the gateway, requests
logged, authorisation still done by the cluster.

## What is in this directory

`warpgate.yaml` is the whole configuration: listeners, recording, the SSO
provider, two example users, four roles and five targets. There is no
`docker-compose.yml` here because Warpgate deploys as a binary with a systemd
unit and a data directory, and wrapping it in a container adds a layer without
removing one.

```bash
warpgate --config warpgate.yaml check          # parses and validates
warpgate --config warpgate.yaml setup          # first run, generates keys and TLS
systemctl start warpgate
```

`/var/lib/warpgate/` then holds the database, the SSH host keys, the TLS pair and
the recordings. All four are excluded from git.

## Recording storage and retention

Recordings are written under `recordings.path`. `log.retention` is not recording
retention: it prunes Warpgate's own session log rows and leaves every file in
place. Nothing in Warpgate deletes recordings, so a retention job is yours to
write, and the one in `../guacamole/prune-recordings.sh` works unchanged against
this directory.

Playback is in the admin UI, session by session. The files are asciicasts, so
`asciinema play` reads them directly without Warpgate running, which is worth
confirming once before relying on it.

## Variables you will want to change

- `external_host`. It goes into the URLs Warpgate generates and into the OIDC
  redirect, and a wrong value produces a sign in loop with no error.
- `ssh.host_key_verification`, `prompt` here. On a gateway with nobody at the
  console this blocks the first connection to each target until someone answers
  it. Pre-seed the host keys and only then consider `auto`.
- `http.trust_x_forwarded_headers`, `false` here. Turn it on only when a proxy
  in front is stripping and setting those headers itself, because with it on and
  nothing in front, a client chooses its own source address in the audit trail.
- `users[].credentials[].email`. Warpgate matches an SSO login against this
  address. It has to be the address the directory releases and the one `sssd`
  reports on the hosts, or the two halves of the audit trail cannot be joined.
- `targets[].options.username`, `svc-gateway` here. This is the account on the
  target, shared by everyone who reaches it through the gateway. The host audit
  trail will therefore show `svc-gateway` and not the human, which is exactly why
  `host-baseline/` exists and why the correlation runs on time and host.

## Known limitations

- **The client secret is in the configuration file.** Warpgate reads the OIDC
  client secret from `warpgate.yaml`, so the deployed copy is secret material
  even though the committed copy is not. Mode 0600, owned by the service
  account.
- **Warpgate writes to its own configuration file.** Adding a target or a user
  in the admin UI rewrites `warpgate.yaml`. Managing it from git and from the UI
  at the same time means one of them loses.
- **SQLite.** One file, one host, no replication. It is enough for a gateway,
  and it means the audit trail and the availability of the gateway have the same
  single point of failure.
- **Target accounts are shared.** Authentication is per person at the gateway
  and per service account at the target. Nothing in Warpgate maps a directory
  user to a distinct Unix account.
- **No high availability story here.** One instance, one SQLite file. See
  `../comparison.md` for what each of the three options does when it is down.
