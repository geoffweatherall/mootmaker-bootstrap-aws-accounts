#!/usr/bin/env bash
# Lists AWS resources in this account that no infrastructure-as-code claims to manage.
#
# WHY THIS EXISTS. Resources that nothing declares are the ones that rot: nobody rebuilds them, no
# review sees them change, and no teardown removes them. They also hide real problems, because a
# stranded resource is indistinguishable from a deliberate one once there are enough of both. This
# reports the difference so the list stays short enough that anything on it is worth reading.
#
# HOW IT DECIDES, and why it is not tag-based. Every managed resource is already recorded, exactly,
# in one of two places: a Terraform state file, or a CloudFormation stack. Both store real AWS
# identifiers, so the answer is a set difference rather than a guess:
#
#     unmanaged = live resources - (terraform state ∪ cloudformation stacks) - allowlists
#
# Tags were considered and rejected. They would add a second, weaker source of truth - one that
# depends on every author remembering to apply it - on top of two that are already authoritative.
# They also cannot cover Route53 records, IAM inline policies or bucket policies, which are not
# taggable at all but ARE in state with their identifiers. And `tag:GetResources` is not currently
# permitted for the SSO role, so enabling it would mean editing the service allowlist in two
# CloudFormation templates to make a less reliable check possible. Tagging is still worth having
# for cost allocation; it is the wrong tool for this.
#
# BOTH IaC SYSTEMS ARE READ, and that is not optional. The credential-rotation stack manages a
# Lambda, an IAM role, an EventBridge rule and an SNS topic entirely in CloudFormation. A
# Terraform-only version of this check reports those four healthy resources as suspicious on every
# run - and a report with permanent false positives is one people stop reading, which is the exact
# problem it was written to solve.
#
# FOUR OUTCOMES, SPLIT INTO TWO HALVES. The report separates what needs a decision from what does
# not, because a list nobody can triage at a glance is a list nobody reads:
#
#   NEEDS ATTENTION  unmanaged resources          - live, and no IaC claims them
#                    undecided coverage gaps      - types this script cannot see and nobody has
#                                                   ruled on. The dangerous one: an unmanaged
#                                                   resource of such a type is silently absent
#                                                   from the section above it.
#   NORMAL           accepted coverage limits     - types we looked at and chose not to check
#                    created by AWS               - cannot be declared even in principle
#
# The distinction between the two middle rows is the whole reason they are separate sections: both
# are things the script cannot see, but one has been reasoned about and the other has not. Collapse
# them and every run reports the same seven sub-resource types forever, which trains the reader to
# skip the section that also carries the genuine finding.
#
# THREE OUTCOMES, NOT TWO. A resource missing from IaC is not automatically a problem: AWS creates
# some resources itself, and they cannot be declared even in principle. Those are reported in their
# own section rather than silently filtered, so the account's inventory stays complete and a reader
# can see that they were considered and classified rather than overlooked. Silently dropping them
# would make the script's own coverage unauditable.
#
# They are identified by IAM PATH rather than by name prefix. AWS guarantees service-linked roles
# live under /aws-service-role/ and Identity Center's provisioned roles under /aws-reserved/, while
# anything genuinely declared here sits at /. A path is a structural fact; a name prefix is a
# convention someone can break.
#
# READ-ONLY. It never deletes anything, which is why it is named "list" rather than "sweep". Acting
# on a finding is a human decision: some will be genuine strays, and some will be things that ought
# to be brought under IaC rather than removed.
#
# WHAT IT DOES NOT COVER. The service list below is hand-maintained, so a resource type nobody
# thought of is invisible to it. That is a real limit and the reason the summary reports how many
# live resources were examined: a number that looks too small is the signal that a service is
# missing from the list.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo ""
  echo "Usage: ./list-unmanaged-resources.sh [--verbose]"
  echo "  --verbose  also print what each managed identifier was matched against"
  exit 0
fi

verbose=0
[[ "${1:-}" == "--verbose" ]] && verbose=1

for tool in aws jq; do
  command -v "${tool}" >/dev/null || { echo "${tool} is required but not installed." >&2; exit 1; }
done

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

account_id="$(aws sts get-caller-identity --query Account --output text)"
# Same derivation the ephemeral-environment scripts use - see mootmaker-bootstrap-terraform's
# README for the "remote-state-<account-id>" convention.
state_bucket="remote-state-${account_id}"
echo "Account ${account_id}, state bucket ${state_bucket}"

# ---------------------------------------------------------------------------
# What Terraform manages
# ---------------------------------------------------------------------------
#
# backups/ is excluded deliberately. Those are historical snapshots, not live state: a resource
# found only in one is managed by nothing today, and counting it would mark a genuine stray as
# healthy - a false negative, which is the direction that matters here.

aws s3api list-objects-v2 --bucket "${state_bucket}" --query 'Contents[].Key' --output text 2>/dev/null \
  | tr '\t' '\n' | grep '\.tfstate$' | grep -v '^backups/' | sort > "${workdir}/states.txt" || true

state_count="$(wc -l < "${workdir}/states.txt")"
: > "${workdir}/managed.txt"
: > "${workdir}/managed-types.txt"

while read -r key; do
  [[ -n "${key}" ]] || continue
  aws s3api get-object --bucket "${state_bucket}" --key "${key}" "${workdir}/state.json" >/dev/null 2>&1 || continue
  # id and arn are the two attributes AWS resources reliably carry. Both are collected because
  # different services are enumerated by different things: Lambda by name, ACM by ARN.
  jq -r '[.resources[]?.instances[]?.attributes | (.arn?, .id?)]
         | .[] | select(. != null and . != "")' "${workdir}/state.json" 2>/dev/null >> "${workdir}/managed.txt" || true
  # Collected here rather than in a second pass: the coverage check below needs the resource TYPES,
  # and downloading every state file twice to get them doubles the slowest part of this script.
  # mode=="managed" excludes data sources - aws_iam_policy_document and aws_caller_identity are not
  # resources, and would otherwise be reported as phantom coverage gaps.
  jq -r '.resources[]? | select(.mode=="managed") | .type' "${workdir}/state.json" 2>/dev/null \
    >> "${workdir}/managed-types.txt" || true
done < "${workdir}/states.txt"

# ---------------------------------------------------------------------------
# What CloudFormation manages
# ---------------------------------------------------------------------------

stacks="$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query 'StackSummaries[].StackName' --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d')"

stack_count=0
while read -r stack; do
  [[ -n "${stack}" ]] || continue
  stack_count=$(( stack_count + 1 ))
  aws cloudformation list-stack-resources --stack-name "${stack}" \
    --query 'StackResourceSummaries[].PhysicalResourceId' --output text 2>/dev/null \
    | tr '\t' '\n' | sed '/^$/d' >> "${workdir}/managed.txt" || true
done <<< "${stacks}"

# An ARN's last segment is the bare name a service's own list call returns, so both forms are
# indexed. EXACT matching only: a substring test would let an unmanaged "foo" hide behind a managed
# "foobar", and a check that silently misses things is worse than no check.
awk 'NF' "${workdir}/managed.txt" | while read -r id; do
  echo "${id}"
  echo "${id##*/}"
  echo "${id##*:}"
done | sort -u > "${workdir}/managed-index.txt"

echo "Read ${state_count} Terraform state file(s) and ${stack_count} CloudFormation stack(s):" \
     "$(wc -l < "${workdir}/managed-index.txt") managed identifier(s)."

# ---------------------------------------------------------------------------
# What is actually live
# ---------------------------------------------------------------------------
#
# Hand-maintained, and the summary prints the total so an implausibly small number is visible.
# Adding a service means adding a line here.

# BEGIN-ENUMERATION - the coverage check below parses THIS block for the AWS CLI service names it
# calls. Deleting a line therefore removes the service from the enumeration AND from the coverage
# claim, in one edit, which is the only way the two can never disagree. Do not restructure these
# lines without checking the parse in "Coverage" still finds them.
{
  aws lambda list-functions --query 'Functions[].FunctionName' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/lambda\t/'
  aws dynamodb list-tables --query 'TableNames[]' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/dynamodb-table\t/'
  aws s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/s3-bucket\t/'
  aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/iam-role\t/'
  aws iam list-policies --scope Local --query 'Policies[].Arn' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/iam-policy\t/'
  aws cognito-idp list-user-pools --max-results 60 --query 'UserPools[].Id' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/cognito-pool\t/'
  aws appsync list-graphql-apis --query 'graphqlApis[].apiId' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/appsync-api\t/'
  aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/cloudfront\t/'
  aws route53 list-hosted-zones --query 'HostedZones[].Id' --output text 2>/dev/null | tr '\t' '\n' | sed 's|/hostedzone/||' | sed 's/^/route53-zone\t/'
  aws sqs list-queues --query 'QueueUrls[]' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/sqs-queue\t/'
  aws sns list-topics --query 'Topics[].TopicArn' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/sns-topic\t/'
  aws acm list-certificates --query 'CertificateSummaryList[].CertificateArn' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/acm-certificate\t/'
  aws events list-rules --query 'Rules[].Name' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/eventbridge-rule\t/'
  aws logs describe-log-groups --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/log-group\t/'
} | grep -P '^[a-z0-9-]+\t\S' > "${workdir}/live.txt" || true
# END-ENUMERATION

live_count="$(wc -l < "${workdir}/live.txt")"

# Roles AWS created for itself, identified by the path it guarantees rather than by their names.
# The two paths mean different things and are reported as such: /aws-service-role/ is a service
# acting on its own behalf, /aws-reserved/ is Identity Center projecting a permission set declared
# in the MANAGEMENT account's identity-center.yaml into this one. The second is genuinely IaC, just
# not IaC that lives here - which is worth saying rather than lumping under "AWS made it".
aws iam list-roles \
  --query 'Roles[?starts_with(Path, `/aws-service-role/`)].RoleName' \
  --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' | sed 's/$/\tservice-linked role, created by the service that uses it/' \
  > "${workdir}/aws-created-roles.txt" || true
aws iam list-roles \
  --query 'Roles[?starts_with(Path, `/aws-reserved/`)].RoleName' \
  --output text 2>/dev/null | tr '\t' '\n' | sed '/^$/d' | sed 's/$/\tIdentity Center permission set, declared in the management account/' \
  >> "${workdir}/aws-created-roles.txt" || true

# ---------------------------------------------------------------------------
# The difference
# ---------------------------------------------------------------------------
#
# Two allowlists, both for things this account cannot manage rather than things it forgot to:
#
#   AWSServiceRoleFor*  AWS creates service-linked roles on first use of a service. They cannot be
#                       declared in Terraform, and deleting one breaks the service that owns it.
#   cf-templates-*      CloudFormation's own bucket for uploaded templates, created by CloudFormation.
#
# A log group whose Lambda IS managed is treated as managed too: Lambda auto-creates the group on
# first invocation, so it is a consequence of a declared resource rather than an undeclared one.
# mootmaker-api declares its own groups explicitly, which is why this only forgives the ones whose
# function is itself accounted for.

: > "${workdir}/unmanaged.txt"
: > "${workdir}/aws-created.txt"
while IFS=$'\t' read -r class name; do
  if [[ "${class}" == "iam-role" ]]; then
    reason="$(awk -F'\t' -v n="${name}" '$1==n{print $2; exit}' "${workdir}/aws-created-roles.txt")"
    if [[ -n "${reason}" ]]; then
      printf '%s\t%s\t%s\n' "${class}" "${name}" "${reason}" >> "${workdir}/aws-created.txt"
      continue
    fi
  fi
  # CloudFormation's own bucket for uploaded templates. It has no path to key off, and CloudFormation
  # creates it on first use whether or not anything asks for it.
  if [[ "${class}" == "s3-bucket" && "${name}" == cf-templates-* ]]; then
    printf '%s\t%s\t%s\n' "${class}" "${name}" "CloudFormation template staging bucket" >> "${workdir}/aws-created.txt"
    continue
  fi

  if [[ "${class}" == "log-group" && "${name}" == /aws/lambda/* ]]; then
    fn="${name#/aws/lambda/}"
    grep -qxF "${fn}" "${workdir}/managed-index.txt" && continue
  fi

  if grep -qxF "${name}" "${workdir}/managed-index.txt" \
     || grep -qxF "${name##*/}" "${workdir}/managed-index.txt" \
     || grep -qxF "${name##*:}" "${workdir}/managed-index.txt"; then
    (( verbose )) && echo "  managed: ${class} ${name}"
    continue
  fi

  printf '%s\t%s\n' "${class}" "${name}" >> "${workdir}/unmanaged.txt"
done < "${workdir}/live.txt"

# ---------------------------------------------------------------------------
# Coverage: does this script know how to look for everything Terraform manages?
# ---------------------------------------------------------------------------
#
# The failure this exists to make visible: a resource type that Terraform manages but this script
# never enumerates is INVISIBLE, and invisible in the dangerous direction. A managed one is
# harmless - it was managed anyway. An UNMANAGED one of that type is exactly what the script exists
# to find, and it is silently absent from the report. "(none)" then says as much about how current
# the enumeration list is as about the account.
#
# Terraform state already names every type it manages, so the script can check its own blind spot
# rather than being trusted about it. The types were collected during the single pass over state
# above.

# Types we have LOOKED AT and decided not to check, with the reason. Being on this list is a
# decision, not an oversight, and that is the whole point of separating it from the gaps below: a
# reader can tell "we thought about this" from "nobody has looked yet".
#
# Most are sub-resources - a policy, a validation, a bucket setting - which AWS has no account-wide
# listing for. They are reachable only by first listing their parent and then asking about each one,
# which is a lot of API calls to detect a stray policy on a bucket that is itself already checked.
# If one of these ever matters, move it out of this list and enumerate it properly.
# Flat pairs - pattern, then reason - rather than one packed "pattern|reason" string. A packed
# string needs a delimiter, and every obvious delimiter is legal inside a regex: "|" is alternation,
# which silently truncated "^aws_s3_bucket_(public_access_block|...)$" at the first bar and left
# bash parsing an unmatched "(". Two array slots cannot collide with the content they hold.
known_uncheckable=(
  '_policy$'                              'attached to a parent resource; no account-wide listing exists'
  '_validation$'                          'a Terraform-side wait, not a distinct AWS object'
  '^aws_route53_record$'                  'listable only per hosted zone, not account-wide'
  '^aws_s3_bucket_(public_access_block|server_side_encryption_configuration)$'
                                          'bucket sub-configuration, not a separate object'
  '^aws_sns_topic_subscription$'          'listable only per topic'
  '^aws_cloudwatch_query_definition$'     'a saved Logs Insights query; carries no cost and cannot be stray'

  # SES, accepted with three different reasons rather than one blanket line, because they are not
  # equally uncheckable and pretending otherwise would make this list untrustworthy.
  '^aws_ses_(domain_dkim|domain_identity_verification)$'
                                          'an attribute of an SES identity, not a separate object'
  '^aws_ses_receipt_rule$'                'listable only per rule set, not account-wide'
  '^aws_ses_(domain_identity|receipt_rule_set|active_receipt_rule_set)$'
                                          'enumerable, but accepted: SES config is small, lives in one repo, and a stray identity costs nothing'
)

declare -A tf_service_to_cli=(
  [acm]=acm [appsync]=appsync [cloudfront]=cloudfront [cloudwatch]=logs [cognito]=cognito-idp
  [dynamodb]=dynamodb [ecr]=ecr [efs]=efs [iam]=iam [kms]=kms [lambda]=lambda [route53]=route53
  [s3]=s3api [secretsmanager]=secretsmanager [ses]=ses [sns]=sns [sqs]=sqs
)

# The CLI services this script actually calls, read from the enumeration block above.
mapfile -t enumerated_cli < <(
  sed -n '/^# BEGIN-ENUMERATION/,/^# END-ENUMERATION/p' "${BASH_SOURCE[0]}" \
    | grep -oP '^\s*aws \K[a-z0-9-]+' | sort -u
)

: > "${workdir}/coverage-gaps.txt"
: > "${workdir}/known-limits.txt"

# Checked at TYPE level, not service level, because those differ in a way that matters: the script
# lists s3 BUCKETS, so aws_s3_bucket_policy would count as covered by a service-level test while
# nothing actually looks for a stray bucket policy. Known limitations are matched first, so a type
# we have already reasoned about never turns up as a fresh gap.
while read -r tf_type; do
  [[ -n "${tf_type}" ]] || continue

  matched=""
  for (( i = 0; i < ${#known_uncheckable[@]}; i += 2 )); do
    pattern="${known_uncheckable[i]}"; reason="${known_uncheckable[i+1]}"
    if [[ "${tf_type}" =~ ${pattern} ]]; then
      printf '%s\t%s\n' "${tf_type}" "${reason}" >> "${workdir}/known-limits.txt"
      matched="yes"; break
    fi
  done
  [[ -n "${matched}" ]] && continue

  tf_service="$(sed -E 's/^aws_([a-z0-9]+)_.*/\1/;s/^aws_([a-z0-9]+)$/\1/' <<< "${tf_type}")"
  cli="${tf_service_to_cli[${tf_service}]:-}"
  if [[ -z "${cli}" ]]; then
    printf '%s\t%s\n' "${tf_type}" "no CLI mapping in this script - add one, or accept it in known_uncheckable" >> "${workdir}/coverage-gaps.txt"
    continue
  fi
  printf '%s\n' "${enumerated_cli[@]+"${enumerated_cli[@]}"}" | grep -qxF "${cli}" && continue
  printf '%s\t%s\n' "${tf_type}" "'aws ${cli}' is not enumerated by this script" >> "${workdir}/coverage-gaps.txt"
done < <(grep '^aws_' "${workdir}/managed-types.txt" | sort -u)

echo ""
echo "==============================================================================="
echo " NEEDS ATTENTION"
echo "==============================================================================="

echo ""
echo "## Unmanaged resources"
echo ""
echo "  Live in this account, claimed by no Terraform state and no CloudFormation stack."
echo "  Either genuinely stray, or something that ought to be brought under IaC."
echo ""
if [[ -s "${workdir}/unmanaged.txt" ]]; then
  sort "${workdir}/unmanaged.txt" | awk -F'\t' '{printf "  %-18s %s\n", $1, $2}'
else
  echo "  (none)"
fi

echo ""
echo "## Coverage gaps nobody has decided about yet"
echo ""
echo "  Types Terraform manages that this script cannot see, and that are NOT on the accepted list"
echo "  below. An unmanaged resource of one of these types would not appear above - the report would"
echo "  look clean and be wrong. Either enumerate it, or accept it into known_uncheckable with a reason."
echo ""
if [[ -s "${workdir}/coverage-gaps.txt" ]]; then
  sort -u "${workdir}/coverage-gaps.txt" | awk -F'\t' '{printf "  %-46s %s\n", $1, $2}'
else
  echo "  (none)"
fi

echo ""
echo "==============================================================================="
echo " NORMAL - reported for completeness, no action needed"
echo "==============================================================================="

echo ""
echo "## Accepted coverage limitations"
echo ""
echo "  Types we looked at and chose not to check, with the reason. On this list by decision rather"
echo "  than by oversight - which is why they are separated from the gaps above."
echo ""
if [[ -s "${workdir}/known-limits.txt" ]]; then
  sort -u "${workdir}/known-limits.txt" | awk -F'\t' '{printf "  %-46s %s\n", $1, $2}'
else
  echo "  (none apply in this account)"
fi

echo ""
echo "## Created by AWS, and correctly outside IaC"
echo ""
echo "  AWS creates these itself and they cannot be declared. Listed rather than filtered, so the"
echo "  inventory stays complete and the classification is visible rather than hidden in a filter."
echo ""
if [[ -s "${workdir}/aws-created.txt" ]]; then
  sort "${workdir}/aws-created.txt" | awk -F'\t' '{printf "  %-18s %-52s %s\n", $1, $2, $3}'
else
  echo "  (none)"
fi

echo ""
unmanaged_count="$(wc -l < "${workdir}/unmanaged.txt")"
echo ""
aws_created_count="$(wc -l < "${workdir}/aws-created.txt")"
gap_count="$(sort -u "${workdir}/coverage-gaps.txt" | wc -l)"
known_count="$(sort -u "${workdir}/known-limits.txt" | wc -l)"
echo "==============================================================================="
if (( unmanaged_count == 0 && gap_count == 0 )); then
  echo " Nothing needs attention."
else
  echo " NEEDS ATTENTION: ${unmanaged_count} unmanaged resource(s), ${gap_count} undecided coverage gap(s)."
fi
echo " Normal: ${known_count} accepted limitation(s), ${aws_created_count} AWS-created, of ${live_count} live resource(s) examined."
echo "==============================================================================="
echo ""
echo "A total that looks too small means a service is missing from the enumeration list in this"
echo "script, not that the account is clean - see the header's \"what it does not cover\"."
