# Where the host's own record goes.
#
# The gateway keeps its recordings on the gateway. This workspace is the second
# copy of the evidence, written by the hosts, and the reason it exists is in
# docs/threat-model.md: somebody with root on a host can delete the local journal
# and cannot delete what has already left it.
#
# Two resources do the work. The workspace, with retention set per table rather
# than only per workspace, because the Syslog table here carries session
# recordings and is much larger than everything else. And a data collection rule
# that tells the agent which facilities to collect, which is the only thing that
# decides whether a recording ever leaves the host.

resource "azurerm_log_analytics_workspace" "recorded_access" {
  name                = var.workspace_name
  location            = var.location
  resource_group_name = var.resource_group_name

  sku               = var.workspace_sku
  retention_in_days = var.workspace_retention_in_days
  daily_quota_gb    = var.daily_quota_gb

  tags = var.tags
}

# Retention on the table the recordings land in, separately from the workspace
# default. The interactive window is what the queries can search; the total
# window is what an investigation months later can still reach.
resource "azurerm_log_analytics_workspace_table" "syslog" {
  workspace_id = azurerm_log_analytics_workspace.recorded_access.id
  name         = "Syslog"

  retention_in_days       = var.syslog_interactive_retention_in_days
  total_retention_in_days = var.syslog_total_retention_in_days

  lifecycle {
    precondition {
      condition     = var.syslog_total_retention_in_days >= var.syslog_interactive_retention_in_days
      error_message = "syslog_total_retention_in_days must be at least syslog_interactive_retention_in_days."
    }
  }
}
