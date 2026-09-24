# Queries

Ten queries against the workspace `../` creates. One is deployed as an alert; the
rest are run by hand and have `let` parameters at the top that are meant to be
edited before running.

| File | Reads | Answers |
| --- | --- | --- |
| `sessions-by-user-this-week.kql` | `tlog-rec-session` messages | Who was recorded, on what host, for how long |
| `recording-failed-to-start.kql` | sshd accept lines against `tlog` sessions | Which logins produced no recording |
| `sudo-outside-change-windows.kql` | auditd keys `privileged` and `sudoers` | Which elevations happened outside an approved window |
| `activation-then-session.kql` | `AuditLogs` PIM activations against `tlog` sessions | Which activation a session belongs to |
| `recording-config-changed.kql` | auditd key `recording-config` | Did somebody edit the configuration that decides whether sessions are recorded |
| `auditd-silent.kql` | The absence of any event | Did a host that was reporting stop reporting |
| `privileged-commands-by-person.kql` | auditd keys `execve` and `privileged` | What did one person actually run, attributed through `auid` |
| `session-without-gateway.kql` | sshd accept lines | Did somebody reach a host without going through the gateway |
| `sudoers-and-identity-changes.kql` | auditd keys `identity` and `sudoers` | Did the access on a host stop matching what the directory granted |
| `recorded-session-inventory.kql` | `tlog-rec-session` messages | Who is actually being recorded, and how much does it cost |

`recording-config-changed.kql` is the only one deployed as a rule. `../alerts.tf`
reads it from disk with `file()`, so the file here and the deployed alert cannot
drift apart.

The first four are the ones the repository is built around. `recording-failed-to-
start.kql` is the one to run first on a new deployment, because it is the only
query that finds a recorder that is not recording.

## The one thing to know about this schema

auditd events arrive as syslog, which means the whole event is one string in
`SyslogMessage` and nothing upstream parses it into columns. Every field in these
queries is pulled out with `extract` for that reason, not for want of a better
way. If the workspace ever gets a properly parsed audit table, these queries
should be rewritten against it; until then, a change to the auditd message format
breaks them silently, returning fewer rows rather than an error.

`auid` is the field that carries the answer. It is the login uid, it is fixed at
login, and `sudo` and `su` do not change it. A query written on `uid` attributes
every interesting command to `root`.

`tlog` is the other half, and it is different: it writes JSON, so those queries
use `parse_json` and read named fields out of the message body.

The five auditd queries select their events with one shared predicate, declared
identically at the top of each file:

```kusto
let auditPrograms = dynamic(["audispd", "audisp-syslog"]);
| where ProcessName in (auditPrograms)
```

`audisp-syslog` is the ident the current plugin calls `openlog` with and
`audispd` is the older one. The predicate is the program rather than the syslog
facility because the facility depends on the `args` line in
`/etc/audit/plugins.d/syslog.conf`: `LOG_LOCAL6` when
`host-baseline/roles/auditd` has set `auditd_syslog_facility`, and the upstream
default of `user` on a host built any other way. A query written on a facility
list returns nothing against one of those two configurations, which is a silent
failure. Change the predicate in one file and change it in all five, or they
disagree again.

The facility still matters in one place: `syslog_facilities` in `../variables.tf`
is what the data collection rule collects, so a facility missing from that list
never reaches the workspace for any query to read.

## What these queries cannot see

- **The gateway's own session history.** That is in the gateway's database, not in
  this workspace. `session-without-gateway.kql` works around it by treating a
  login from the gateway's address as brokered, which is a heuristic and is
  documented as one in the file.
- **The contents of a recording.** The workspace holds the host's record and the
  metadata. Replaying a session means going to the file on the gateway or on the
  collector, and [../../docs/runbook.md](../../docs/runbook.md) is that procedure.
- **Anything on a host that is not sending.** Which is what `auditd-silent.kql` is
  for, and it reports a gap without reporting a cause.
- **A recording with a hole in it.** A session truncated by a rate limit still
  produces fragments, so it passes `recording-failed-to-start.kql` while being
  incomplete. That is why the rate limits are configured off in the `tlog` role
  rather than monitored from here.
