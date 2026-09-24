# sssd

Joins the host to an enterprise directory, restricts login to named directory
groups, and grants sudo to a subset of them.

This role is underneath everything else in `host-baseline/`. The gateway records
a session and labels it with a directory identity; `auditd` and `tlog` on the
host record the same session and label it with a Unix uid. Those two labels are
only the same person because the host resolves users from the same directory the
gateway authenticates against. Local accounts break that, which is why
`sssd_allowed_groups` is the access control list and not a convenience.

## What it does

1. Installs the directory client packages, `realmd` and `authselect` included.
2. Reads the current realm membership and joins the realm only when asked to and
   only when not already joined.
3. Selects the `sssd` authselect profile with `with-mkhomedir`, so PAM and NSS
   are configured by authselect rather than by hand edited PAM files.
4. Writes `/etc/sssd/sssd.conf`, validated with `sssctl config-check` before it
   is installed, mode 0600 because sssd refuses to start otherwise.
5. Writes a sudoers drop-in for the admin groups, validated with `visudo -cf`
   before it is installed.
6. Enables `sssd` and `oddjobd`.

## Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `sssd_realm` | `EXAMPLE.COM` | Kerberos realm, upper case |
| `sssd_domain` | `example.com` | Directory domain as the directory writes it |
| `sssd_join_domain` | `false` | Whether the role may run `realm join` |
| `sssd_join_account` | `example-join-account` | Account permitted to create computer objects |
| `sssd_join_password` | `""` | Pass from a vault. Empty by default and must stay that way |
| `sssd_join_computer_ou` | `""` | OU for the computer object, empty for the default container |
| `sssd_allowed_groups` | two example groups | Groups allowed to log in. The access control list |
| `sssd_sudo_groups` | one example group | Groups granted sudo. Must be a subset of the above |
| `sssd_sudo_commands` | `ALL` | Command set in the sudoers drop-in |
| `sssd_sudo_nopasswd` | `false` | Passwordless sudo. Leave it off |
| `sssd_ldap_id_mapping` | `true` | Generate POSIX ids from the directory SID |
| `sssd_use_fully_qualified_names` | `false` | Short usernames, to match the gateway's claim |
| `sssd_cache_credentials` | `true` | Allow offline authentication from cache |
| `sssd_offline_credentials_expiration` | `7` | Days a cached credential is accepted |
| `sssd_enumerate` | `false` | Walk the whole directory for `getent passwd`. Slow, and not needed |
| `sssd_validate_config` | `true` | Run `sssctl config-check` before installing the file |
| `sssd_manage_services` | `true` | Start and enable `sssd` and `oddjobd` |

`sssd_join_password` has no real default and the role fails early if
`sssd_join_domain` is true and it is empty. The join task is `no_log: true`.

## Notes

- **The username format has to match the gateway.** With
  `sssd_use_fully_qualified_names: false` the host sees `example.admin`. The
  gateway's OIDC username claim has to produce the same string, or a recording
  filename and a host audit event about the same session cannot be joined. That
  correlation is the whole point of running both.
- **`sssd_allowed_groups` is enforced by the simple access provider.** A
  directory account outside those groups authenticates successfully and is then
  refused a session. That is the intended behaviour and it looks like a broken
  login to the user, so say so in the access request process.
- **Credential caching cuts both ways.** It is why a directory outage does not
  lock every host at once. It is also why a disabled account can still log in for
  up to `sssd_offline_credentials_expiration` days. Seven days is a starting
  point; if leaver handling has to be faster than that, lower it and accept the
  outage behaviour.
- **`ldap_id_mapping` cannot be changed later.** Flipping it on a host that
  already has files owned by mapped uids orphans every one of them. Decide once,
  per estate.
- **`realm join` is off by default.** A join is a write to the directory and it
  creates an object somebody has to clean up. Turn it on deliberately, for the
  hosts being built, and leave it off for configuration re-runs.
- **A sudoers syntax error locks sudo for everybody.** The `validate` on that
  task is the only thing standing between a bad template change and a host that
  needs console access to recover.
