# auditd

The host's own audit trail. It exists so that the gateway recording is not the
only evidence, and it is written on the assumption that somebody with root on
this host is trying to remove it.

## What it records

Six keys, and they are the keys the queries in `pipeline/queries` select on.
Renaming one here breaks a query there.

| Key | Rule | What it answers |
| --- | --- | --- |
| `execve` | Every command run by a real user, both architectures | What did they actually do |
| `identity` | Writes to `passwd`, `group`, `shadow`, `gshadow`, `opasswd` | Did somebody create or change an account |
| `sudoers` | Writes to `/etc/sudoers` and `/etc/sudoers.d/` | Did somebody grant themselves more than the directory did |
| `privileged` | Execution of `sudo`, `su`, `passwd`, `usermod` and the rest | Who elevated, cheaply queryable |
| `modules` | `init_module`, `finit_module`, `delete_module`, and the module tools | Did somebody load a kernel module |
| `recording-config` | Writes under `/etc/tlog/`, `/etc/sssd/`, `/etc/pam.d/`, `/etc/rsyslog.d/`, `/etc/systemd/journald.conf.d/` | Did somebody turn the recording off |
| `audit-config` | Writes under `/etc/audit/` | Did somebody edit the auditing |

`auid`, not `uid`, is what every rule keys off. `auid` is the login uid and it
survives `su` and `sudo`, so an event is attributed to the person who logged in
rather than to the account they became. `auid!=unset` excludes processes with no
login uid, which is every daemon started at boot.

The events leave the host through the audisp syslog plugin, which this role
switches on with `auditd_forward_to_syslog` and points at a facility with
`auditd_syslog_facility`, and then through the rsyslog forward
the `tlog` role writes: `tlog_forward_programs` matches the plugin as well as
`tlog-rec-session`, so a recording and the audit trail of the same session leave
together. `../../../pipeline/agent/audisp-syslog.conf` is the reference for the
whole plugin file.

Both lines of that plugin file are managed, and the second one is the one that is
easy to miss. The shipped file is `args = LOG_INFO`, which names no facility, and
with no facility named `audisp-syslog` never calls `openlog()`: every event then
arrives on the default facility of `user`, under the ident `audisp-syslog` rather
than `audispd`. A host configured that way forwards a complete audit trail to a
facility the data collection rule in `../../../pipeline/` does not collect, which
from the workspace looks exactly like a host that is not forwarding at all. That
is why `auditd_syslog_facility` exists and why the molecule scenario asserts the
rendered `args` line and not only `active = yes`.

The last two keys are the ones that make this more than a compliance checkbox.
They also have a limit that cannot be fixed with a rule: an attacker who edits
the recording configuration and then stops `auditd` has generated the event, and
one who stops `auditd` first has not. That ordering is why
`auditd_forward_to_syslog` is on and why the events leave the host.

## Volume

One rule in this set is an order of magnitude louder than the others.
[../../docs/audit-volume.md](../../docs/audit-volume.md) has the per rule
estimate, what drives each number, and what to do when the volume is too much.
Read it before setting retention or a daily ingestion cap.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `auditd_uid_min` | `1000` | Lowest uid treated as a real person. Every rule keys off it |
| `auditd_log_execve` | `true` | The command rule. The loudest one |
| `auditd_privileged_commands` | twelve binaries | Executions recorded on their own key |
| `auditd_watch_identity` | five files | Identity file watches |
| `auditd_watch_sudoers` | two paths | sudoers watches |
| `auditd_watch_recording_config` | five directories | The recording configuration |
| `auditd_watch_audit_config` | two directories | The audit configuration |
| `auditd_log_kernel_modules` | `true` | Module load and unload |
| `auditd_extra_rules` | `[]` | Raw rules appended verbatim |
| `auditd_immutable` | `false` | Add `-e 2`. Rules then need a reboot to change |
| `auditd_forward_to_syslog` | `true` | Enable the audisp syslog plugin |
| `auditd_syslog_facility` | `LOG_LOCAL6` | The facility the plugin writes to. Named, or nothing collects the events |
| `auditd_syslog_priority` | `LOG_INFO` | The priority the plugin writes at |
| `auditd_conf_settings` | see below | Applied to `auditd.conf` |
| `auditd_manage_service` | `true` | Start `auditd` and load rules |

## The auditd.conf settings worth arguing about

- **`log_format: ENRICHED`.** Resolves uids, gids and names at write time, so an
  event still reads correctly after the account is deleted or once the log is
  being read somewhere other than the host that wrote it. It costs disk. On a
  host whose logs are forwarded, it is not optional.
- **`admin_space_left_action: SYSLOG`.** This is the availability decision. When
  the audit partition is nearly full, `SYSLOG` complains and keeps the host
  working, accepting a gap in the trail. `SINGLE` drops to single user mode and
  `HALT` stops the host, keeping the trail complete and taking the host out of
  service. `SYSLOG` is chosen here because a brokered access host that halts
  itself denies access to the people who would fix it, and because the forward
  means the events up to that point have already left. If the requirement is that
  the trail must never have a gap, change this and size the partition for it.
- **`flush: INCREMENTAL_ASYNC` with `freq: 50`.** A compromise. `SYNC` writes
  every event to disk before continuing and is measurably slow; asynchronous
  flushing every 50 records loses at most 50 records if the host dies abruptly.
- **`name_format: HOSTNAME`.** Puts the hostname in every event, which the
  collector needs and the local reader does not.
- **`auditd_immutable: false`.** `-e 2` is the right end state: nothing, not even
  root, can change the loaded rules until a reboot. It also means this role
  cannot reload rules on a re-run, so turn it on once the rule set has settled
  and expect to reboot to change it.

## Notes

- **`systemctl restart auditd` does not work on the RHEL family.** The unit sets
  `RefuseManualStop`. The handlers here use `state: reloaded`, which runs the
  unit's `ExecReload` and sends SIGHUP, and `augenrules --load` for the rules.
  A rule change is therefore two separate reload paths, not one restart.
- **There is no way to validate the rule file before loading it.** `auditctl -R`
  is the only thing that parses this syntax, and it loads the rules rather than
  checking them, so it cannot be used as a `validate` without applying a half
  written file. A syntax error is caught at load time, and the symptom is a rule
  set that is missing everything after the bad line.
- **`auditd` cannot run in a container.** It needs the kernel audit netlink
  socket, which a container does not have. The molecule scenario renders and
  reads the rule file and never starts the service, so the rules are checked as
  text and not as loaded rules. That gap is named in the repository README.
- **The `-w` watches are on paths, so a bind mount or a hard link can dodge
  them.** They are a tripwire, not containment.
