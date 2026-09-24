# Runbook

Two procedures. Pulling the record of what one person did on one host in one time
window, and working when the gateway is down.

## Pulling a session for a user and a time

Start with what you have. The four sources are independent and you will usually
end up in more than one.

### 1. Find out whether a session exists at all

```kusto
// pipeline/queries/sessions-by-user-this-week.kql, narrowed.
let user = "example.admin";
let from = datetime(2026-09-18 09:00:00);
let to = datetime(2026-09-18 18:00:00);
Syslog
| where TimeGenerated between (from .. to)
| where ProcessName == "tlog-rec-session"
| extend rec = parse_json(SyslogMessage)
| where tostring(rec.user) == user
| summarize Start = min(TimeGenerated), End = max(TimeGenerated), Fragments = count()
    by Computer, SessionId = tostring(rec.session)
| order by Start asc
```

That gives you the host, the session id and the boundaries. If it returns
nothing, do not conclude there was no session: run
`pipeline/queries/recording-failed-to-start.kql` over the same window, which
finds logins with no recording behind them.

### 2. Get the gateway's copy

Guacamole, from the UI: Settings, Session history, filter by username and date,
then the play button on the row. From the shell, when the UI cannot find it:

```bash
# Where the files are, by user and date, as recording-name renders them.
docker compose exec guacd \
  ls -la /var/lib/guacamole/recordings/

# Graphical session to a video file.
docker compose exec guacd \
  guacenc -s 1280x800 -r 2000000 \
  "/var/lib/guacamole/recordings/<session>/example.admin-20260918-0912"

# SSH typescript, replayed at the speed it happened.
scriptreplay --timing example.admin-20260918-0912.timing example.admin-20260918-0912
```

`guacenc` has to be the version that wrote the recording, which is why the image
is pinned. Warpgate: the admin UI, or `asciinema play` on the file. Teleport:
`tsh recordings ls` then `tsh play <session-id>`.

### 3. Get the host's copy

```bash
# On the host, while the journal still holds it.
tlog-play -r journal -M 'TLOG_USER=example.admin'
tlog-play -r journal -M 'TLOG_SESSION=42'

# What they ran, attributed to the login uid rather than the account it ran as.
ausearch -k execve -ua example.admin -ts '09/18/2026 09:00:00' -te '09/18/2026 18:00:00' -i

# Elevations only.
ausearch -k privileged -ua example.admin -ts today -i

# Keystrokes, if pam_tty_audit covers the account.
aureport --tty --start '09/18/2026 09:00:00' --end '09/18/2026 18:00:00'
```

Past the host's journal retention, the same content is in the workspace and the
queries in `pipeline/queries/` are the way in. Past the workspace's interactive
retention, it is in the archive and needs a search job.

### 4. Tie it to an authorisation

```kusto
// Which activation this session belongs to.
// pipeline/queries/activation-then-session.kql, narrowed to one person.
```

Run that query for the user and window. An activation with a justification and an
approver is the authorisation; a session with no activation in front of it is the
finding, and it means either a permanent assignment somebody should not have or a
bypass.

### What to write down

The host, the account, the window, the session id, the gateway recording filename,
the activation record, and which of the four sources were available. That last
item is the one people leave out and the one that matters when the same question
comes back in six months.

## When the gateway is down

Three questions, in this order.

### Is anything still being recorded

Yes, on every host in `host-baseline/`. `tlog` and `auditd` do not depend on the
gateway, and the forward to the collector does not go through it. Sessions opened
during the outage are recorded by the host and are missing from the gateway's
history, which is expected and is worth writing down so it does not read later as
a bypass.

### How does anyone get in

This is a decision to make before the outage, not during it. The options, in order
of preference:

1. **Wait.** If the outage is short and nothing is broken behind the gateway, this
   is the right answer and the only one with no side effects.
2. **Direct SSH from a named jump path, for the accounts in
   `sssd_allowed_groups`.** It works if the network allows it. The session is
   recorded by the host, it appears in
   `pipeline/queries/session-without-gateway.kql`, and that is the audit trail.
   Say in advance that this is the break glass path, so the query's output during
   an outage is explainable.
3. **The console.** Out of band management, or the hypervisor. Not recorded by
   anything in this repository, so it needs its own record: who, when, why, and
   what they did, written down by hand.

What not to do: add a local account, loosen `sssd_allowed_groups`, or turn off
`tlog` to make the recovery easier. All three generate the audit events this
repository exists to notice, and all three look exactly like an attack in the
review afterwards.

### Getting the gateway back

```bash
# Guacamole. All four containers, and the state of each.
cd gateways/guacamole
docker compose ps
docker compose logs --tail=200 guacamole
docker compose logs --tail=200 guacd

# The usual causes, in the order they happen:
#   1. Postgres is not healthy, so the web app never starts. Check the volume.
#   2. The OIDC endpoints in .env are wrong or the token is rejected. The web app
#      is up and every sign in fails.
#   3. The redirect URI does not match the registration exactly, including the
#      trailing path. Sign in loops with no error.
docker compose config -q               # renders with .env applied
docker compose restart guacamole
```

Recordings written before the outage are still on the volume and are readable with
`guacenc` without the web app. The database holds the history rows that point at
them, so if the database is the casualty, the files are still there and the
filenames are what the recording name template produced: identity, date, time.

### After the outage

- Compare the host recordings against the gateway history for the outage window.
  Every session the host recorded and the gateway did not should be accounted for.
- Check that nothing in `recording-config` fired during the recovery. If somebody
  changed a recording setting to get in, that needs to be a line in the report and
  a change back.
- Check that the connections in Guacamole still carry their recording parameters.
  A connection recreated in a hurry is the most likely way a recording setting
  goes missing:

```sql
-- Connections with no recording parameters on them at all.
SELECT c.connection_id, c.connection_name, c.protocol
FROM guacamole_connection c
WHERE NOT EXISTS (
    SELECT 1 FROM guacamole_connection_parameter p
    WHERE p.connection_id = c.connection_id
      AND p.parameter_name IN ('recording-path', 'typescript-path')
);
```

An empty result is the healthy state. Run it on a schedule, not only after an
outage, because Guacamole has no server wide default that would make it
unnecessary.

Run the other half of that review on the same schedule: the accounts the gateway
database will accept a password for. `EXTENSION_PRIORITY=openid` orders the
authentication providers and does not remove the JDBC one, so a local account
with a password is a way past Conditional Access, the PIM activation and the
compliant device check all at once.

```sql
-- Local accounts the JDBC provider will accept a password for. The generated
-- schema creates guacadmin with a publicly known password; first start deletes
-- it, and nothing prevents another one being added.
SELECT e.name, u.disabled, u.last_active
FROM guacamole_user u
JOIN guacamole_entity e ON e.entity_id = u.entity_id
ORDER BY u.last_active DESC NULLS LAST;
```

Accounts created by the first OIDC sign in appear here too, so this is a list to
account for rather than a list that should be empty. An account named in it that
nobody recognises, or `guacadmin` reappearing, is an incident.
