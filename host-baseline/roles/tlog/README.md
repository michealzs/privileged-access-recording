# tlog

Records terminal input and output on the host itself, for named directory groups
only, and forwards the recordings to a remote collector.

This is the half of the audit trail the gateway does not provide. The gateway
records the session it brokered; `tlog` records the session the host actually
ran, including one opened by somebody who never went through the gateway. When
the two disagree, that disagreement is the finding.

## How the shell substitution works

`tlog` is not a daemon and does not hook the kernel. `sssd` hands recorded users
`/usr/bin/tlog-rec-session` as their login shell, `tlog-rec-session` starts
recording and then executes the real shell from `tlog_shell`. The user cannot
opt out, because the shell they were given is not the one they asked for.

Two consequences follow from that mechanism, and both of them are limits:

- It is a login shell substitution, so it records what goes through a login
  shell. `ssh host command`, `scp`, `sftp` and a port forward do not get one.
- It depends on `sssd` resolving the user. A local account in `/etc/passwd` has a
  shell from `/etc/passwd` and is not recorded by this. The `auditd` rules in the
  `auditd` role are what cover that case, which is why both roles are applied.

## Limiting what is recorded

`tlog_scope` and `tlog_record_groups` are the variables that decide who is
recorded, and `some` plus the privileged groups is the configuration here.
Recording every unprivileged login is a volume problem nobody reads and a
disclosure problem if a recording leaks, so the scope is the privileged groups
and the exclusions are the service accounts.

| Variable | Default | Purpose |
| --- | --- | --- |
| `tlog_scope` | `some` | `none`, `some` or `all` |
| `tlog_record_groups` | `example-linux-admins` | Directory groups recorded. The variable that limits recording |
| `tlog_record_users` | `[]` | Individual users, where a group cannot express it |
| `tlog_exclude_users` | `example-svc-backup` | Never recorded. Service accounts belong here |
| `tlog_exclude_groups` | `[]` | Groups never recorded |
| `tlog_log_input` | `false` | Capture keystrokes. See the warning below |
| `tlog_log_output` | `true` | Capture what the terminal showed |
| `tlog_log_window` | `true` | Capture resizes, so playback geometry is right |
| `tlog_notice` | a one line notice | Shown at the start of every recorded session |
| `tlog_limit_rate` | `16384` | Bytes per second before limiting |
| `tlog_limit_burst` | `32768` | Burst allowance |
| `tlog_limit_action` | `delay` | `pass`, `delay` or `drop` |
| `tlog_latency` | `10` | Seconds buffered before a write |
| `tlog_writer` | `journal` | `journal` or `syslog` |
| `tlog_forward_enabled` | `true` | Forward to a remote collector |
| `tlog_forward_programs` | `tlog-rec-session`, `audisp-syslog`, `audispd` | Syslog programs the forward matches. The audisp entries are auditd's events |
| `tlog_collector_host` | `collector.example.com` | The collector |
| `tlog_forward_tls` | `true` | TLS on the forward, with `rsyslog-gnutls` |
| `tlog_configure_journald` | `true` | Remove journald rate limiting. Read below before turning this off |
| `tlog_manage_services` | `true` | Restart `sssd`, `rsyslog` and `systemd-journald` |

The role fails early if `tlog_scope` is `some` and both lists are empty, because
that configuration records nobody while looking like it records somebody.

## Input capture and passwords

`tlog_log_input` is `false`. Turning it on records keystrokes, and keystrokes
include a password typed into a prompt inside the session: a `sudo` password on
a nested host, a database password, a token pasted into a command line. The
output stream already shows what the operator saw and what the commands did,
which is what a session review needs.

If input capture is switched on anyway, the recordings become secret material.
That means the collector, the journal on every host and every backup of both are
now holding passwords, and the retention policy has to be written on that basis.
The same problem, in a stronger form, is in
[../pam_tty_audit/README.md](../pam_tty_audit/README.md).

## Two silent failure modes

Both of these lose the middle of a recording and report nothing, so they are
configured here rather than left at their defaults.

- **journald rate limiting.** `tlog` writes a recorded session as a stream of
  journal messages. journald's default rate limit discards messages above it and
  logs one suppression line, so a session that produces a burst of output ends up
  with a hole in it. The role writes a journald drop-in setting
  `RateLimitIntervalSec=0`.
- **imjournal rate limiting in rsyslog.** The same problem one layer up, and the
  one with a trap in it. The override has to be applied where `imjournal` is
  actually loaded, which on the RHEL family is `/etc/rsyslog.conf`: that file
  loads the module and then includes `/etc/rsyslog.d/*.conf`, and rsyslog treats a
  second `module(load="imjournal")` in a drop-in as a repeat load of an already
  loaded input module rather than re-reading its parameters. So the role edits the
  existing load in place with `Ratelimit.Interval="0"` and
  `Ratelimit.Burst="0"`, and the drop-in loads the module itself only on a host
  whose main configuration does not. Written the obvious way, the override renders
  into a file, passes a text assertion, and never reaches the running input.
  `rsyslogd -N1` is what confirms it, and the role runs it wherever it manages
  services.

`tlog_limit_action` is the third one, and it is the one that is a real choice.
`drop` keeps the session fast and discards the excess, which silently loses the
moment somebody dumped a large file to the terminal. `delay` keeps every byte and
makes a runaway session visibly slow, which is the trade taken here.

## Reading a recording back

```bash
# On the host, by user and time window.
journalctl -u 'tlog*' --since '2026-09-01 09:00' --until '2026-09-01 18:00'

# Replay a specific session. -M matches on message fields, so "TLOG_USER"
# selects a person and "TLOG_SESSION" a single session.
tlog-play -r journal -M 'TLOG_USER=example.admin'
tlog-play -r journal -M 'TLOG_SESSION=42'
```

`tlog-play` needs the journal entries, so once retention has passed on the host
the playback has to come from the collector. `docs/runbook.md` in the repository
root is the procedure for pulling a session for one user and one time window from
either end.

## Notes

- **Recording stops if `sssd` cannot resolve the user.** During a directory
  outage, cached credentials still let a member of a recorded group log in, and
  `sssd` still applies the shell override from its cache, so recording continues.
  A local account created during that outage is not covered at all.
- **A user can exec a different shell inside a recorded session.** That is fine:
  the recording is of the terminal, not of the process tree, so it captures the
  new shell as well.
- **`tlog` and the gateway recording overlap on purpose.** Two recorders with
  different trust assumptions is the design, not duplication. See
  `docs/threat-model.md`.
- **The forward is one way, and the host cannot read it back.** That is
  deliberate: someone with root on the host can delete the local journal and
  cannot delete what has already left.
- **This role's rsyslog file carries auditd's events too.** `tlog_forward_programs`
  matches the audisp syslog plugin as well as `tlog-rec-session`, because a
  recording and the audit trail of the same session have to leave the host
  together. A second rsyslog file with its own `stop` in it is how one of them
  silently stops leaving, and the file numbering matters: anything sorting after
  `40-tlog-remote.conf` never sees these messages.
