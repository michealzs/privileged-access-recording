variable "tenant_id" {
  description = "Directory tenant the policies are created in."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.tenant_id))
    error_message = "tenant_id must be a GUID."
  }
}

variable "policy_name_prefix" {
  description = "Prefix on every Conditional Access policy name created here, so they sort together in the portal and are obvious as managed resources."
  type        = string
  default     = "CA-PrivilegedAccess"
}

variable "create_access_groups" {
  description = "Create the operators and admins groups here rather than consuming object ids for groups that already exist. False by default, because group lifecycle usually belongs with joiners and leavers and not with policy."
  type        = bool
  default     = false
}

variable "group_prefix" {
  description = "Prefix on the names of the groups created when create_access_groups is true. The resulting names have to match the groups named in host-baseline/inventory, or a host allows a group the directory does not grant."
  type        = string
  default     = "example-linux"
}

variable "operators_group_description" {
  description = "Description on the operators group. Standing access: login to recorded hosts, no sudo."
  type        = string
  default     = "Login to recorded hosts. No sudo, and sessions are recorded only if the group is added to tlog_record_groups."
}

variable "admins_group_description" {
  description = "Description on the admins group. Membership is what PIM makes time bound, and sessions for it are recorded."
  type        = string
  default     = "Privileged access to recorded hosts. Membership is time bound through PIM and every session is recorded."
}

variable "gateway_application_ids" {
  description = "Application (client) ids of the gateway applications these policies apply to: the Guacamole OIDC registration, the Warpgate registration, and anything else that fronts a recorded session. Empty means the gateway policy is not created."
  type        = list(string)
  default     = []
}

variable "administrative_group_object_ids" {
  description = "Object ids of the existing directory groups whose members reach the gateways as administrators. Group object ids, not names, and they differ in every tenant. Ignored when create_access_groups is true."
  type        = list(string)
  default     = []
}

variable "protected_role_template_ids" {
  description = "Role template ids of the directory roles the multifactor and device policy applies to. Role template ids are the same in every tenant and are listed in the directory's own role documentation; the all-zero value in the example is a placeholder to replace."
  type        = list(string)
  default     = []
}

variable "break_glass_group_object_id" {
  description = "Object id of the group holding the break glass accounts. Excluded from every Conditional Access policy created here. Read break-glass.md before setting it, and read it again before deciding nobody needs one."
  type        = string
}

variable "authentication_strength_phishing_resistant_id" {
  description = "Id of the built-in phishing resistant multifactor authentication strength policy. This value is fixed across tenants; it is a variable so a custom strength policy can be used instead."
  type        = string
  default     = "00000000-0000-0000-0000-000000000004"
}

variable "require_compliant_device" {
  description = "Require a device the directory considers compliant, in addition to phishing resistant multifactor. Turning this off leaves multifactor as the only control and lets an administrative session start from an unmanaged machine."
  type        = bool
  default     = true
}

variable "policy_state" {
  description = "State of every Conditional Access policy created here: enabled, disabled, or enabledForReportingButNotEnforced. Deploy in report-only first and read the sign-in logs before enforcing, because the failure mode of a wrong exclusion is that nobody can sign in."
  type        = string
  default     = "enabledForReportingButNotEnforced"

  validation {
    condition     = contains(["enabled", "disabled", "enabledForReportingButNotEnforced"], var.policy_state)
    error_message = "policy_state must be enabled, disabled or enabledForReportingButNotEnforced."
  }
}

variable "sign_in_frequency_hours" {
  description = "How often an administrative session must reauthenticate. A long value here undoes the point of time bound elevation, because a token issued before an activation expired is still accepted."
  type        = number
  default     = 4
}

variable "gateway_access_group_object_id" {
  description = "Object id of the existing role-assignable group that grants access to the gateways. Membership of it is what PIM makes eligible rather than permanent, so it is the group the activation rules apply to. Ignored when create_access_groups is true."
  type        = string
  default     = ""
}

variable "eligible_principal_object_ids" {
  description = "Object ids of the principals, users or groups, made eligible for membership of the gateway access group. Eligible is not active: a member has to activate before they can reach a gateway."
  type        = list(string)
  default     = []
}

variable "activation_maximum_duration" {
  description = "Longest a single activation may last, as an ISO 8601 duration. PT8H is a working day; PT2H forces a second decision on a long piece of work, which is the point."
  type        = string
  default     = "PT8H"
}

variable "require_activation_approval" {
  description = "Require somebody else to approve an activation. With this true and activation_approver_object_ids empty, Entra does not refuse the activation: approval falls back to the group owners and the Privileged Role Administrators, which can include the person activating, so the control silently becomes a self approval. A precondition on azuread_group_role_management_policy.gateway_access refuses that combination at plan time."
  type        = bool
  default     = true
}

variable "activation_approver_object_ids" {
  description = "Object ids of the groups that may approve an activation. Approvers should not be the same people as the eligible principals, or the control is a formality. Required when require_activation_approval is true, and checked as a precondition rather than here, because the two variables have to be read together."
  type        = list(string)
  default     = []
}

variable "eligible_assignment_expiration" {
  description = "How long an eligibility itself lasts before it has to be renewed, as an ISO 8601 duration. Eligibility that never expires is a permanent grant with an extra click in front of it."
  type        = string
  default     = "P180D"
}

variable "notification_recipient_addresses" {
  description = "Addresses notified when an eligibility or an activation changes. An activation nobody is told about is an audit record nobody reads."
  type        = list(string)
  default     = []
}
