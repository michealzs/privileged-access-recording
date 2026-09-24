# Teleport single sign on, and which parts are paid

Read this before designing around Teleport. The recording works in the free
edition. The directory integration most teams assume they are getting does not,
and for a small team that one line usually decides the whole question.

## The short version

Teleport Community Edition, which is the self hosted free build, authenticates
users in two ways: local accounts with WebAuthn, and a GitHub connector. Signing
in against an enterprise directory over **OIDC or SAML is an Enterprise feature**.
There is no configuration flag and no self hosted workaround: the connector
resources exist, and the free build refuses them.

`teleport.yaml` in this directory therefore uses `type: local` with WebAuthn
required. That is a deliberate, working configuration, not a placeholder, and it
is the only one a free deployment has if the identity provider is not GitHub.

## What is in which tier

The grouping below is what decides a design. Tiering moves between releases, so
confirm against the current documentation and pricing page before committing to
it.

| Capability | Community Edition | Enterprise |
| --- | --- | --- |
| Session recording, SSH and Kubernetes | Yes | Yes |
| Recording at the proxy or at the node | Yes | Yes |
| Structured audit log of every session and command | Yes | Yes |
| Role based access control over hosts, clusters and namespaces | Yes | Yes |
| Per session multifactor, WebAuthn | Yes | Yes |
| Local users | Yes | Yes |
| GitHub connector | Yes | Yes |
| OIDC connector | No | Yes |
| SAML connector | No | Yes |
| Access Requests, time bound elevation with approval | No | Yes |
| Access Lists and periodic access review | No | Yes |
| Device Trust, requiring an enrolled device | No | Yes |
| Moderated sessions, a second person watching or joining live | No | Yes |
| Hardware key enforcement, private keys on a PIV token | No | Yes |
| FIPS build | No | Yes |

Two of those rows are worth naming again, because they overlap with work this
repository does elsewhere:

- **Access Requests** is Teleport's time bound elevation with an approval step.
  It is Enterprise. `identity/` in this repository does the same job in the
  directory with PIM eligible assignments, which is where it belongs anyway when
  the elevation has to cover more than one gateway.
- **Device Trust** is Teleport's compliant device requirement. It is Enterprise.
  The Conditional Access policy in `identity/` requires a compliant device at
  sign in instead, which is a different control at a different point and is not
  a substitute for it: Conditional Access checks the device when the token is
  issued, Device Trust checks it on every connection.

## What this means for a small team

- **If the directory is GitHub, the free edition is a complete answer.** Teleport
  Community with the GitHub connector gives directory sign in, recording, RBAC
  and per session MFA with nothing paid.
- **If the directory speaks OIDC or SAML and there is no budget, Teleport is out
  at this point** and Guacamole or Warpgate is the comparison to make, because
  both do OIDC in the free build. `../comparison.md` is that comparison.
- **If there is budget, the question changes shape.** Enterprise brings Access
  Requests, Device Trust and moderated sessions, and at that point Teleport is
  doing several jobs that would otherwise be three separate systems. Comparing
  it against Guacamole on price alone misses that.
- **The free edition plus local WebAuthn accounts is a real option**, and it is
  what `teleport.yaml` configures. The cost is a second account lifecycle:
  joiners and leavers have to be applied to Teleport separately, and a leaver who
  keeps a Teleport local account keeps their access after the directory account
  is gone. If that risk is taken, the leaver process has to name Teleport
  explicitly, and a periodic reconciliation of Teleport users against the
  directory is not optional.

## Recording is not the part that is gated

Nothing above limits the evidence. Community Edition records SSH sessions and
`kubectl exec` sessions, writes a structured audit event per session, and replays
them with `tsh play` and in the web UI. The Enterprise features are about who may
connect and under what conditions, not about what is captured once they do.

That is why `host-baseline/` exists regardless of which gateway or tier is
chosen: the host keeps its own `auditd` and `tlog` record, so the gateway's
recording is corroboration rather than the only copy.
