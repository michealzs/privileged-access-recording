# pam_tty_audit

Captures TTY input for named privileged accounts, through the `pam_tty_audit`
PAM module and the kernel's TTY auditing. The captured data goes into the audit
log and is read back with `aureport --tty`.

This is the narrowest and most dangerous recorder in the repository. Read the
warning before enabling it anywhere.

## Warning: this can capture passwords

TTY auditing captures what was typed. A password typed into a prompt is what was
typed.

The module's behaviour is specific, and the specifics are what make a safe
configuration possible:

- **Without `log_passwd`, input is not recorded while the terminal has echo
  disabled.** A well behaved password prompt, such as `sudo`'s or `ssh`'s,
  disables echo, so the password is not captured. That is the default and it is
  what this role configures.
- **With `log_passwd`, echo state is ignored and passwords are captured.** Every
  audit log on the host, everything the audit log is forwarded to, and every
  backup of either then contains passwords in clear text.
- **Even without `log_passwd`, a secret typed where echo is on is captured.** A
  token pasted onto a command line, `mysql -p<password>` typed inline, an API key
  echoed into a heredoc: all of those are recorded, because the terminal never
  disabled echo. No PAM setting prevents it. The control for that is telling
  operators that command lines are recorded, and treating the audit log as
  sensitive regardless.

### How to configure it so it does not capture passwords

That is the default configuration of this role, and it is three things:

1. `pam_tty_audit_log_passwd: false`. This is the only variable that decides
   whether echo-off input is captured.
2. `pam_tty_audit_allow_log_passwd: false`. A second, separate acknowledgement.
   The role fails if `log_passwd` is true and this is not, so an inherited
   `group_vars` file cannot turn password capture on quietly. Setting both takes
   a deliberate edit in the inventory with a comment saying who decided it.
3. `pam_tty_audit_disable_patterns: ["*"]` first, with the enable patterns after
   it, so capture is off for everybody except the accounts named.

If `log_passwd` is ever switched on, the audit log becomes secret material and
the retention, the forwarding and the access control on it all have to be
rewritten on that basis. There is no partial version of that change.

## Patterns are usernames, not groups

`pam_tty_audit` matches **username glob patterns**. It has no concept of a group,
so "the admins group" cannot be expressed here, and this is the one place in
`host-baseline/` where the group based model does not reach.

Three ways out, in order of preference:

1. Name the accounts. Short lists are honest and reviewable, and a joiner who is
   missing from the list is a gap somebody can see.
2. Use a username convention and a glob, such as `adm-*`, and write the
   convention down in the access process. A convention nobody enforces is a
   capture that silently misses people.
3. Leave it at `root` only, and rely on `tlog` for named users. `tlog` does
   understand directory groups, and `sudo` to root is already covered by the
   `auditd` rules.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `pam_tty_audit_enabled` | `true` | Add or remove the managed block |
| `pam_tty_audit_enable_patterns` | `root`, `example.admin` | Username globs whose input is captured |
| `pam_tty_audit_disable_patterns` | `*` | Evaluated first, so capture is off by default |
| `pam_tty_audit_log_passwd` | `false` | Capture input while echo is off. See above |
| `pam_tty_audit_allow_log_passwd` | `false` | The second switch. Both must be true |
| `pam_tty_audit_open_only` | `false` | Leave the audit flag set when the session ends |
| `pam_tty_audit_services` | `sshd`, `login`, `su`, `sudo` | PAM stacks the module is added to |
| `pam_tty_audit_module_paths` | three usual paths | Checked before a `required` line is written |

## What it writes

A marked block appended to each existing PAM service file:

```
# BEGIN ANSIBLE MANAGED BLOCK pam_tty_audit
session required pam_tty_audit.so disable=* enable=root,example.admin
# END ANSIBLE MANAGED BLOCK pam_tty_audit
```

Files that do not exist are skipped, never created, because creating a PAM file
is how a host stops accepting logins. Before writing anything the role checks
that `pam_tty_audit.so` is actually installed, because a `required` line naming a
missing module fails every session in that stack and the first symptom is that
nobody can log in.

Test it on one host, with a second session already open, before applying it to
anything you cannot reach the console of.

## Reading captures back

```bash
aureport --tty                        # every captured TTY session
aureport --tty --start today
ausearch -m TTY -ts today -i          # the raw events, interpreted

# For one user, over a window.
ausearch -m TTY -ua example.admin -ts '09/01/2026 09:00:00' -i
```

`aureport --tty` decodes the keystrokes into readable text. Assume anything in
there could have been a secret typed into an unlucky prompt, and hold it
accordingly.

## Notes

- **This is not session recording.** It is keystrokes, with no output and no
  timing. It answers "what did they type", and `tlog` answers "what did they see
  and what happened". They are complementary, and `tlog` is the one to deploy
  first.
- **It needs `auditd` running to store anything.** The `auditd` role is applied
  after this one for that reason.
- **PAM files are package owned.** An `openssh-server` upgrade can replace
  `/etc/pam.d/sshd` and leave the previous file as `.rpmsave`, taking the managed
  block with it. Re-running the role restores it; nothing warns you in between.
- **`su` and `sudo` stacks are included.** That is where a privilege change
  happens, so it is where the capture matters most, and it is also where a
  password prompt lives. The echo-off behaviour above is what makes including
  them safe.
