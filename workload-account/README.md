# workload-account

CloudFormation for **member/workload accounts** (this account: 431071856068,
and any future ones). Deploy these from *inside* the account being
configured - not from the management account. Two independent templates:

- `credential-rotation.yaml` - a scheduled Lambda that force-deactivates
  IAM access keys past a configurable age.
- `billing-alert.yaml` - two AWS Budgets that email an alert when this
  account's monthly cost is forecasted or actually exceeds a low and a
  high threshold.

They don't depend on each other and can be deployed in either order.

**Day-to-day account access is via IAM Identity Center, not an IAM user.**
See the root README's ["Configuring AWS access on a new
machine"](../README.md#configuring-aws-access-on-a-new-machine) section for
how to sign in, and
[../management-account/README.md](../management-account/README.md#identity-centeryaml)
for how that's set up. There is deliberately no IAM-user-based break-glass
role in this account either - the AWS account root user is the sole
fallback if Identity Center is ever unreachable. An earlier version of this
project had one (`admin-guardrail.yaml`, an MFA-gated assumable role); it
was removed once Identity Center was confirmed working, along with the
last IAM user in this account.

## Deploying

Open CloudFormation in 431071856068, **Create stack** > upload the
template. Name the stack after the template filename (e.g.
`credential-rotation`, `billing-alert`) - the convention this project uses
for every stack, so it's obvious at a glance which template deployed which
stack. `credential-rotation.yaml` creates named IAM resources, so the
console will ask you to acknowledge **"I acknowledge that AWS
CloudFormation might create IAM resources with custom names"**
(`CAPABILITY_NAMED_IAM`) - that's expected. `billing-alert.yaml` needs no
capability acknowledgement.

`cloudformation:*` is included in both the service-allowlist SCP
(`../management-account/scp-guardrails.yaml`) and the IAM Identity Center
permission set (`../management-account/identity-center.yaml`), so a normal
Identity Center session can manage stacks here - root isn't required for
this, only for changes to the management-account stacks themselves.

## credential-rotation.yaml

Runs `iam-key-rotation-enforcer` (Lambda, Python) once a day by default,
deactivating (not deleting) any Active IAM access key older than
`pMaxKeyAgeDays` (default 90). Deactivation is reversible by an admin if
it was a mistake, but ordinary users have no standing permission to
reactivate their own keys - that's deliberate, otherwise the enforcement
would be optional.

If you set `pNotificationEmail`, you'll get an email whenever a key is
deactivated (the subscription needs confirming once, via a link AWS emails
you after deploy). You can also add more subscribers to the
`RotationNotificationTopic` output ARN later without redeploying.

This scans every IAM user's access keys account-wide. With no IAM users
currently in this account, it has nothing to act on day to day - it's
here as a safety net in case an IAM user (and a key) is ever created again
in the future, deliberately or otherwise.

## billing-alert.yaml

Two `AWS::Budgets::Budget` resources - `pLowBudgetUsd` (default $1, an early
"something's using more than expected" signal) and `pHighBudgetUsd` (default
$10, a "this is a lot more than expected" sanity check) - each with the same
two email notifications:

- **FORECASTED** - fires as soon as AWS's cost forecast for the rest of the
  month projects a total over the threshold. The earliest possible warning,
  but the forecast is unreliable in the first few days of a billing cycle
  with little usage data to project from.
- **ACTUAL** - fires once real month-to-date spend crosses the threshold.
  Later, but reliable regardless of how little usage history exists.

AWS Budgets emails `pAlertEmail` directly - no SNS topic, no subscription
link to confirm. **Free, but exactly at the limit**: the first two budgets
per AWS account cost nothing, and this template creates exactly two. That's
the full free allowance for this account - any additional budget created
here later (including manually, via the console) will cost ~$0.02/day.
