variable "subscription_id" {
  description = "Subscription the workspace and the data collection rule are created in."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the workspace and the data collection rule."
  type        = string
}

variable "location" {
  description = "Azure region. The data collection rule must be in the same region as the machines it is associated with."
  type        = string
}

variable "workspace_name" {
  description = "Name of the Log Analytics workspace the audit trail and the session recordings arrive in."
  type        = string
}

variable "workspace_sku" {
  description = "Workspace pricing tier. PerGB2018 is pay as you go."
  type        = string
  default     = "PerGB2018"

  validation {
    condition     = contains(["PerGB2018", "CapacityReservation", "LACluster"], var.workspace_sku)
    error_message = "workspace_sku must be one of PerGB2018, CapacityReservation or LACluster."
  }
}

variable "workspace_retention_in_days" {
  description = "Default interactive retention for the workspace, between 30 and 730 days."
  type        = number
  default     = 90

  validation {
    condition     = var.workspace_retention_in_days >= 30 && var.workspace_retention_in_days <= 730
    error_message = "workspace_retention_in_days must be between 30 and 730."
  }
}

variable "syslog_interactive_retention_in_days" {
  description = "Queryable retention on the Syslog table, which is where both the audit trail and the session recordings land. This is the window the queries in queries/ can look back over."
  type        = number
  default     = 90
}

variable "syslog_total_retention_in_days" {
  description = "Interactive retention plus the cheaper long term archive on the Syslog table. Must be at least the interactive window. This is the window an investigation months later can reach."
  type        = number
  default     = 730
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB. Ingestion stops for the rest of the UTC day once it is hit, which on this workspace means the audit trail stops arriving, so treat it as an alarm and not a budget. Set to -1 to remove it."
  type        = number
  default     = 20
}

variable "data_collection_rule_name" {
  description = "Name of the data collection rule that carries auditd and tlog output."
  type        = string
  default     = "dcr-recorded-access"
}

variable "syslog_facilities" {
  description = "Syslog facilities collected. authpriv carries the audisp syslog plugin and the PAM records, local6 is where the audisp plugin is configured to write in agent/, and daemon carries sshd. tlog writes through the journal and arrives with whatever facility rsyslog gives it, which is why user and local6 are both here."
  type        = list(string)
  default     = ["auth", "authpriv", "daemon", "local6", "user"]
}

variable "syslog_log_levels" {
  description = "Levels collected. Info and above, because tlog writes session content at Info and dropping it collects the metadata and not the recording."
  type        = list(string)
  default     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
}

variable "enable_ingestion_transform" {
  description = "Apply a KQL transform at ingestion that drops messages no query here reads. It cuts volume and it is destructive: a message dropped at ingestion is not in the archive either."
  type        = bool
  default     = false
}

variable "collector_vm_resource_id" {
  description = "Resource id of the collector, the machine that receives the forward from every recorded host and runs the agent. Left empty, the rule is created and collects nothing, because an association is what makes an installed agent do anything."
  type        = string
  default     = ""
}

variable "additional_machine_resource_ids" {
  description = "Resource ids of any other machines the rule is associated with, for a deployment where hosts ship to the workspace directly instead of through the collector. Azure virtual machines or Arc enabled servers."
  type        = list(string)
  default     = []
}

variable "alert_enabled" {
  description = "Deploy the alert on queries/recording-config-changed.kql. That query is the one event this repository exists to notice, so the alert is on by default."
  type        = bool
  default     = true
}

variable "alert_severity" {
  description = "Severity of the recording configuration alert, 0 to 4, where 0 is the highest. Somebody editing the recording configuration is a 1: it is either change management or an attacker covering their tracks, and both need reading the same day."
  type        = number
  default     = 1

  validation {
    condition     = var.alert_severity >= 0 && var.alert_severity <= 4
    error_message = "alert_severity must be between 0 and 4."
  }
}

variable "alert_evaluation_frequency" {
  description = "How often the alert query runs, as an ISO 8601 duration."
  type        = string
  default     = "PT15M"
}

variable "alert_window_duration" {
  description = "How far back each evaluation looks. Larger than the frequency on purpose, so a late arriving event is still seen; the cost is that one event can raise two alerts."
  type        = string
  default     = "PT30M"
}

variable "action_group_id" {
  description = "Resource id of the action group the alert notifies. Empty by default, and an alert with no action group fires into a list nobody is watching. Supply one before relying on it."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource created here."
  type        = map(string)
  default     = {}
}
