# host-baseline

Four Ansible roles that make a host keep its own record of privileged access, so
the gateway recording is not the only evidence that a session happened.

The roles are applied in a fixed order and the order is part of the design:

| Order | Role | What it establishes |
| --- | --- | --- |
| 1 | [sssd](roles/sssd/) | Identity comes from the directory, login is restricted to named groups, sudo goes to a subset of them |
| 2 | [auditd](roles/auditd/) | The audit trail exists before anything starts writing to it |
| 3 | [tlog](roles/tlog/) | Terminal input and output recorded for the privileged groups, forwarded off the host |
| 4 | [pam_tty_audit](roles/pam_tty_audit/) | TTY capture for named privileged accounts, with password capture off |

`sssd` is first because every other role names directory groups and they have to
resolve. `auditd` is second because it stores what `pam_tty_audit` captures and
because it records a change to the recording configuration, so a host that gets
`tlog` first has a window where recording can be reconfigured unobserved.
`pam_tty_audit` is last because it is the role most likely to need backing out.

## Running it

```bash
python3 -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml -p .collections

ansible-playbook -i inventory/example/hosts.yml site.yml --syntax-check
ansible-playbook -i inventory/example/hosts.yml site.yml --check --diff   # always first
ansible-playbook -i inventory/example/hosts.yml site.yml --diff
```

From the repository root, `make syntax`, `make check`, `make ansible-lint` and
`make molecule` do the same things.

A dry run matters more here than on most baselines. Three of these roles edit PAM
or NSS, and on a host reached only through a gateway, breaking PAM breaks the way
in. `site.yml` sets `serial: 25%` and `max_fail_percentage: 0` so a bad change
stops at the first batch.

## Joining the directory

`sssd_join_domain` is `false` everywhere, including in the example inventory. A
join writes an object to the directory that somebody has to clean up later, so it
is opt in per run:

```bash
ansible-playbook -i inventory/example/hosts.yml site.yml \
  --limit app-03.internal.example.com \
  -e sssd_join_domain=true \
  -e @vault/join.yml --ask-vault-pass
```

`sssd_join_password` has no default, the role fails early if a join is requested
without one, and the join task is `no_log: true`.

## Variables you will want to change

Everything host specific is in `inventory/example/group_vars/`. The five that
decide whether this baseline is doing anything:

- `sssd_allowed_groups`. The access control list. A directory account outside
  these groups authenticates and is then refused a session.
- `tlog_record_groups`. Who is recorded. `example-linux-admins` here, so an
  operator who can log in but not elevate is not recorded. That is a policy
  decision with a cost, and the cost is in `../docs/threat-model.md`.
- `pam_tty_audit_enable_patterns`. Accounts whose keystrokes are captured. This
  one is usernames, not groups, because `pam_tty_audit` has no concept of a
  group, so it has to be maintained alongside the group list above.
- `auditd_uid_min`. Every audit rule keys off it. Raising it above an automation
  account's uid is the usual way to cut audit volume, and it is a hole: see
  `docs/audit-volume.md`.
- `auditd_syslog_facility`. `LOG_LOCAL6`, and it has to be a facility
  `syslog_facilities` in `../pipeline/variables.tf` collects. It is in this list
  because getting it wrong is invisible from the host: the audit trail leaves
  correctly, arrives on a facility nothing reads, and the workspace looks like a
  host that is not forwarding.

## Testing

```bash
MOLECULE_DISTRO=rockylinux9 molecule test
MOLECULE_DISTRO=rockylinux8 molecule test
```

What the scenario proves: every file is rendered, owned and moded correctly,
parses, contains the keys the queries in `../pipeline/queries/` select on, and a
second run reports no change.

What it cannot prove, because a container has neither a kernel audit socket nor a
directory: that `auditd` loads the rules, that `sssd` authenticates a directory
user, that `tlog` substitutes a shell, or that `pam_tty_audit` captures a
keystroke. The services are left unmanaged in the scenario for that reason, and
the roles have variables for it rather than the scenario reaching around them.

## Known limitations

- **Recording is a login shell substitution, so it has holes by construction.**
  `ssh host command`, `scp`, `sftp` and port forwarding never get a login shell
  and are not recorded by `tlog`. The `auditd` `execve` rule is what covers them,
  and it records the command and not the session.
- **`pam_tty_audit` cannot express a group.** It matches username globs. The
  account list and the directory group list have to be kept in step by hand.
- **`auditd` is not verified under test.** It cannot run in a container. The
  rules are checked as text, and a syntax error would be caught only at load time
  on a real host, where the symptom is a rule set missing everything after the
  bad line.
- **Credential caching lets a disabled account log in.** Up to
  `sssd_offline_credentials_expiration` days, seven by default. Lower it if leaver
  handling has to be faster than that, and accept what it does to a directory
  outage.
- **Only the RHEL family.** Every package task uses `ansible.builtin.dnf`, and
  the `tlog` and `authselect` paths are RHEL specific. A Debian port is a real
  piece of work, not a variable.
- **Nothing here stops a local account.** `useradd` on the host produces an
  `identity` audit event and a user who is not in the directory, not recorded by
  `tlog`, and not covered by the gateway. The event is the control, which means
  somebody has to be reading the events.
