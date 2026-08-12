# management-account

CloudFormation for the AWS Organizations **management account** (339140804537).
This deploys the Service Control Policies (SCPs) that lock down which AWS
regions and services member accounts can use - restrictions that member
account admins cannot remove, because SCPs live outside the account they
restrict and are only editable from here.

Three independent templates:

- `scp-guardrails.yaml` - the region/service allow-list SCPs.
- `billing-alert.yaml` - an AWS Budget that emails an alert on any
  non-trivial spend in this account.
- `identity-center.yaml` - an IAM Identity Center admin group, permission
  set, and account assignment, so day-to-day work uses short-lived SSO
  sessions instead of a long-lived IAM user access key.

## Prerequisites (should already be true)

- Organizations is enabled on this account, in **"All features"** mode
  (not "Consolidated billing" - SCPs don't work in that mode). Check under
  Organizations console > Settings.
- The member account (431071856068) has already accepted its invitation
  and shows up under Organizations > Accounts.

## What this does

Two SCPs, both attached to the account IDs listed in `pTargetAccountIds`:

- **region-allowlist** - denies any action outside the regions in
  `pAllowedRegions`, except for AWS's inherently-global services (IAM,
  Organizations, Route53, CloudFront, Support, STS, etc.) which are exempt
  so you don't lock yourself out of essentials.
- **service-allowlist** - allows only the service action prefixes in
  `pAllowedServiceActions`. Anything not listed is denied by omission -
  this is what blocks EC2 and everything else you don't use, without
  having to enumerate what to block.

Defaults are scoped to exactly what mootmaker-api/mootmaker-webapp/
mootmaker-tools currently use: `s3, dynamodb, lambda, appsync, cognito-idp,
cloudfront, iam, sts, logs, cloudwatch` (the last for viewing metrics/alarms
in the workspace account, e.g. CloudWatch Logs Insights / metric dashboards),
plus `events` (EventBridge - schedules mootmaker-tools/sample-data-topup's
weekly Lambda trigger), plus `budgets, ce, support, trustedadvisor, health`
for account hygiene and a couple of `organizations:Describe*/List*` calls
for basic self-service visibility from the member account.

**Important:** none of this applies to the management account itself - SCPs
never restrict the account they're managed from, only member accounts.
That's intentional; it's what keeps this guardrail out of reach of the
member account's admin user even if their credentials leak.

## Deploying scp-guardrails.yaml

1. Log in to **339140804537** as the **root user** (console).
2. Go to **CloudFormation** (any region - `us-east-1` is fine;
   `AWS::Organizations::Policy` resources are global regardless of the
   stack's region).
3. **Create stack** > **With new resources** > upload `scp-guardrails.yaml`.
4. Review the parameters - the default `pTargetAccountIds` already
   targets `431071856068`. Adjust `pAllowedRegions` /
   `pAllowedServiceActions` first if you want something different from
   the defaults.
5. No IAM capability checkbox is needed for this template - it only
   creates Organizations policies, not IAM resources.
6. Create the stack.

This takes effect immediately on the target account(s) - unlike joining
the organization (which changes nothing by itself, since the default
`FullAWSAccess` SCP grants everything), attaching these SCPs actively
restricts what the member account can do from that moment on.

## billing-alert.yaml

An `AWS::Budgets::Budget` that emails `pAlertEmail` the moment any spend
above one cent (`ACTUAL`, `ABSOLUTE_VALUE`, $0.01) shows up in this account.
No `FORECASTED` notification - at a one-cent threshold it wouldn't add
anything, `ACTUAL` alone fires essentially immediately. This account is
meant to hold no workloads and no IAM users (see
[../workload-account/README.md](../workload-account/README.md)'s admin
guardrail for why), so this isn't cost management, it's a tripwire: any
recorded cost here at all means something exists in this account that
shouldn't. Deploy the same way as `scp-guardrails.yaml` above - no IAM
capability needed, this template doesn't touch IAM either. **Free**: this
is the only budget in this account, well under the free-2-per-account
limit.

## identity-center.yaml

Replaces day-to-day use of a long-lived IAM user access key with short-lived
IAM Identity Center (successor to AWS SSO) sessions, MFA-protected by
default. There is deliberately no separate IAM-user-based break-glass role
alongside this - the sole fallback if Identity Center is ever unreachable
is the AWS account root user (see "Do I still need a break-glass IAM role?"
below).

Two parts to setting this up: a few manual, one-time, console-only steps
(nothing here can be templated - see why below), then deploying the
CloudFormation stack with the values those steps produce.

### Prerequisites: enabling IAM Identity Center (manual, one-time)

CloudFormation cannot do this part. `AWS::SSO::Instance` only creates a
*standalone* account-level instance; an *organization* instance (the kind
that spans your management account and 431071856068) has to be enabled
once, by hand, from the management account:

1. Log in to **339140804537** as the **root user** (console).
2. Go to **IAM Identity Center** and choose **Enable**. Pick your identity
   source as **Identity Center directory** (the built-in one - no external
   IdP needed for a single person).
3. Note the **home Region** it's enabled in (top-right of the console,
   pick one from `pAllowedRegions`, e.g. `us-east-1` - once set, this
   can't be changed without deleting and recreating the instance).
4. On the **Settings** page, copy down two values from the "Identity
   source" card - you'll need both as stack parameters:
   - **Instance ARN**
   - **Identity store ID**
5. Still on **Settings**, check the **Authentication** tab: AWS enables
   MFA by default for new instances, so this should already show MFA
   required "Every time they sign in" or similar. If not, turn it on here
   - there's no CloudFormation resource for this setting, it's
   console/API only.
6. Go to **Users** > **Add user**. Create a user for yourself (email,
   name). You'll set a password and enroll an MFA device the first time
   you sign in through the resulting access portal URL.
7. Once created, open your user and copy its **User ID** from the
   **General** tab (not your email/username) - this is `pAdminUserId`.

You should now have three values: **Instance ARN**, **Identity store ID**,
**your User ID**.

### Deploying identity-center.yaml

1. Still logged in to **339140804537** as root, in the **same Region** you
   enabled Identity Center in (step 3 above).
2. **CloudFormation** > **Create stack** > **With new resources** > upload
   `identity-center.yaml`.
3. Fill in the parameters:
   - `pInstanceArn`, `pIdentityStoreId`, `pAdminUserId` - the three values
     from the prerequisites above (no defaults - you must supply these).
   - Everything else has a sensible default already matching
     `scp-guardrails.yaml` - only change `pAllowedRegions`/
     `pAllowedServiceActions` if you changed those elsewhere too, and keep
     both in sync if you do.
4. No capability checkbox needed - this template creates no `AWS::IAM::*`
   resources, only Identity Center/Identity Store ones.
5. Create the stack. Note the **AdminPermissionSetArn** output if you want
   it later, though you won't need it directly for day-to-day use.

### Using it

See the root README's ["Configuring AWS access on a new
machine"](../README.md#configuring-aws-access-on-a-new-machine) section for
the exact `~/.aws/config` file to use, how to sign in, and how to verify it
worked - that's the same for any machine, not specific to setting up this
stack.

### Do I still need a break-glass IAM role?

No, by design here - there is no IAM-user-based break-glass role in this
setup (an earlier version of this project had one, `GuardrailAdminRole`;
it was deliberately removed once Identity Center was confirmed working,
along with the last remaining IAM user). The account's only standing
access paths are Identity Center and the AWS account root user. If
Identity Center is ever unreachable, root login (console) is the fallback
- there is no faster middle-ground path, and that's an accepted
trade-off in exchange for one fewer standing identity in the account.

## Verifying

From a session **in the member account** (431071856068), confirm the
restrictions are live:

```
# Should fail - ec2 isn't in the allow-list
aws ec2 describe-instances --region us-east-1

# Should fail - region isn't in the allow-list
aws s3 ls --region eu-west-1

# Should still work - s3 is allowed, region is allowed
aws s3api list-buckets --region us-east-1
```

Also worth doing once: a full `terraform apply` / `terraform destroy`
cycle against the `test` environment in mootmaker-api and
mootmaker-webapp, to confirm nothing legitimate got caught by the
service allow-list before you rely on this for real.

## Covering more member accounts, or adjusting the lists later

- **New member account**: add its account ID to `pTargetAccountIds` and
  update the stack. No new SCP required.
- **New service/region needed**: add it to `pAllowedServiceActions` /
  `pAllowedRegions` and update the stack.

Both SCPs together are capped at 5120 characters of policy content each
(the AWS SCP size limit) - comfortably far from that with the current
lists, but worth knowing if the allow-list grows a lot over time.
