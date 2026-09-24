# Choosing a recording gateway

Three options, configured for real in the directories next to this file. This is
the comparison that was made to pick one, written as criteria rather than as a
verdict, because the answer changes with the constraint and none of these is
wrong everywhere.

What is not in the table: how any of them behaved under load in a particular
deployment. Nothing here is a performance claim.

## Protocols covered

| | Guacamole 1.5.5 | Warpgate | Teleport, Community |
| --- | --- | --- | --- |
| SSH | Yes, in the browser | Yes, with a native client | Yes, with `tsh` or OpenSSH |
| RDP | Yes | No | No |
| VNC | Yes | No | No |
| HTTPS to an internal web app | No | Yes | Enterprise, as an app |
| Kubernetes API | No | As an HTTPS target | Yes, natively |
| MySQL or Postgres | No | MySQL only | Enterprise, as a database |
| Native client, no browser | No | Yes, `ssh user:target@gateway` | Yes |

Guacamole is the only one of the three that does RDP and VNC. If Windows or a
graphical console is in scope, the comparison is over before it starts.

## Recording fidelity

| | Guacamole | Warpgate | Teleport |
| --- | --- | --- | --- |
| Graphical sessions | Full protocol stream, replays in the browser, converts to video with `guacenc` | Not applicable | Not applicable |
| Terminal sessions | Typescript plus timing file, replays with `scriptreplay` | asciicast, replays in the UI and with `asciinema` | Native format, replays with `tsh play` |
| Structured command events | No | No | Yes, per session events. Per command only with node recording and eBPF |
| Kubernetes exec | Not applicable | No, request log only | Yes, recorded as a session |
| File transfer contents | No | No | No |
| Port forwarded traffic | No | No | No |
| Recording switched on per | Connection, in the database | Instance, in the config file | Cluster, in the config file |
| Can the target suppress it | No, `guacd` is the writer | No, the gateway is the writer | Not with `proxy` mode. Yes in principle with `node` mode |

The per-connection row is the one that bites. In Guacamole, a connection created
without `recording-path` produces a session with no recording and nothing warns
you. Warpgate and Teleport switch recording on for the whole instance, so the
same mistake is not available.

## Single sign on, and what it costs

| | Guacamole | Warpgate | Teleport |
| --- | --- | --- | --- |
| OIDC against an enterprise directory | Yes, bundled extension, free | Yes, built in, free | Enterprise only |
| SAML | Yes, bundled extension, free | No | Enterprise only |
| GitHub as the directory | Through OIDC | Through OIDC | Yes, free |
| Local accounts as the fallback | Yes, in the database | Yes, in the config | Yes, with WebAuthn |
| Enforced multifactor | At the directory | At the directory | At the directory, or WebAuthn locally |
| Group claims drive authorisation | Yes | Through role mappings | Through roles, free |
| Time bound elevation with approval | No | No | Enterprise, as Access Requests |
| Compliant device required | No | No | Enterprise, as Device Trust |

For a team whose directory speaks OIDC and whose budget is zero, this table is
the decision: Guacamole and Warpgate do directory sign in in the free build and
Teleport does not. [teleport/sso-and-tiers.md](teleport/sso-and-tiers.md) is the
detail, including what changes once there is budget.

Note what none of the three free builds has: elevation that is time bound and
approved. That is why `../identity/` puts it in the directory with PIM rather
than in the gateway, where it would have to be bought three times.

## Self hosting effort

| | Guacamole | Warpgate | Teleport |
| --- | --- | --- | --- |
| Components to run | Three, plus a database schema to generate | One binary, one SQLite file | One binary, one data directory |
| Deployment shape here | `docker-compose.yml`, four containers | Binary plus systemd unit | Binary plus systemd unit |
| Needs a reverse proxy for TLS | Yes | No, terminates TLS itself | No, terminates TLS itself |
| Certificate authority to manage | No | Host keys only | Yes, two CAs, generated on first start |
| Upgrade care | `guacenc` must match the version that wrote a recording | Config file is rewritten by the UI | `cluster_name` is fixed at first start forever |
| Client software on the operator's machine | None, a browser | None, `ssh` | `tsh`, or OpenSSH with a config |
| Retention job included | Written here, `prune-recordings.sh` | No, nothing prunes recordings | No, external backend or a job |

Guacamole is the most moving parts and the least surprising: three well known
containers and a Postgres schema. Warpgate is the least to run and the most
likely to fight a git workflow, because the admin UI rewrites the config file
you committed. Teleport is one binary that is also a certificate authority, and
the irreversible `cluster_name` is the detail to get right before the first
start.

## When the gateway is down

This row decides more architectures than the protocol list does.

| | Guacamole | Warpgate | Teleport |
| --- | --- | --- | --- |
| Can anyone reach the targets | Only by direct SSH, if that is still allowed | Only by direct SSH, if that is still allowed | Only by direct SSH, if that is still allowed |
| Sessions already open | Dropped, `guacd` is in the path | Dropped, the gateway is in the path | Dropped, the proxy is in the path |
| Recordings written so far | Kept, on the gateway's volume | Kept, on the gateway's disk | Kept, under `data_dir` |
| Recordings reachable while it is down | Yes, the files are on disk. `guacenc` needs the image | Yes, asciicasts replay without Warpgate | Yes, under `data_dir`. `tsh play` needs the proxy |
| Can a new user be granted access | No, the database is behind the web app | No, editing the config needs a restart anyway | No, `tctl` needs the auth service |
| What the host still records | `auditd` and `tlog`, independently | `auditd` and `tlog`, independently | `auditd` and `tlog`, independently |

All three are in the path, all three drop live sessions, and none of them lets
you fix access while it is down. That is a property of brokered access, not of
any one product, and it is why two things in this repository are not optional:
a documented break glass path that does not go through the gateway, in
[../docs/runbook.md](../docs/runbook.md), and the host's own audit trail in
`../host-baseline/`, which keeps recording when the gateway cannot.

## Which one fits which constraint

- **Windows, RDP or a graphical console is in scope.** Guacamole. The other two
  do not proxy RDP at all.
- **Directory sign in over OIDC or SAML, and no budget.** Guacamole or Warpgate.
  Teleport's OIDC and SAML connectors are Enterprise.
- **Terminal access only, smallest thing that works, native `ssh` client.**
  Warpgate. One binary, recording on for the whole instance, no per connection
  setting to forget.
- **`kubectl exec` has to be recorded as a session.** Teleport. Warpgate's HTTPS
  target in front of the API server logs the request and does not record the
  shell, and Guacamole does not speak to an API server at all.
- **Per command events, not just a terminal stream.** Teleport with node
  recording and eBPF, accepting that the recorder then runs on the host being
  recorded. Or `tlog` and `auditd` from `../host-baseline/`, which is where this
  repository puts that requirement.
- **The directory is GitHub.** Teleport Community, where the GitHub connector is
  free and brings RBAC and per session multifactor with it.
- **Elevation must be time bound and approved.** None of the three free builds.
  `../identity/` does it in the directory, which also covers the gateways
  themselves.
- **Config must live in git and stay there.** Guacamole or Teleport. Warpgate's
  admin UI rewrites its own configuration file.

The fullest configuration in this repository is the Guacamole one, because it is
the option whose constraints are hardest to work around: graphical protocols and
free OIDC narrow the field to one before anything else is weighed. That is which
row of the table is binding, not a ranking of the three products, and a team
whose first row is `kubectl exec` reads the same table to a different answer.
