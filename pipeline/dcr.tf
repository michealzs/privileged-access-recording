# The data collection rule.
#
# This is the piece people forget. The agent being installed on a host collects
# nothing at all: the rule says which facilities to read, and the association
# says which machines the rule applies to. A host with the agent, no association
# and a perfectly configured rsyslog sends nothing and reports no error.
#
# What arrives here, and from where:
#   auditd  the audisp syslog plugin writes events to syslog, and agent/ sets the
#           facility. See roles/auditd/defaults/main.yml for the plugin switch.
#   tlog    writes recorded sessions to the journal, rsyslog reads the journal and
#           forwards them. See roles/tlog for the two rate limits that silently
#           drop them if left at their defaults.
#   sshd    session open and close, which is how a recording is tied to a login.

locals {
  destination_name = "law-recorded-access"

  associated_machines = compact(concat([var.collector_vm_resource_id], var.additional_machine_resource_ids))

  # Dropped at ingestion, when enable_ingestion_transform is on. Everything
  # listed here is noise no query in queries/ reads. It is a destructive filter:
  # what it drops is not in the archive either, so the list is short and each
  # entry is a pattern rather than a facility.
  ingestion_transform = <<-KQL
    source
    | where not(SyslogMessage has_any (
        "CROND",
        "systemd-logind: New session",
        "pam_unix(cron:session)"
      ))
  KQL
}

# The agent sends to a regional endpoint, and the rule has to name one. Without
# it the rule is valid and the agent has nowhere to deliver to.
resource "azurerm_monitor_data_collection_endpoint" "recorded_access" {
  name                          = "dce-${var.data_collection_rule_name}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  kind                          = "Linux"
  public_network_access_enabled = true
  description                   = "Ingestion endpoint for the recorded access collection rule."

  tags = var.tags
}

resource "azurerm_monitor_data_collection_rule" "recorded_access" {
  name                        = var.data_collection_rule_name
  resource_group_name         = var.resource_group_name
  location                    = var.location
  kind                        = "Linux"
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.recorded_access.id
  description                 = "auditd events and tlog session recordings from the hosts in host-baseline/."

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.recorded_access.id
      name                  = local.destination_name
    }
  }

  data_sources {
    syslog {
      name           = "auditd-and-tlog"
      streams        = ["Microsoft-Syslog"]
      facility_names = var.syslog_facilities
      log_levels     = var.syslog_log_levels
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = [local.destination_name]

    # A transform runs in the ingestion pipeline, so it is applied before
    # anything is stored and cannot be undone by a query.
    transform_kql = var.enable_ingestion_transform ? local.ingestion_transform : null
    output_stream = var.enable_ingestion_transform ? "Microsoft-Syslog" : null
  }

  tags = var.tags
}

# Without an association, the rule is configuration nothing reads. The usual
# deployment associates one machine, the collector, because that is where the
# forward from every recorded host arrives.
resource "azurerm_monitor_data_collection_rule_association" "recorded_access" {
  for_each = toset(local.associated_machines)

  name                    = "dcra-recorded-access"
  target_resource_id      = each.value
  data_collection_rule_id = azurerm_monitor_data_collection_rule.recorded_access.id
  description             = "Associates a recorded host with the auditd and tlog collection rule."
}
