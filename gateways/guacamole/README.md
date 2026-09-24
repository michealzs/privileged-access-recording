# Guacamole as a recording gateway

Apache Guacamole proxies RDP, VNC and SSH in a browser. The part that matters
here is that `guacd`, not the client, is the process that talks to the target,
so it is in a position to write a complete recording of the session and the user
has no way to switch that off.

This directory is the whole deployment: `docker-compose.yml`, an `.env.example`
to copy, and the retention job. There is no Guacamole extension code here and
nothing is forked.

## What records, and where it lands

Recording is a per connection setting, not a server setting. That is the single
most important thing to know about this deployment, because a connection created
without those parameters is a session with no recording and nothing warns you.

| Protocol | Parameter | Produces |
| --- | --- | --- |
| RDP, VNC | `recording-path`, `recording-name` | A Guacamole session recording: the graphical protocol stream, played back in the browser |
| SSH, telnet | `typescript-path`, `typescript-name` | A typescript: the terminal byte stream plus a timing file, replayable with `scriptreplay` |

Both are written by `guacd` into `/var/lib/guacamole/recordings`, which is the
`recordings` volume. The web app mounts the same volume read only and the
bundled history recording storage extension, switched on by
`RECORDING_SEARCH_PATH`, is what puts a play button on each row of the session
history table.

Set these on every connection, and set them the same way every time:

| Parameter | Value | Why |
| --- | --- | --- |
| `recording-path` | `/var/lib/guacamole/recordings/${HISTORY_PATH}` | `${HISTORY_PATH}` expands to a per session directory, which is what the history extension searches |
| `recording-name` | `${GUAC_USERNAME}-${GUAC_DATE}-${GUAC_TIME}` | Identity and time in the filename, so the runbook can find it without the database |
| `recording-exclude-output` | `false` | Excluding output leaves a recording that shows what was typed and not what happened |
| `recording-exclude-mouse` | `false` | Without the cursor a graphical recording is very hard to follow |
| `recording-include-keys` | `false` | See the warning below |
| `create-recording-path` | `true` | `guacd` creates the per session directory itself |
| `typescript-path` | `/var/lib/guacamole/recordings/${HISTORY_PATH}` | Same directory for SSH, so retention is one job |
| `typescript-name` | `${GUAC_USERNAME}-${GUAC_DATE}-${GUAC_TIME}` | Produces `name` and `name.timing` |

`recording-include-keys` records raw keystrokes, which means it records
passwords typed into a prompt inside the session. The graphical stream already
shows everything the operator saw. Leave it off unless there is a written reason
to capture keystrokes, and if it goes on, the recordings become secret material
and the volume needs to be treated as such.

A connection group parameter template is the practical way to stop someone
creating a connection without any of this. Guacamole has no server wide default,
so the alternative is a periodic query against `guacamole_connection_parameter`
looking for connections with no `recording-path` or `typescript-path`. That
query is in the runbook.

## Playing a recording back

Graphical recordings play in the browser: Settings, then Session history, then
the play button on the row. That path needs the history extension to find the
file, which means the session has to have finished and the file has to still be
inside `RECORDING_SEARCH_PATH`.

When the UI cannot find it, or the database is gone, go to the file:

```bash
# Graphical: convert to a video. guacenc is in the guacd image.
docker compose exec guacd \
  guacenc -s 1024x768 -r 2000000 \
  "/var/lib/guacamole/recordings/<session>/<user>-<date>-<time>"
# writes <...>.m4v next to the recording

# SSH: replay the typescript at the speed it happened.
scriptreplay --timing <user>-<date>-<time>.timing <user>-<date>-<time>
```

`guacenc` needs the matching guacd version to read a recording, which is one
reason the image is pinned to a patch version here rather than to `latest`. Keep
the version that wrote a recording available for as long as you keep the
recording.

## Retention

`recording-pruner` deletes files under the recording path older than
`RECORDING_RETENTION_DAYS`, then removes the empty per session directories. It
ships with `PRUNE_DRY_RUN=1`, which logs what it would delete and deletes
nothing. Leave it there until you have watched a full retention period of its
logs, because the failure mode is silent and permanent.

Retention is a policy decision and 90 days is a placeholder, not a
recommendation. Two things about it are not negotiable:

- Pruning deletes the file. The row in `guacamole_connection_history` stays, so
  the audit trail still shows that a session happened, who opened it and for how
  long, after the recording itself is gone.
- The prune job runs with write access to the volume. Anyone who can reach the
  Docker daemon on this host can delete recordings regardless of retention,
  which is why `docs/threat-model.md` treats gateway administrators as inside
  the trust boundary and the host audit trail in `host-baseline/` as the
  independent record.

## First start

```bash
cp .env.example .env
$EDITOR .env                      # database password, OIDC endpoints, public URL

# Generate the schema once. The image ships the DDL; postgres applies whatever
# is in initdb/ on an empty data directory and ignores it afterwards.
mkdir -p initdb
docker run --rm guacamole/guacamole:1.5.5 /opt/guacamole/bin/initdb.sh --postgresql \
  > initdb/01-schema.sql

docker compose config -q         # renders with .env applied, catches typos
docker compose up -d
docker compose ps                # all four healthy
```

Then delete the account that schema created, before anything else. This is not
optional and it is not a hardening nicety:

```bash
set -a; . ./.env; set +a

# guacadmin ships in the generated schema with the publicly known password
# "guacadmin" and full system administrator permissions. EXTENSION_PRIORITY does
# not close that door: the JDBC provider is still loaded and still accepts a
# username and a password at /api/tokens, so this account reaches the gateway
# without Conditional Access, without a PIM activation, without a phishing
# resistant factor and without a compliant device, and as a system administrator
# it can create a connection with no recording parameters.
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "DELETE FROM guacamole_entity WHERE name = 'guacadmin' AND type = 'USER';"

# Then read what is left. Every row is an account the JDBC provider will accept a
# password for, so every row has to be accounted for. Accounts created by the
# first OIDC sign in appear here too, which is why this is a review rather than an
# expectation of an empty result.
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "SELECT e.name FROM guacamole_user u JOIN guacamole_entity e ON e.entity_id = u.entity_id;"
```

Renaming the account and setting a long random password is the other acceptable
answer, and it is the one to take if the directory is ever unavailable and a local
administrator is the fallback. What is not acceptable is leaving it, because the
password is in the project's own documentation.

`initdb/` is git-ignored: the file in it is generated by the image, so it is
reproducible from the command above and pinning a copy in git only creates a way
for the schema and the image to disagree.

The first OIDC sign in creates an account row, because
`POSTGRESQL_AUTO_CREATE_ACCOUNTS` is on, with no permissions on anything. Grant
connection permissions to directory groups, not to those accounts. Until one
group has permissions, every sign in succeeds and shows an empty connection
list, which is the expected state and not a broken deployment.

## Variables you will want to change

- `OIDC_USERNAME_CLAIM` in `.env`. It decides the string in every recording
  filename and every history row, and it has to match the username `sssd`
  reports on the hosts or the two halves of the audit trail cannot be joined.
  `preferred_username` is the usual answer; it is mutable in most directories,
  and `oid` or `sub` is the stable choice if you are willing to read GUIDs.
- `PROXY_ALLOWED_IPS_REGEX`. Only the proxy in front should be trusted to set
  `X-Forwarded-For`. Widen this and a client can put any source address it likes
  into the audit trail.
- `OPENID_MAX_TOKEN_VALIDITY`, 300 seconds here. This is how long an issued
  token may be presented for, not how long the session lasts.
- The published port, `127.0.0.1:8080`. TLS, the public hostname and any IP
  allow list belong to the reverse proxy in front of this, which is not in this
  repository.

## Known limitations

- **No reverse proxy, and therefore no TLS.** The web app is published on
  loopback. Something in front has to terminate TLS on the name in
  `PUBLIC_URL`, and OIDC will refuse to complete over plain HTTP on any other
  name.
- **Guacamole's OIDC extension uses the implicit flow.** There is no client
  secret in `.env` because the extension does not use one. The application
  registration has to permit implicit ID tokens, which some directories
  discourage by default.
- **The database holds authorisation, so it is in scope.** Moving
  authentication to the directory does not move permissions. Whoever can write
  `guacamole_connection_parameter` can create a connection with no recording
  parameters on it.
- **The database is also still an authentication path.** `EXTENSION_PRIORITY`
  orders the providers; it does not unload the JDBC one, which keeps accepting a
  username and a password at `/api/tokens`. So a local account with a password is
  a way past the entire identity layer, and the generated schema creates one:
  `guacadmin`, with a publicly known password and system administrator
  permissions. First start above deletes it. Nothing in this repository prevents
  another one being created, so the query in First start belongs on the same
  schedule as the runbook query for connections with no recording parameters.
  Removing `guacamole-auth-jdbc` from the image is the only way to close the path
  rather than manage it, and it takes the permissions model with it.
- **No backup of either volume.** `recordings` and `database` are local named
  volumes. A recording that exists only on the gateway is not evidence against
  someone with root on the gateway.
