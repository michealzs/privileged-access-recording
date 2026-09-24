# Time bound elevation, through PIM for Groups.
#
# The model is one role-assignable group that grants access to the gateways, and
# nobody permanently in it. Administrators are made eligible; reaching a gateway
# means activating, which requires multifactor, a justification, an approval and
# expires by itself.
#
# Why the group and not the directory role: the elevation has to cover the
# gateways, which are applications and not directory roles. A group can hold
# both the application assignment and a directory role, so one activation covers
# everything a privileged session needs and there is one record of it.

resource "azuread_group_role_management_policy" "gateway_access" {
  group_id = local.gateway_access_group_id
  role_id  = "member"

  lifecycle {
    # The two ways a default configured plan fails, both with an error that does
    # not name the variable to set. Checking them here is the difference between
    # a readable failure and half an hour in the provider source.
    precondition {
      condition     = var.create_access_groups || var.gateway_access_group_object_id != ""
      error_message = "Set gateway_access_group_object_id to the object id of the role-assignable group that grants gateway access, or set create_access_groups to create it here. Left empty, the provider rejects the group id as a malformed GUID."
    }

    # An approval stage with no approvers is not a policy nobody can satisfy. Entra
    # falls back to the group owners and the Privileged Role Administrators, which
    # can include the person activating, so the approval quietly becomes a self
    # approval. The provider refuses it first, because primary_approver has a
    # minimum of one block, and this is the error message that says what to do
    # about it.
    precondition {
      condition     = !var.require_activation_approval || length(var.activation_approver_object_ids) > 0
      error_message = "require_activation_approval is true and activation_approver_object_ids is empty. Name at least one approver group, or set require_activation_approval to false and say so in the design; an approval stage with no approvers falls back to the group owners and can be satisfied by the requester."
    }
  }

  activation_rules {
    # The ceiling on a single activation. Nothing here extends it; a longer piece
    # of work means activating again, which is another record.
    maximum_duration = var.activation_maximum_duration

    # Multifactor at activation, on top of the Conditional Access policy at sign
    # in. They are different moments: sign in is when the session started,
    # activation is when the privilege was taken.
    require_multifactor_authentication = true

    # A free text reason, which is what makes the activation record readable six
    # months later.
    require_justification = true

    # A change or incident reference. Turn this on when there is a ticket system
    # whose references can be checked, and leave it off when there is not,
    # because an unvalidated field is a field people type "n/a" into.
    require_ticket_info = false

    # This and approval_stage below are two independent fields in the provider, and
    # that is the trap. An approval_stage on its own deploys a policy that lists
    # approvers while approval is not required, so activation succeeds with nobody
    # approving anything and the portal still shows an approver list. They are
    # driven from one variable for that reason, and because the provider also
    # refuses require_approval with no approval_stage.
    require_approval = var.require_activation_approval

    dynamic "approval_stage" {
      for_each = var.require_activation_approval ? [1] : []

      content {
        dynamic "primary_approver" {
          for_each = var.activation_approver_object_ids

          content {
            object_id = primary_approver.value
            type      = "groupMembers"
          }
        }
      }
    }
  }

  eligible_assignment_rules {
    # Eligibility that never expires is a permanent grant with an extra click in
    # front of it. This is what forces a periodic decision about whether the
    # person still needs it.
    expiration_required = true
    expire_after        = var.eligible_assignment_expiration
  }

  active_assignment_rules {
    # Nobody is permanently active in this group. A permanent member has the
    # access without the activation record, which defeats the whole design.
    expiration_required                = true
    expire_after                       = "P30D"
    require_multifactor_authentication = true
    require_justification              = true
  }

  notification_rules {
    eligible_assignments {
      admin_notifications {
        notification_level    = "All"
        default_recipients    = true
        additional_recipients = var.notification_recipient_addresses
      }
    }

    active_assignments {
      admin_notifications {
        notification_level    = "All"
        default_recipients    = true
        additional_recipients = var.notification_recipient_addresses
      }
    }

    eligible_activations {
      admin_notifications {
        notification_level    = "All"
        default_recipients    = true
        additional_recipients = var.notification_recipient_addresses
      }
    }
  }
}

# Who may activate. Eligible, not active: membership does not exist until an
# activation succeeds, and it goes away when the activation expires.
resource "azuread_privileged_access_group_eligibility_schedule" "gateway_access" {
  for_each = toset(var.eligible_principal_object_ids)

  group_id             = local.gateway_access_group_id
  principal_id         = each.value
  assignment_type      = "member"
  duration             = var.eligible_assignment_expiration
  justification        = "Eligible for recorded privileged access to the gateways, managed in identity/."
  permanent_assignment = false

  lifecycle {
    # Same group id, same opaque provider error, so the same check. An eligibility
    # for a group that was never named is the other half of the default configured
    # plan failing without saying which variable is unset.
    precondition {
      condition     = var.create_access_groups || var.gateway_access_group_object_id != ""
      error_message = "Set gateway_access_group_object_id, or set create_access_groups to create the group here. An eligibility cannot be written against an empty group id."
    }
  }
}
