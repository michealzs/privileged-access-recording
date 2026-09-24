# Conditional Access for the accounts that reach the recording gateways.
#
# Two policies, and they are separate on purpose:
#
#   1. Administrative roles and groups need phishing resistant multifactor and a
#      compliant device, for every application. This is the control that decides
#      whether an administrative session may start at all.
#   2. The gateway applications need the same, for everybody, including accounts
#      that are not in an administrative role. A reader who can open a recording
#      is reading the contents of a privileged terminal.
#
# Every policy excludes the break glass group. That exclusion is not a weakness
# to be fixed, it is what stops a policy change locking every administrator out
# of the directory at once. break-glass.md is the file that makes it safe, and it
# is not optional reading.

locals {
  # One place, so no policy can be created without the exclusion.
  break_glass_exclusions = [var.break_glass_group_object_id]

  # Report-only is the default state. A wrong exclusion in an enforced policy
  # locks people out, and the sign-in logs in report-only mode show exactly who
  # would have been blocked.
  policy_state = var.policy_state
}

resource "azuread_conditional_access_policy" "administrative_roles" {
  display_name = "${var.policy_name_prefix}-AdminRoles-PhishingResistantMFA-CompliantDevice"
  state        = local.policy_state

  conditions {
    # Browser and non-browser clients both. Leaving legacy clients out of a
    # policy is how a policy gets bypassed by an older client.
    client_app_types = ["all"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_groups = local.administrative_group_ids
      included_roles  = var.protected_role_template_ids
      excluded_groups = local.break_glass_exclusions
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.administrative_group_ids) > 0 || length(var.protected_role_template_ids) > 0
      error_message = "Set create_access_groups, or administrative_group_object_ids, or protected_role_template_ids. With all three empty this policy applies to nobody."
    }
  }

  grant_controls {
    operator = "AND"

    # Phishing resistant multifactor, as an authentication strength rather than
    # the older "require MFA" control. The difference matters: "require MFA"
    # accepts a push notification, which is phishable.
    authentication_strength_policy_id = var.authentication_strength_phishing_resistant_id

    # A device the directory considers compliant, which means it is enrolled and
    # reporting. Without it, a valid credential from an unmanaged machine is
    # enough to open an administrative session.
    built_in_controls = var.require_compliant_device ? ["compliantDevice"] : []
  }

  session_controls {
    # An issued token outliving an elevation is the hole this closes. PIM can
    # expire an activation and the token in the browser will keep working until
    # it is asked to reauthenticate.
    sign_in_frequency                         = var.sign_in_frequency_hours
    sign_in_frequency_period                  = "hours"
    sign_in_frequency_authentication_type     = "primaryAndSecondaryAuthentication"
    disable_resilience_defaults               = false
    persistent_browser_mode                   = "never"
    cloud_app_security_policy                 = "monitorOnly"
    application_enforced_restrictions_enabled = false
  }
}

resource "azuread_conditional_access_policy" "gateway_applications" {
  count = length(var.gateway_application_ids) > 0 ? 1 : 0

  display_name = "${var.policy_name_prefix}-Gateways-PhishingResistantMFA-CompliantDevice"
  state        = local.policy_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = var.gateway_application_ids
    }

    users {
      # Everybody who reaches a gateway, not only the administrative roles. Read
      # access to a recording is read access to a privileged terminal.
      included_users  = ["All"]
      excluded_groups = local.break_glass_exclusions
    }
  }

  grant_controls {
    operator                          = "AND"
    authentication_strength_policy_id = var.authentication_strength_phishing_resistant_id
    built_in_controls                 = var.require_compliant_device ? ["compliantDevice"] : []
  }

  session_controls {
    sign_in_frequency                     = var.sign_in_frequency_hours
    sign_in_frequency_period              = "hours"
    sign_in_frequency_authentication_type = "primaryAndSecondaryAuthentication"
    persistent_browser_mode               = "never"
  }
}
