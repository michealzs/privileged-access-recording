# identity

Terraform against the `azuread` provider, for the two controls that decide
whether a recorded session may start at all: Conditional Access on the accounts
that reach the gateways, and time bound elevation with an approval in front of
it.

Nothing here touches a gateway or a host. It is the layer above both, and it is
where the elevation lives because none of the three gateways in `../gateways/`
can do time bound elevation in a free build. Putting it in the directory means it
is configured once and covers all of them.

## The two access groups

`main.tf` can create them, behind `create_access_groups`, which is `false` by
default because most directories already have them and manage their lifecycle
with joiners and leavers. When it is `true`, two groups are created: an operators
group holding standing access, login with no sudo, and an admins group that is
role-assignable and whose membership PIM makes temporary.

Both are assigned membership rather than dynamic. Dynamic membership on an access
group means an attribute edit somewhere else in the directory grants host access,
and that attribute is usually writable by more people than the group is.

Their names have to match `sssd_allowed_groups` and `tlog_record_groups` in
`../host-baseline/inventory/`. A group that grants login and is not in the
recording list is access without a recording, and nothing in either half notices
the mismatch.

## Conditional Access

Two policies, in `conditional-access.tf`:

| Policy | Applies to | Requires |
| --- | --- | --- |
| `...-AdminRoles-PhishingResistantMFA-CompliantDevice` | The administrative groups and the protected directory roles, for every application | Phishing resistant multifactor, and a compliant device |
| `...-Gateways-PhishingResistantMFA-CompliantDevice` | Everybody, for the gateway applications | The same two |

The second one covers everybody rather than only administrators, because read
access to a session recording is read access to the contents of a privileged
terminal. Somebody who can play a recording back does not need administrative
rights to see what was typed in one.

Three details that are choices rather than defaults:

- **Phishing resistant multifactor as an authentication strength, not the older
  "require multifactor" control.** "Require multifactor" is satisfied by a push
  notification, and a push notification is phishable. The strength policy
  requires a factor that is bound to the origin.
- **`client_app_types = ["all"]`.** Including legacy clients. A policy that
  covers only browsers is a policy with an older client as its bypass.
- **`sign_in_frequency` at four hours, with `persistent_browser_mode = "never"`.**
  This is what stops an issued token outliving an elevation. PIM can expire an
  activation, and a token issued while it was active keeps working until
  something asks for reauthentication.

Both policies start in `enabledForReportingButNotEnforced`. Read the sign-in logs
for the accounts they would have blocked before setting `policy_state` to
`enabled`.

## Time bound elevation

`pim.tf` uses PIM for Groups rather than PIM for directory roles, because the
elevation has to cover the gateway applications and those are not directory
roles. One role-assignable group grants gateway access, nobody is permanently in
it, and administrators are made eligible for membership.

Activation requires, all together:

- Multifactor at activation. A separate moment from multifactor at sign in: one
  is when the session started, the other is when the privilege was taken.
- A written justification, which is what makes the record readable months later.
- An approval from somebody in `activation_approver_object_ids`, who should not be
  one of the eligible principals. Two fields deliver this and both are driven from
  `require_activation_approval`: `require_approval` on the activation rules, and
  the `approval_stage` block that names the approvers. An `approval_stage` without
  `require_approval` deploys a policy that lists approvers while approval is not
  required, which reads correctly in the portal and approves nothing.
- An expiry. `activation_maximum_duration` is `PT8H` and nothing extends it; a
  longer piece of work means activating again, which is another record.

Eligibility itself expires, after `eligible_assignment_expiration`, 180 days by
default. Eligibility that never expires is a permanent grant with an extra click
in front of it.

`active_assignment_rules` requires an expiry on any permanent membership too, so
a direct add to the group is still time bound. A permanent member would have the
access without the activation record, which is the one thing this design cannot
tolerate.

### What an empty approver list actually does

Not what it sounds like. `require_activation_approval` true with
`activation_approver_object_ids` empty is not a policy nobody can satisfy: Entra
falls back to the group owners and the Privileged Role Administrators, either of
which can include the person activating, so the approval becomes a self approval
and the record still says it was approved. That is worse than a policy that
refuses, because it looks like the control is working.

Two things stop it. The provider refuses first, because `primary_approver` has a
minimum of one block, and a `precondition` on
`azuread_group_role_management_policy.gateway_access` refuses it with an error
message that names both variables instead of leaving somebody to read a block
count. Setting `require_activation_approval` to false is a valid choice; leaving
it true with nobody named is not.

## The break glass account

Every policy here excludes `break_glass_group_object_id`, built once in a local so
a new policy cannot be written without it.

[break-glass.md](break-glass.md) is required reading before applying this. It
covers what the account has to be, why the exclusion is unconditional, the three
alerts that make the exclusion safe, and the mistake that makes all of it
worthless: an exclusion group with nobody in it.

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars        # tenant, groups, approvers, break glass group

terraform init
terraform plan                  # read this properly, it is a lockout risk
terraform apply
```

The plan is worth reading line by line rather than skimming. A Conditional Access
policy is one of the few resources whose incorrect application removes your
ability to correct it.

## Variables you will want to change

- `administrative_group_object_ids` and `gateway_application_ids`. Object ids,
  which differ in every tenant. The policy applies to nobody if the first is
  empty, and the variable validation refuses that.
- `break_glass_group_object_id`. Required, no default, and the group has to
  actually contain the accounts.
- `activation_approver_object_ids`. Required in practice, because
  `require_activation_approval` defaults to true and a plan with an empty list is
  refused by a precondition. See what an empty approver list actually does, above.
- `gateway_access_group_object_id`. Required unless `create_access_groups` is
  true. Left empty, the provider rejects it as a malformed GUID rather than naming
  the variable, so a precondition names it first.
- `activation_maximum_duration`. `PT8H` is a working day. `PT2H` forces a second
  decision on a long piece of work, which is the argument for it.
- `sign_in_frequency_hours`. Four. Longer, and a token can outlive an elevation.
- `require_compliant_device`. Turning it off leaves multifactor as the only
  control and allows an administrative session from an unmanaged machine.
- `policy_state`. Report-only until the logs have been read.

## Known limitations

- **Report-only proves less than it looks like it does.** `policy_state` ships as
  `enabledForReportingButNotEnforced`, which blocks nothing. It shows who would
  have been blocked at sign in, and it does not exercise the failure mode where
  the device compliance service is unavailable and every evaluation fails closed.
  Until it is `enabled`, every claim about what Conditional Access stops is a
  claim about what it would have stopped, which is why
  [../docs/threat-model.md](../docs/threat-model.md) marks those two entries
  conditional.
- **Group membership is not managed here.** `create_access_groups` will create
  the operators and admins groups, and nothing in this configuration puts anybody
  in them, because group lifecycle belongs with joiners and leavers rather than
  with policy. An eligibility for a principal who has left is invisible to this
  code.
- **Approvers are a list of object ids with no structure.** There is no escalation
  path, no second stage and no fallback if the only approver is on leave. That is
  a process gap this configuration cannot fill, and the symptom is an activation
  that nobody can approve at three in the morning.
- **Nothing here notices an unused eligibility.** Somebody eligible who never
  activates still holds a standing grant. Review the eligibility list on the same
  schedule as the expiry, not less often.
- **The authentication strength id is a fixed constant.** It is a variable so a
  custom strength policy can replace it, and it is not a tenant specific value.
  If a custom policy is used, check what it actually requires; a custom strength
  that includes a phishable factor is worse than the built-in one because it reads
  as stricter.
