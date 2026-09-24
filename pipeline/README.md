# pipeline

Where the host's own record goes, and what reads it. One Terraform root, one
workspace, one data collection rule, one alert, and ten queries.

The gateway keeps its recordings on the gateway. This is the second copy, written
by the hosts, and the reason it exists is in
[../docs/threat-model.md](../docs/threat-model.md): somebody with root on a host
can clear the local journal and cannot retrieve what has already left it.

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # subscription, resource group, collector, action group

terraform init -backend=false
terraform validate
terraform plan
```

## What it creates

| Resource | Why |
| --- | --- |
| `azurerm_log_analytics_workspace` | The destination, with a daily cap and a default retention |
| `azurerm_log_analytics_workspace_table` | Retention on `Syslog` specifically, which is where both the audit trail and the session recordings land and is much larger than everything else |
| `azurerm_monitor_data_collection_endpoint` | The agent delivers to a regional endpoint, and the rule has to name one |
| `azurerm_monitor_data_collection_rule` | The facilities and levels collected. This is the volume decision, and the only thing that decides whether a recording ever leaves the host |
| `azurerm_monitor_data_collection_rule_association` | Attaches the rule to the collector. Without it the rule is configuration nothing reads |
| `azurerm_monitor_scheduled_query_rules_alert_v2` | One alert, on `queries/recording-config-changed.kql` |

The alert reads its query from disk with `file()`. The file in `queries/` and the
deployed rule therefore cannot drift apart, which is the reason the query is not
inlined in the Terraform.

## The path a recording takes

```text
recorded host                     collector                      Azure
-------------                     ---------                      -----
auditd  -> audisp syslog -> rsyslog --TLS 6514--> rsyslog -> AMA -> Log Analytics
tlog    -> journal       -> rsyslog
```

[agent/](agent/) is the collector end: the rsyslog configuration that terminates
the TLS the hosts insist on, and the notes on installing the agent. The sending
end is `../host-baseline/roles/tlog/templates/rsyslog-tlog-remote.conf.j2`, and
the two have to agree on the port, the TLS mode and the peer name or the forward
fails silently.

Three things can make a host look healthy while collecting nothing, and all three
are documented where they happen rather than here: journald rate limiting, rsyslog
`imjournal` rate limiting, and a missing data collection rule association.

## Retention, and the number that matters

`syslog_total_retention_in_days` is what a retention policy is actually about.
`syslog_interactive_retention_in_days` only decides how much of it is queryable
without a search job, which is to say how far back the queries in `queries/` can
look without extra work.

`daily_quota_gb` defaults to 20. Treat it as an alarm rather than a budget:
ingestion stops for the rest of the UTC day once it is hit, and on this workspace
that means the audit trail stops arriving and nothing tells the people whose
sessions are no longer being recorded.
[../host-baseline/docs/audit-volume.md](../host-baseline/docs/audit-volume.md) is
the estimate to read first, and `queries/recorded-session-inventory.kql` is how to
replace the estimate with a measurement.

`enable_ingestion_transform` is off. It drops messages in the ingestion pipeline,
which means what it drops is not in the archive either. Turn it on only after the
volume has been measured and the list in `dcr.tf` has been read line by line.

## The queries

Ten files in [queries/](queries/), one deployed as an alert and the rest run by
hand. [queries/README.md](queries/README.md) is the index. The four the design is
built around:

| Query | Answers |
| --- | --- |
| `sessions-by-user-this-week.kql` | Who was recorded, on what, for how long |
| `recording-failed-to-start.kql` | Which logins produced no recording. The only way a silent failure in the shell substitution becomes visible |
| `sudo-outside-change-windows.kql` | Which elevations happened outside an approved window |
| `activation-then-session.kql` | Which activation a session belongs to, which is what makes time bound elevation auditable rather than decorative |

## Variables you will want to change

- `collector_vm_resource_id`. Empty means the rule exists and collects nothing,
  which is the most common reason a deployment looks complete and the workspace
  stays empty.
- `action_group_id`. Empty means the alert fires into a list nobody is watching.
- `syslog_facilities`. The only filter between a host and the workspace. A host's
  events present on the collector and missing here are almost always this.
- `syslog_interactive_retention_in_days` and `syslog_total_retention_in_days`.
  Ninety days and two years, both chosen to be changed.
- `alert_severity`, 1. Somebody editing the recording configuration is either
  change management or an attacker covering their tracks, and both need reading
  the same day.

## What is deliberately not here

- **The gateway recordings.** Those are protocol streams on the gateway's disk.
  Copying them into a log workspace would be expensive and would not make them
  queryable, so the workspace holds the host's own record and the metadata.
  [../docs/runbook.md](../docs/runbook.md) is the procedure for getting from a row
  here to the file.
- **A remote state backend.** Local state, which is right for a repository nobody
  applies and wrong for anything else.
- **Sentinel.** This is a Log Analytics workspace with one alert on it, not a SIEM
  deployment. Turning the rest of `queries/` into analytics rules is a separate
  decision with a separate bill.
- **Access control on the workspace.** It holds the contents of privileged
  terminals. Who may read it is at least as important as the recording itself, and
  it is not configured here.
