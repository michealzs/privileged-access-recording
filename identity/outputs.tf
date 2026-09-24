output "conditional_access_policy_ids" {
  description = "Ids of the Conditional Access policies created here. Both start in report-only; check the sign-in logs for the accounts they would have blocked before setting policy_state to enabled."
  value = compact([
    azuread_conditional_access_policy.administrative_roles.id,
    try(azuread_conditional_access_policy.gateway_applications[0].id, ""),
  ])
}

output "policy_state" {
  description = "State every policy was created in. enabledForReportingButNotEnforced means nothing is being blocked yet."
  value       = var.policy_state
}

output "group_names_for_host_baseline" {
  description = "Names of the groups created here, empty when create_access_groups is false. They have to match sssd_allowed_groups and tlog_record_groups in host-baseline/inventory, or a host allows a group the directory does not grant."
  value = var.create_access_groups ? {
    operators = local.operators_group_name
    admins    = local.admins_group_name
  } : {}
}

output "operators_group_object_id" {
  description = "Object id of the operators group when it is created here, empty otherwise. Standing access: login, no sudo."
  value       = try(azuread_group.operators[0].object_id, "")
}

output "gateway_access_group_object_id" {
  description = "The role-assignable group whose membership is time bound. Nobody should be a permanent member of it."
  value       = local.gateway_access_group_id
}

output "break_glass_group_object_id" {
  description = "The group excluded from every policy created here. Monitor it; see break-glass.md."
  value       = var.break_glass_group_object_id
}

output "eligible_principal_count" {
  description = "How many principals are eligible for the gateway access group. Zero means the group is unreachable, which is a valid state only before the first eligibility is added."
  value       = length(var.eligible_principal_object_ids)
}
