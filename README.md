# mootmaker-bootstrap-aws-accounts

CloudFormation that locks down the two AWS accounts behind the
[mootmaker](https://github.com/geoffweatherall/mootmaker) project - the
Organizations management account and the workload account that
[mootmaker-api](https://github.com/geoffweatherall/mootmaker-api) and
[mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp)
deploy into. Not a generic reusable template: account IDs, the region/service
allow-lists, and the IAM Identity Center setup below are all specific to
this project's two accounts.

Two parts, one per account:

- [management-account/](management-account/README.md) - CloudFormation for the
  Organizations management account (339140804537): SCP guardrails, a billing
  tripwire, IAM Identity Center (SSO) setup, and the narrow SSO access that
  lets those stacks be updated from the command line instead of as root.
- [workload-account/](workload-account/README.md) - CloudFormation for the
  workload account (431071856068, and any future ones): scheduled credential
  rotation and billing alerts. This is the account
  [mootmaker-api](https://github.com/geoffweatherall/mootmaker-api) and
  [mootmaker-webapp](https://github.com/geoffweatherall/mootmaker-webapp)
  deploy their `test`/`production`/ephemeral environments into (see each
  repo's own README for their `deploy.sh`), and where
  [mootmaker-domain](https://github.com/geoffweatherall/mootmaker-domain)
  and [mootmaker-email-testing](https://github.com/geoffweatherall/mootmaker-email-testing)'s
  email pipeline deploy once, persistently, shared across every environment.

## Configuring AWS access on a new machine

Once IAM Identity Center is set up (see
[management-account/README.md](management-account/README.md#identity-centeryaml)),
day-to-day access to the workload account uses short-lived SSO sessions - no
access key ever touches disk, on this machine or any other.

Replace the entire contents of `~/.aws/config` with exactly this:

```ini
[default]
sso_session = mootmaker
sso_account_id = 431071856068
sso_role_name = WorkloadAdministrator
region = us-east-1

[profile mootmaker-billing]
sso_session = mootmaker
sso_account_id = 339140804537
sso_role_name = ManagementBillingReadOnly
region = us-east-1

[sso-session mootmaker]
sso_start_url = https://d-90667673bd.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

`mootmaker-billing` is read-only access to the organization's bill, Cost
Explorer and Free Tier usage in the management account - only used when named
with `--profile mootmaker-billing`. There is deliberately **no** profile for
changing the management account: that goes through a separate Identity Center
user and [with-management-credentials.sh](management-account/with-management-credentials.sh),
see [Applying stacks](#applying-stacks) below.

Leave `~/.aws/credentials` empty (or delete it) - it's not used by this setup.

Then, in any terminal:

```bash
aws sso login
```

This opens a browser, you sign in (MFA prompt included), and short-lived
credentials (1 hour, per `pSessionDurationIso8601` in
[identity-center.yaml](management-account/identity-center.yaml)) are cached
locally - the CLI silently refreshes them for as long as your underlying SSO
session lasts (24 hours from `aws sso login`, an instance-wide Identity Center
setting), so this is not something you need to think about day to day.
Because this is the
`[default]` profile, every AWS CLI/Terraform command - including this
workspace's `deploy.sh` scripts - picks them up automatically, no `--profile`
flag or `AWS_PROFILE` env var needed.

Verify it worked:

```bash
aws sts get-caller-identity
```

Expected output shape:

```json
{
    "UserId": "...:<your-username>",
    "Account": "431071856068",
    "Arn": "arn:aws:sts::431071856068:assumed-role/AWSReservedSSO_WorkloadAdministrator_.../<your-username>"
}
```

When the session expires (you'll see `NoCredentials` or `ExpiredToken`
errors), just run `aws sso login` again - no other setup needed.

**Common mistake:** `~/.aws/config` must have exactly one `[default]`
section. If you're merging these lines into an existing file that already
has a `[default]` block (e.g. left over from a plain access-key setup),
merge into that one block rather than adding a second `[default]` header -
a duplicate section is a hard parse error (`Unable to parse config file`),
not something that silently merges.

### Note on the values above

`sso_start_url`, `sso_account_id`, and `sso_role_name` are specific to this
project's IAM Identity Center instance - copy them exactly as shown. They
only change if the instance is re-created or the `identity-center.yaml`
stack is redeployed with different parameter values (see
[management-account/README.md](management-account/README.md#identity-centeryaml)).

## Applying stacks

Every stack in this repo is applied from the command line with
[deploy-stack.sh](deploy-stack.sh) - no console, no root, except for
`management-access` (see below):

```bash
./deploy-stack.sh workload-account/credential-rotation.yaml
./deploy-stack.sh workload-account/billing-alert.yaml pLowBudgetUsd=2   # override a parameter
```

It names the stack after the template file, checks your credentials are for
the account the template's directory belongs to, shows the deployed template
diffed against the local one, creates a change set, prints it, and executes it
only if you answer `y` at a terminal. Parameters you don't override keep the
stack's current values. Without a terminal it stops after printing the change
set and deletes it, so an agent can preview a change but never apply one.

**Workload account** stacks use your everyday `[default]` profile
(`WorkloadAdministrator`).

**Management account** stacks need the management user's credentials, which
your everyday session cannot get:

```bash
management-account/with-management-credentials.sh ./deploy-stack.sh management-account/identity-center.yaml
```

It prints a sign-in URL and code. Open it in a **private window** and sign in
as **geoff-management** (not your everyday user). The script takes one hour of
`ManagementStackOperator` credentials, signs that session out straight away,
and runs the command with them. Changes are then made by the
`mootmaker-management-cloudformation` service role, which `deploy-stack.sh`
passes automatically. See [management-account/README.md](management-account/README.md#management-accessyaml)
for what that role can and cannot do.

`management-account/management-access.yaml` - the access just described - is
the one stack still applied by root in the console, deliberately.

