# What this design stops, and what it does not

Recorded, brokered access is a detection and attribution control. It is not
containment. Everything below follows from that, and the second list is longer
than the first on purpose.

## Trust boundaries

| Actor | Inside or outside | Why it matters |
| --- | --- | --- |
| Operator with a directory account | Outside, and recorded | The case the design is built for |
| Operator with root on a target host | Partly inside | Can delete the local journal, cannot delete what has left it, cannot touch the gateway recording |
| Gateway administrator | Inside | Can create a connection with no recording, and can delete recordings on the gateway |
| Directory administrator | Inside, entirely | Can grant themselves any group, disable any policy, and become anyone |
| Collector administrator | Inside for the host half | Holds the only copy of the host recordings that survives the host |
| Break glass account holder | Inside, by design | See `../identity/break-glass.md`. The control is monitoring, not policy |
| Anyone with network access to port 22 on a target | Outside, and partly unrecorded | The gateway is bypassable unless the network says otherwise |

## What it stops

Two of these are conditional and are marked as such. The Conditional Access
entries hold only when `policy_state` is `enabled`, and this repository ships
`enabledForReportingButNotEnforced`, which logs what it would have done and
enforces nothing. Read them as what the policy would stop, not as what it does,
until somebody has changed that value and checked the sign-in logs.

- **An unattributable privileged session.** Authentication is at the directory,
  authorisation is a directory group, and the same identity appears in the gateway
  recording and in the host audit trail. A session with no name behind it requires
  a local account, which produces an `identity` audit event.
- **A privileged session from an unmanaged device.** Conditional to
  `policy_state = enabled`, and the shipped value enforces nothing. Conditional
  Access requires a compliant device for the administrative groups, so a stolen
  password and a phishing resistant factor on somebody else's laptop is not
  enough. In report-only it is recorded and allowed.
- **A phished credential.** Conditional to `policy_state = enabled`, same
  caveat. The authentication strength policy requires a factor bound to the
  origin, and a push notification approved under pressure does not satisfy it. In
  report-only the sign-in log says it would not have satisfied it and the sign in
  succeeds.
- **Standing privilege.** Nobody is permanently in the group that grants gateway
  access. Reaching a host requires an activation with a justification, an approval
  and an expiry, and the activation is a record. The approval part depends on
  `activation_approver_object_ids` naming somebody who is not eligible themselves:
  with an empty list Entra falls back to the group owners and the Privileged Role
  Administrators, which can include the requester. `identity/` refuses that
  combination at plan time, and `../identity/README.md` says why.
- **A session whose privilege has expired.** `sign_in_frequency` at four hours
  means a token issued during an activation stops working after it. Without that,
  PIM expires the assignment and the browser keeps working.
- **Quietly turning the recording off.** The `recording-config` auditd key fires
  on a write to `/etc/tlog/`, `/etc/sssd/`, `/etc/pam.d/`, `/etc/rsyslog.d/` or
  the journald drop-in, and the event is forwarded before anyone can act on it.
- **Deleting the evidence from the host.** Recordings and audit events leave over
  TLS with a disk assisted queue. Root on the host can clear the journal and
  cannot retrieve what has already gone.
- **A target compromise erasing its own session recording.** The gateway is the
  writer. With Teleport that is what `session_recording: proxy` means; with
  Guacamole `guacd` is the writer; with Warpgate the gateway is.
- **A password typed at a prompt landing in the audit log.** `tlog_log_input` is
  false and `pam_tty_audit` runs without `log_passwd`, behind two separate
  variables.

## What it does not stop

- **A directory administrator.** Someone who can edit Conditional Access, add
  themselves to a group or approve their own activation is above every control
  here. The only mitigations are outside this repository: separation of duties on
  the directory roles, PIM on those roles too, and alerting on policy changes.
- **A local Guacamole account.** The schema Guacamole generates creates
  `guacadmin` with a publicly known password and full system administrator
  permissions, and `EXTENSION_PRIORITY=openid` changes the order the providers are
  tried rather than removing the database as an authentication path: the JDBC
  provider still accepts a username and a password at `/api/tokens`. An account in
  that database therefore reaches the gateway without touching Conditional Access,
  PIM activation, phishing resistant multifactor or a compliant device, and as a
  system administrator it can write `guacamole_connection_parameter` and create a
  connection with no recording path. `../gateways/guacamole/README.md` deletes the
  default account during first start and has the query for finding any other local
  account with a password; neither is prevented by configuration, so both are
  things to check.
- **A compromised recorded host forging or misattributing forwarded records.**
  The collector authenticates senders with a certificate name, and the file each
  message lands in is keyed off `%HOSTNAME%`, which the sender chooses. Root on any
  host that holds a certificate the collector accepts can therefore write audit
  events and recording fragments under another host's name. `Computer` in the
  workspace is an assertion by the sender rather than a fact, which matters most
  for `pipeline/queries/auditd-silent.kql`, where the whole answer is per
  `Computer`. The mitigation is scope: issue collector-client certificates from a
  certificate authority that signs nothing else, and list those names rather than
  a wildcard.
- **A gateway administrator creating an unrecorded connection.** In Guacamole,
  recording is a per connection parameter. Somebody who can write
  `guacamole_connection_parameter` can create a connection with no
  `recording-path`. `../docs/runbook.md` has the query that finds those; nothing
  prevents them. Warpgate and Teleport are better here because recording is
  instance wide.
- **A gateway administrator deleting recordings.** Anyone with the Docker daemon
  or root on the gateway can delete the volume. That is why the host half exists
  and why the pruner ships in dry run mode, and it is why recordings should be
  backed up somewhere gateway administrators cannot write.
- **A direct SSH that bypasses the gateway.** Nothing here closes port 22. The
  host still records the session, so it is detected and not prevented, and
  `pipeline/queries/session-without-gateway.kql` is the detection. If bypass has
  to be impossible, that is a network control.
- **Anything without a login shell.** `ssh host command`, `scp`, `sftp` and port
  forwarding never produce a `tlog` recording. The `auditd` `execve` rule records
  the command; nothing records the contents of a transfer or a tunnel.
- **A local account.** `useradd` on the host creates a user `sssd` does not
  resolve, `tlog` does not record and the gateway does not know about. It produces
  an `identity` audit event, which is a control only if somebody reads it.
- **Kernel level tampering.** `auditd` rules are watches on paths. A loaded module
  or a kernel exploit is above them. The `modules` key is the tripwire, and it is
  only a tripwire.
- **A disabled account, immediately.** `sssd_cache_credentials` is on, so a
  directory user who has been disabled can still log in from cache for up to
  `sssd_offline_credentials_expiration` days. Lowering it trades that for hosts
  that lock out during a directory outage.
- **An attacker who stops auditd before touching anything.** Then there is no
  event to catch, and the only signal is absence.
  `pipeline/queries/auditd-silent.kql` is that signal, and it reports a gap
  without reporting a cause.
- **A recording with a hole in it.** journald and rsyslog rate limiting both
  discard messages silently. The roles configure both limits off, and if either is
  reverted, the recording is incomplete and nothing says so.
- **A secret typed where the terminal echoes.** A token on a command line is in
  the recording and in the `execve` audit event, whatever `log_passwd` says.
  Treat the recordings and the workspace as sensitive on that basis.
- **Somebody reading a recording they should not.** The workspace and the gateway
  hold the contents of privileged terminals. Access control on both is outside this
  repository, and it is at least as important as the recording itself.

## The assumptions the whole thing rests on

Four, and each one is a thing to check rather than a thing to believe.

1. **The identity in the gateway recording and the identity on the host are the
   same string.** If the OIDC username claim and `sssd`'s username format
   disagree, both halves of the trail exist and cannot be joined. See
   `architecture.md`.
2. **The forward works.** A host whose rsyslog queue has been failing for a week
   has a complete local journal, an empty workspace, and nothing reporting the
   difference until somebody runs `auditd-silent.kql`.
3. **Somebody reads the queries.** Every control in the second list is a detection.
   An alert with no action group, or a query nobody runs, converts this design back
   into a compliance artefact.
4. **The policies are enforcing.** `policy_state` ships as
   `enabledForReportingButNotEnforced`. Everything the first list says about
   Conditional Access is true of an enforcing policy and of nothing else, and the
   only way to know which one is deployed is to look. `terraform output
   policy_state` is the shortest way.
