output "workspace_id" {
  description = "Workspace customer id, which is what a query tool and an agent both ask for."
  value       = azurerm_log_analytics_workspace.recorded_access.workspace_id
}

output "workspace_resource_id" {
  description = "Full resource id of the workspace, for a diagnostic setting or another data collection rule pointed at it."
  value       = azurerm_log_analytics_workspace.recorded_access.id
}

output "data_collection_rule_id" {
  description = "Resource id of the data collection rule. Associating a machine with this is what makes the agent on it collect anything."
  value       = azurerm_monitor_data_collection_rule.recorded_access.id
}

output "associated_machine_count" {
  description = "How many machines are associated with the rule. Zero means nothing is being collected, whatever the agent on each host reports."
  value       = length(local.associated_machines)
}

output "data_collection_endpoint_id" {
  description = "Resource id of the ingestion endpoint the agent delivers to."
  value       = azurerm_monitor_data_collection_endpoint.recorded_access.id
}

output "alert_id" {
  description = "Resource id of the recording configuration alert, empty when alert_enabled is false."
  value       = try(azurerm_monitor_scheduled_query_rules_alert_v2.recording_config_changed[0].id, "")
}

output "alert_has_action_group" {
  description = "Whether the alert notifies anything. False means it fires into a list nobody is watching."
  value       = var.action_group_id != ""
}

output "syslog_retention" {
  description = "Interactive and total retention on the Syslog table, in days. The first is how far the queries in queries/ can look back."
  value = {
    interactive_days = var.syslog_interactive_retention_in_days
    total_days       = var.syslog_total_retention_in_days
  }
}
