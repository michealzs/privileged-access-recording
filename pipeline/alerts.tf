# One alert, on one query.
#
# queries/recording-config-changed.kql is the one event the rest of this
# repository exists to notice: somebody wrote to the configuration that decides
# whether sessions are recorded. Everything else in queries/ is run by hand.
#
# The query is read from disk with file() rather than inlined here, so the file a
# person reads and the rule that runs cannot drift apart. Editing the .kql and
# applying is the whole change.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "recording_config_changed" {
  count = var.alert_enabled ? 1 : 0

  name                = "alert-recording-config-changed"
  display_name        = "Recording configuration changed on a recorded host"
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "A write to /etc/tlog/, /etc/sssd/, /etc/pam.d/, /etc/rsyslog.d/ or the journald drop-in, tagged by auditd with the recording-config key. Either change management, or somebody turning the recording off."

  scopes   = [azurerm_log_analytics_workspace.recorded_access.id]
  severity = var.alert_severity
  enabled  = true

  evaluation_frequency = var.alert_evaluation_frequency
  window_duration      = var.alert_window_duration

  criteria {
    query                   = file("${path.module}/queries/recording-config-changed.kql")
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  # The query is parameterised with let statements and ends in a projection, so
  # the service side validator rejects it even though it runs. Validation of the
  # query itself happens by running it in the Logs blade, which is the only place
  # it can be checked against real data anyway.
  skip_query_validation = true

  # Resolve by itself when the condition stops being met. A configuration change
  # is a point in time event, so an alert that stays open needs closing by hand
  # and the queue fills with history.
  auto_mitigation_enabled = true

  dynamic "action" {
    for_each = var.action_group_id != "" ? [var.action_group_id] : []

    content {
      action_groups = [action.value]
    }
  }

  tags = var.tags
}
