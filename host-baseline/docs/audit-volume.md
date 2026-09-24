# What each audit rule costs

Every rule in `roles/auditd/templates/privileged-access.rules.j2` produces
events, and the events are forwarded, stored and paid for. One rule produces
almost all of it.

The numbers below are order of magnitude, for sizing a disk and a daily cap, not
measurements of any particular host. The measurement commands are at the bottom
and they are the only numbers worth planning around.

## Event size first

With `log_format: ENRICHED`, one audited command is not one line. It is a group
of records that share an event id:

| Record | What it holds |
| --- | --- |
| `SYSCALL` | The syscall, the uid, the `auid`, the exit code, the resolved names ENRICHED adds |
| `EXECVE` | The arguments, one field per argument |
| `CWD` | The working directory |
| `PATH` | One record per path the syscall touched, so usually two or three |
| `PROCTITLE` | The command line, hex encoded |

A short command is roughly 1 KB across those records. A long one, an `ansible`
module invocation or a `find` with many arguments, is several KB because the
argument list is in there verbatim. `ENRICHED` adds perhaps 20 per cent over
`RAW`, and it is worth it the moment the log is read anywhere other than the host
that wrote it.

## Per rule

| Key | Trigger | Rate to expect | Why |
| --- | --- | --- | --- |
| `execve` | Every command run by a uid at or above `auditd_uid_min` with a login uid | Dominant. Hundreds to tens of thousands of events per day per host | It is one event per command, and the count follows what people and their tools run, not how much traffic the host serves |
| `privileged` | Execution of the twelve binaries in `auditd_privileged_commands` | Tens per day per active admin | A duplicate of events `execve` already produced, on a separate key |
| `sudoers` | Writes under `/etc/sudoers` and `/etc/sudoers.d/` | A handful per configuration run, otherwise zero | Ansible touches these files, so a baseline run generates a burst |
| `identity` | Writes to `passwd`, `group`, `shadow`, `gshadow`, `opasswd` | Near zero on a directory joined host | Local accounts should not be changing. Any event here is worth reading |
| `recording-config` | Writes under `/etc/tlog/`, `/etc/sssd/`, `/etc/pam.d/`, `/etc/rsyslog.d/`, `/etc/systemd/journald.conf.d/` | A burst per configuration run, otherwise zero | The burst is the problem: it makes the signal look like noise. See below |
| `audit-config` | Writes under `/etc/audit/` | Same shape as above | Same problem, same answer |
| `logins` | Writes to `lastlog` and the faillock directory | One or two per login | Small events, and the count is bounded by how many people log in |
| `modules` | Module load and unload, and the module tools | Near zero outside a kernel upgrade | High value per event for that reason |

## The two problems worth planning for

**`execve` is nearly all of it, and configuration management is nearly all of
`execve`.** An interactive admin session is a few hundred commands. A single
Ansible run against the host, connecting as a directory user, is every module
invocation, every `python3` call and every shell probe, each as an audited
command with its full argument list. On a host that is configured daily and
touched by a human weekly, the automation produces more audit volume than the
humans do.

Three ways to deal with that, in order of how much they cost you:

1. Keep it. It is a complete record, and if a compromise arrives through the
   configuration management path, this is the only place it will be visible.
2. Raise `auditd_uid_min` above the automation account's uid, or give the
   automation a uid below it. This is cheap and it is a real hole: anything run
   by that account is now unaudited, including anything that reaches it.
3. Add a targeted `-a never,exit` rule for the automation's binary path to
   `auditd_extra_rules`. Narrower than the second option and still a hole, and it
   should be reviewed whenever the automation changes.

There is no fourth option where the volume goes away and the coverage does not.

**The configuration watches fire when you configure the configuration.** Applying
`site.yml` writes to `/etc/sssd/`, `/etc/pam.d/`, `/etc/tlog/` and
`/etc/audit/`, so every baseline run produces a burst of `recording-config` and
`audit-config` events. The query that matters, "did somebody change the recording
outside a change window", is in
[../../pipeline/queries/sudo-outside-change-windows.kql](../../pipeline/queries/sudo-outside-change-windows.kql)
and it works by excluding the window, not by excluding the account. Excluding the
automation account would exclude exactly the events an attacker using that
account would generate.

## Measure it

Two commands, on a host that has been running the rules for a day.

```bash
# Events per key over the last day, biggest first. This is the number that
# decides retention.
aureport --key --summary --start yesterday

# Bytes per day, from the log itself.
ls -l /var/log/audit/
ausearch --start today --raw | wc -c
```

Then size from there:

- `max_log_file: 100` and `num_logs: 10` in `auditd_conf_settings` is a 1 GB
  ceiling on `/var/log/audit/`. If a day of events is larger than that, the local
  log holds less than a day and everything depends on the forward having worked.
- The forward is what retention is really about. The local log is a buffer.
- `space_left: 500` and `admin_space_left: 200` are megabytes free on the audit
  partition, and both actions are `SYSLOG` here. That choice keeps the host
  working and accepts a gap; `roles/auditd/README.md` has the argument for and
  against.

## What none of this measures

The audit log does not include the session recording. `tlog` output goes to the
journal and is forwarded separately, and it is much larger per session than the
audit events for the same session: a recording is every byte the terminal showed.
Size the journal and the collector for that separately, and see
`roles/tlog/README.md` for the rate limits that quietly drop it when they are
left at their defaults.
