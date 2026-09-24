# Collector and agent

The collector is one host with two jobs: receive the forward from every recorded
host, and let the Azure Monitor Agent ship it into the workspace `../` creates.

```text
recorded host                    collector                        Azure
-------------                    ---------                        -----
auditd  --> rsyslog  --TLS 6514-->  rsyslog  --> AMA  --> Log Analytics
tlog    --> journal --> rsyslog       |
                                      +--> /var/log/recorded-access/<sender ip>/
```

`rsyslog-collector.conf` is the receiving end. The sending end is
`../../host-baseline/roles/tlog/templates/rsyslog-tlog-remote.conf.j2`, and the
two have to agree on three things or the forward fails silently:

| Setting | Sending end | Receiving end |
| --- | --- | --- |
| Port | `tlog_collector_port`, 6514 | `input(... port="6514")` |
| TLS | `StreamDriverAuthMode="x509/name"` | `StreamDriver.AuthMode="x509/name"` |
| Peer name | `tlog_forward_tls_permitted_peer` | the name on the collector certificate |
| Sender name | the name on the host's certificate | `PermittedPeer` on the `imtcp` module |

`PermittedPeer` on the receiving end is the only authentication control in front
of the second copy of the evidence, and it is a list of sending hosts rather than
a wildcard for that reason. A wildcard under one internal certificate authority
means every host that authority signs for may write to the evidence store.

## Installing the agent

The Azure Monitor Agent is an extension on the collector VM, and the data
collection rule decides what it picks up. Attaching the rule is what
`collector_vm_resource_id` does in `../variables.tf`; left empty, the rule is
created and collects nothing.

```bash
# The agent has to be installed before the association does anything.
az vm extension set \
  --name AzureMonitorLinuxAgent \
  --publisher Microsoft.Azure.Monitor \
  --resource-group example-recorded-access \
  --vm-name example-collector \
  --enable-auto-upgrade true

# Then apply ../ with collector_vm_resource_id set, and confirm data is arriving.
# The agent writes its own diagnostics here:
journalctl -u azuremonitoragent --since '15 min ago'
```

## Two failure modes worth knowing before they happen

- **The received messages have to stay in the default ruleset.** The agent's
  syslog data source works by installing its own rsyslog drop-in, which holds a
  catch-all action in the default ruleset. A message bound to a custom ruleset
  never reaches the default ruleset, so `input(... ruleset="something")` gives a
  collector whose local files fill up correctly while the workspace stays empty,
  which is a failure that looks like success from the collector. That is why
  `rsyslog-collector.conf` names its input and selects on `$inputname` rather than
  binding a ruleset, and why the `stop` has to come after the agent's own action:
  the agent's drop-in is numbered 10, so this file is numbered 40.
- **The agent's own drop-in decides the order.** Confirm it before trusting the
  numbering above: `ls /etc/rsyslog.d/` and read whichever file the agent
  installed. If a future agent version binds its action to a ruleset of its own,
  the `stop` in `rsyslog-collector.conf` has to go, and `rsyslogd -N1` plus one
  test message is the way to find out which it is.
- **The facility and level filter is the only filter.** The data collection rule
  in `../dcr.tf` names the facilities in `syslog_facilities`: `auth`, `authpriv`,
  `daemon`, `local6` and `user`. Anything a host sends on
  another facility is received, written to disk and never ingested. If a host's
  events are missing from the workspace and present on the collector, that filter
  is the first place to look.

## What this collector is not

It is a single host with local disk, which means it shares a failure domain with
itself: if it is full, the hosts buffer to their own spool directories
(`tlog_forward_spool_max_size`, 1g by default) and then start discarding. Sizing
that spool is how long a collector outage can last before recordings are lost,
and it is a number to set deliberately rather than inherit.
