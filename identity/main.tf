# The two access groups, optionally created here.
#
# These are the groups every other directory in this repository names:
# host-baseline/roles/sssd puts them in simple_allow_groups, host-baseline/roles
# /tlog puts the admin one in tlog_record_groups, and the gateways authorise on
# the group claim. They have to stay in step, because a group that grants login
# and is not in the recording list is access without a recording.
#
# create_access_groups is false by default. Most directories already have these
# groups and manage their lifecycle alongside joiners and leavers, in which case
# this configuration consumes object ids through variables and creates nothing.
# Set it to true for a directory that does not have them yet.

locals {
  operators_group_name = "${var.group_prefix}-operators"
  admins_group_name    = "${var.group_prefix}-admins"

  # Which ids the policies below apply to: the groups created here, or the ones
  # passed in. One place, so a policy cannot be wired to the wrong set.
  administrative_group_ids = var.create_access_groups ? [
    azuread_group.admins[0].object_id,
  ] : var.administrative_group_object_ids

  gateway_access_group_id = var.create_access_groups ? azuread_group.admins[0].object_id : var.gateway_access_group_object_id
}

# Login to recorded hosts, no sudo. Membership here is standing access, which is
# the point: an operator should not have to elevate to read a log.
resource "azuread_group" "operators" {
  count = var.create_access_groups ? 1 : 0

  display_name     = local.operators_group_name
  description      = var.operators_group_description
  security_enabled = true
  mail_enabled     = false

  # Assigned membership, not dynamic. Dynamic membership on an access group means
  # an attribute edit elsewhere in the directory grants host access, and that
  # attribute is usually writable by more people than the group is.
  types = []
}

# Login plus sudo. Sessions for this group are recorded by tlog, and membership
# is what pim.tf makes temporary.
resource "azuread_group" "admins" {
  count = var.create_access_groups ? 1 : 0

  display_name     = local.admins_group_name
  description      = var.admins_group_description
  security_enabled = true
  mail_enabled     = false

  types = []

  # Assignable to directory roles is what lets this group be governed as
  # privileged access, and it is what PIM for Groups needs. It cannot be changed
  # after creation, so it is set here whether or not elevation is configured yet.
  assignable_to_role = true
}
