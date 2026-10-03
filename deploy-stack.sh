#!/usr/bin/env bash
#
# Apply one of this repo's templates to its stack: create a change set, show
# what it would do, and execute it only when a person at a terminal says yes.
#
#   ./deploy-stack.sh <template.yaml> [Key=Value ...]
#
# The stack name is the template's filename without .yaml (this repo's
# convention). Which account the template belongs to comes from its
# directory, and the script refuses to run with credentials for any other
# account. Existing parameter values are kept unless overridden with
# Key=Value. Management-account stacks are always applied through the
# mootmaker-management-cloudformation service role - get credentials for
# them with management-account/with-management-credentials.sh.
#
# With no terminal (an agent, a pipe), it stops after showing the change set
# and deletes it - it never executes unattended.

set -euo pipefail

REGION=us-east-1
MANAGEMENT_ACCOUNT=339140804537
WORKLOAD_ACCOUNT=431071856068
SERVICE_ROLE_ARN="arn:aws:iam::${MANAGEMENT_ACCOUNT}:role/mootmaker-management-cloudformation"

die() { echo "deploy-stack: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: $0 <template.yaml> [Key=Value ...]"
template=$1; shift
[[ -f $template ]] || die "no such template: $template"

stack=$(basename "$template" .yaml)
dir=$(basename "$(cd "$(dirname "$template")" && pwd)")

case $dir in
  management-account) expected_account=$MANAGEMENT_ACCOUNT ;;
  workload-account) expected_account=$WORKLOAD_ACCOUNT ;;
  *) die "$template is not under management-account/ or workload-account/" ;;
esac

if [[ $stack == management-access ]]; then
  die "management-access is applied by root in the console, never from here - see management-account/README.md"
fi

account=$(aws sts get-caller-identity --query Account --output text) \
  || die "no working AWS credentials"
[[ $account == "$expected_account" ]] \
  || die "$template belongs to account $expected_account, but these credentials are for $account"

role_args=()
[[ $dir == management-account ]] && role_args=(--role-arn "$SERVICE_ROLE_ARN")

body="file://$template"
summary=$(aws cloudformation validate-template --region "$REGION" --template-body "$body")
capabilities=$(jq -r '.Capabilities // [] | join(" ")' <<<"$summary")

if aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" >/dev/null 2>&1; then
  change_set_type=UPDATE
  existing=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" \
    --query 'Stacks[0].Parameters[].ParameterKey' --output json)
else
  change_set_type=CREATE
  existing='[]'
fi

# Every parameter the template declares: overridden if given, otherwise the
# stack's current value if it has one, otherwise left to the template default.
declare -A overrides=()
for kv in "$@"; do
  [[ $kv == *=* ]] || die "parameter override must be Key=Value: $kv"
  overrides[${kv%%=*}]=${kv#*=}
done
params='[]'
for key in $(jq -r '.Parameters[].ParameterKey' <<<"$summary"); do
  if [[ -v overrides[$key] ]]; then
    params=$(jq --arg k "$key" --arg v "${overrides[$key]}" \
      '. + [{ParameterKey: $k, ParameterValue: $v}]' <<<"$params")
    unset "overrides[$key]"
  elif jq -e --arg k "$key" 'index($k) != null' <<<"$existing" >/dev/null; then
    params=$(jq --arg k "$key" '. + [{ParameterKey: $k, UsePreviousValue: true}]' <<<"$params")
  fi
done
[[ ${#overrides[@]} -eq 0 ]] || die "template has no parameter(s): ${!overrides[*]}"

if [[ $change_set_type == UPDATE ]]; then
  echo "== Deployed template vs $template"
  # Both through $(...) so neither side's trailing newlines show up as a diff.
  deployed=$(aws cloudformation get-template --region "$REGION" --stack-name "$stack" \
    --template-stage Original --query TemplateBody --output text)
  diff -u --label "deployed:$stack" --label "$template" \
    <(printf '%s\n' "$deployed") <(printf '%s\n' "$(<"$template")") \
    && echo "(identical)"
  echo
fi

change_set="deploy-stack-$(date -u +%Y%m%dT%H%M%SZ)"
cap_args=()
[[ -n $capabilities ]] && cap_args=(--capabilities $capabilities)

aws cloudformation create-change-set --region "$REGION" \
  --stack-name "$stack" --change-set-name "$change_set" \
  --change-set-type "$change_set_type" --template-body "$body" \
  --parameters "$params" "${cap_args[@]}" "${role_args[@]}" >/dev/null

delete_change_set() {
  if [[ $change_set_type == CREATE ]]; then
    # A declined CREATE leaves an empty REVIEW_IN_PROGRESS stack behind.
    aws cloudformation delete-stack --region "$REGION" --stack-name "$stack"
  else
    aws cloudformation delete-change-set --region "$REGION" \
      --stack-name "$stack" --change-set-name "$change_set"
  fi
}

if ! aws cloudformation wait change-set-create-complete --region "$REGION" \
     --stack-name "$stack" --change-set-name "$change_set" 2>/dev/null; then
  reason=$(aws cloudformation describe-change-set --region "$REGION" \
    --stack-name "$stack" --change-set-name "$change_set" --query StatusReason --output text)
  delete_change_set
  if [[ $reason == *"didn't contain changes"* || $reason == *"No updates are to be performed"* ]]; then
    echo "== $stack: no changes"
    exit 0
  fi
  die "change set failed: $reason"
fi

echo "== Change set $change_set for $stack ($change_set_type)"
changes=$(aws cloudformation describe-change-set --region "$REGION" \
  --stack-name "$stack" --change-set-name "$change_set" --query 'length(Changes)')
if [[ $changes == 0 ]]; then
  # Template text (comments, descriptions) or the service role changed, but
  # no resource does - executing it only updates what the stack records.
  echo "No resource changes - only the stored template or stack settings differ."
else
  aws cloudformation describe-change-set --region "$REGION" \
    --stack-name "$stack" --change-set-name "$change_set" \
    --query 'Changes[].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
    --output table
fi

if [[ ! -t 0 ]] || ! { exec 3</dev/tty; } 2>/dev/null; then
  delete_change_set
  echo "deploy-stack: no terminal, so not executing; change set deleted" >&2
  exit 3
fi
read -r -u 3 -p "Execute this change set? [y/N] " answer
if [[ $answer != y && $answer != Y ]]; then
  delete_change_set
  echo "Not executed; change set deleted."
  exit 0
fi

aws cloudformation execute-change-set --region "$REGION" \
  --stack-name "$stack" --change-set-name "$change_set"
waiter=stack-update-complete
[[ $change_set_type == CREATE ]] && waiter=stack-create-complete
echo "Executing; waiting for $stack..."
if aws cloudformation wait "$waiter" --region "$REGION" --stack-name "$stack"; then
  echo "== $stack: $(aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" \
    --query 'Stacks[0].StackStatus' --output text)"
else
  aws cloudformation describe-stack-events --region "$REGION" --stack-name "$stack" \
    --max-items 15 --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
    --output table >&2
  die "$stack did not reach a complete state"
fi
