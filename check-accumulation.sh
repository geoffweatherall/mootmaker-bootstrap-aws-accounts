#!/usr/bin/env bash
# Checks that nothing in this account accumulates without a bound (mootmaker#77).
#
# WHY THIS EXISTS. principles.md states it as a rule: under steady usage the bill should be flat,
# and anything that grows with TIME rather than with use is a defect. Nothing enforced that. Each
# known breach was found by someone happening to look - orphaned AppSync log groups (#71), Lambda
# versions piling up, meeting history nobody deleted - and a fix for one does not stop the next.
# This is the check that would have caught each of them without anyone remembering to look.
#
# WHAT IT CHECKS. Each is a single read of state that already exists, so none needs a paid alarm
# (CloudWatch alarms are a standing US$0.10/month per metric - the shape this check exists to
# catch):
#
#   1. Log groups with no retention. AWS creates a group with "never expire" whenever something
#      logs to a group that does not exist, so any service writing outside Terraform's knowledge
#      leaves one. Every group in this account is meant to expire.
#   2. Lambda published versions. SnapStart publishes one per code change; mootmaker-api's
#      deploy/prune-lambda-versions.sh keeps the live alias's plus the newest three. More than four
#      means the pruning has stopped running.
#   3. The history-cleanup job is still running, in each standing environment. Its own stored
#      retention boundary is a dead-man's switch: the job advances it weekly (Mondays 14:17 UTC) to
#      Monday(today - 30), so it is 35-42 days old in normal operation. Older than 43 means a run
#      was missed, and meeting history is growing with time again. Lambda failure destinations
#      would not catch this - they fire when an invocation fails, not when it never happens.
#
# Also REPORTED, never failed on: each standing environment's DynamoDB item counts, so a reading
# can be compared with the last one by eye. A single run cannot tell growth with time from growth
# with use, and pretending it could would make this fail on legitimate traffic.
#
# READ-ONLY. Exits 1 if any check fails, so the scheduled run in mootmaker-ephemeral-envs'
# sweep.yml goes red and GitHub notifies. Runs under the release deploy role there and under
# WorkloadAdministrator locally; both can make every call below.
#
# Usage: ./check-accumulation.sh
set -euo pipefail

STANDING_ENVIRONMENTS=(production test)
MAX_LAMBDA_VERSIONS=4
MAX_RETENTION_BOUNDARY_AGE_DAYS=43

failures=0
fail() { echo "  FAIL: $*"; failures=$(( failures + 1 )); }
ok() { echo "  ok:   $*"; }

echo "## 1. Log groups without retention"
mapfile -t unbounded_groups < <(
  aws logs describe-log-groups --query 'logGroups[?retentionInDays==null].logGroupName' --output text \
    | tr '\t' '\n' | sed '/^$/d'
)
if (( ${#unbounded_groups[@]} == 0 )); then
  ok "every log group expires"
else
  for group in "${unbounded_groups[@]}"; do fail "${group} never expires"; done
fi

echo ""
echo "## 2. Lambda published versions (at most ${MAX_LAMBDA_VERSIONS} per function)"
mapfile -t functions < <(
  aws lambda list-functions --query 'Functions[].FunctionName' --output text | tr '\t' '\n' \
    | grep -- '-mootmaker-' | sort
)
over=0
for fn in "${functions[@]+"${functions[@]}"}"; do
  count="$(aws lambda list-versions-by-function --function-name "${fn}" \
    --query "length(Versions[?Version!='\$LATEST'])" --output text)"
  if (( count > MAX_LAMBDA_VERSIONS )); then
    fail "${fn} has ${count} published versions"
    over=$(( over + 1 ))
  fi
done
(( over == 0 )) && ok "${#functions[@]} functions, none over the limit"

echo ""
echo "## 3. History cleanup still running (retention boundary at most ${MAX_RETENTION_BOUNDARY_AGE_DAYS} days old)"
today_epoch="$(date -u -d "$(date -u +%F)" +%s)"
for env in "${STANDING_ENVIRONMENTS[@]}"; do
  table="${env}-mootmaker-meetings"
  if ! aws dynamodb describe-table --table-name "${table}" >/dev/null 2>&1; then
    echo "  --    ${env}: no meetings table, not deployed"
    continue
  fi
  boundary="$(aws dynamodb get-item --table-name "${table}" --consistent-read \
    --key '{"pk":{"S":"CONFIG#retention"}}' --query 'Item.earliestRetainedDate.S' --output text)"
  if [[ ! "${boundary}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    fail "${env}: no readable retention boundary (got '${boundary}')"
    continue
  fi
  age_days=$(( (today_epoch - $(date -u -d "${boundary}" +%s)) / 86400 ))
  if (( age_days > MAX_RETENTION_BOUNDARY_AGE_DAYS )); then
    fail "${env}: retention boundary ${boundary} is ${age_days} days old - the cleanup job has missed a run"
  else
    ok "${env}: retention boundary ${boundary} (${age_days} days old)"
  fi
done

echo ""
echo "## Reported, not checked: standing environments' DynamoDB item counts (updated by AWS ~6-hourly)"
for env in "${STANDING_ENVIRONMENTS[@]}"; do
  for table in meetings rooms people; do
    name="${env}-mootmaker-${table}"
    if reading="$(aws dynamodb describe-table --table-name "${name}" \
        --query 'Table.[ItemCount,TableSizeBytes]' --output text 2>/dev/null)"; then
      read -r items bytes <<< "${reading}"
      printf '  %-32s %8s items %12s bytes\n' "${name}" "${items}" "${bytes}"
    fi
  done
done

echo ""
if (( failures > 0 )); then
  echo "${failures} accumulation check(s) failed."
  exit 1
fi
echo "Nothing accumulating."
