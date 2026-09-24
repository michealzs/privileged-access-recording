# The break glass account

Every Conditional Access policy in this directory excludes a group, and that
group holds the break glass accounts. The exclusion looks like the weakest line
in the configuration and it is the reason the configuration is safe to deploy.

Forgetting it locks everyone out. That is not a hypothetical failure mode, it is
the ordinary one: a policy that requires a compliant device, applied to all
administrative roles, on a day when the device compliance service is not
returning results, blocks every administrator including the one who would turn
the policy off. Conditional Access is evaluated before the portal loads, so there
is no console to get in through.

## What a break glass account is

- A cloud-only account in the directory. Not synchronised from anywhere, so an
  outage on the synchronisation path or on the on-premises directory cannot
  affect it.
- Permanently assigned the highest administrative role. Not eligible through PIM,
  permanently assigned, because PIM activation needs a working directory, a
  working multifactor path and sometimes an approver, and the situations this
  account exists for are exactly the ones where one of those is broken.
- Excluded from every Conditional Access policy. Every one, including policies
  added later by somebody who has not read this file.
- Holding a long random password and a phishing resistant second factor that does
  not depend on a phone, a person or a network service. A hardware security key,
  or the password split between two sealed envelopes in two different safes.
- Not a mailbox, not licensed, not a member of any group that grants anything
  else, and not named anything that looks like a service account somebody might
  tidy up.

Two accounts, not one, so the loss of a single credential or a single key is not
the loss of the recovery path. They should not share a factor.

## Why it is excluded rather than accommodated

The alternative designs all fail in the same way. Requiring multifactor on the
break glass account means the recovery path depends on the multifactor service,
which is one of the things that breaks. Requiring a compliant device means it
depends on the device compliance service. An exclusion with a named location
attached means it depends on that network being reachable.

The exclusion is unconditional because every condition is another thing that can
be broken at the moment the account is needed.

## What the exclusion costs, and what pays for it

The cost is real: two accounts with permanent top level access and no
Conditional Access on them. Nothing in Terraform can make that safe. What makes
it safe is that using one is loud enough to be noticed within minutes, and that
means monitoring, not policy.

Three things to build before the accounts exist:

1. **An alert on any sign-in by either account.** Not a report, an alert, to
   somebody who is on call. The query is in
   [../pipeline/queries/](../pipeline/queries/) territory and the shape is a
   sign-in event whose account object id is one of two known values, severity
   high, with no aggregation and no threshold. Every sign-in is an incident until
   somebody says otherwise.
2. **An alert on any change to either account, or to the group they are in.** A
   password reset, a factor registration, a role change, a group membership
   change. Somebody preparing to use one of these accounts changes it first.
3. **An alert on any change to the exclusion itself.** If a policy stops
   excluding the group, the next policy change can lock everyone out. If a
   policy starts excluding a different group, somebody has quietly created a way
   around every control in this directory.

And two things to do on a schedule:

- **Test the credential quarterly**, by signing in and doing nothing else. An
  untested recovery credential is not a recovery credential. The test generates
  the alert from item one, which also tests the alert.
- **Rotate after every use and after every test.** Write down who used it, when
  and why, next to the alert it generated.

## Where this configuration puts it

`break_glass_group_object_id` is a required variable with no default, and the
exclusion is built once in a local:

```hcl
locals {
  break_glass_exclusions = [var.break_glass_group_object_id]
}
```

Every policy resource uses that local, so a new policy added to this directory
cannot be written without the exclusion unless somebody deliberately removes it.
That is the only enforcement Terraform can offer here; the rest is the monitoring
above.

`policy_state` defaults to `enabledForReportingButNotEnforced`. Deploy in
report-only, read the sign-in logs for the accounts the policies would have
blocked, and only then set it to `enabled`. The logs in report-only mode are what
find the service principal nobody remembered, the account with no compliant
device, and the administrator whose only factor is a phone.

## The thing that is easy to get wrong

An exclusion on a **group** only works if the accounts are in the group. A group
created in Terraform and populated by hand is a group that can be empty, and an
empty exclusion group is the same as no exclusion at all, silently.

Check the membership, from the directory and not from the state file, before
enforcing anything:

```bash
# Object ids of the accounts actually in the exclusion group.
az ad group member list --group "<break glass group object id>" \
  --query "[].{id:id, upn:userPrincipalName}" -o table
```

Two accounts, both cloud-only, both permanently in the highest role. If that
command returns an empty list, stop and fix it before setting `policy_state` to
`enabled`.
