#!/usr/bin/env bash
#
# Run one command with short-lived ManagementStackOperator credentials:
#
#   management-account/with-management-credentials.sh ./deploy-stack.sh management-account/identity-center.yaml
#
# Sign in as the management user (geoff-management), not your everyday user,
# in a PRIVATE WINDOW - a browser profile holds one access portal sign-in at
# a time. The script then:
#
#   1. signs in under a throwaway HOME, so the management token never reaches
#      ~/.aws/sso/cache and your everyday session is untouched;
#   2. takes ONE set of role credentials (one hour, per the permission set);
#   3. signs that session out on the server and deletes the throwaway HOME;
#   4. runs the command with those credentials in its environment only.
#
# Nothing can renew the credentials, so they stop working within the hour.
# Agents never run this - Geoff does (see AGENTS.md).

set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <command> [args...]" >&2; exit 1; }

START_URL=https://d-90667673bd.awsapps.com/start
MANAGEMENT_ACCOUNT=339140804537
ROLE=ManagementStackOperator

scratch=$(mktemp -d)
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT INT TERM

mkdir -p "$scratch/.aws"
cat >"$scratch/.aws/config" <<EOF
[profile management]
sso_session = management
sso_account_id = $MANAGEMENT_ACCOUNT
sso_role_name = $ROLE
region = us-east-1

[sso-session management]
sso_start_url = $START_URL
sso_region = us-east-1
sso_registration_scopes = sso:account:access
EOF

in_scratch() { env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  HOME="$scratch" AWS_CONFIG_FILE="$scratch/.aws/config" AWS_SHARED_CREDENTIALS_FILE=/dev/null aws "$@"; }

echo "Open the URL below in a PRIVATE WINDOW and sign in as geoff-management." >&2
in_scratch sso login --profile management --no-browser --use-device-code >&2

creds=$(in_scratch configure export-credentials --profile management --format process)

# Ends the session server-side as well as locally. Inside the throwaway HOME
# the only cached session is this one, so the everyday one is unaffected.
in_scratch sso logout >&2
cleanup

AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds")
AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds")
AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds")
expires=$(jq -r .Expiration <<<"$creds")
unset creds

echo "Management credentials valid until $expires; session signed out." >&2

exec env -u AWS_PROFILE \
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" AWS_REGION=us-east-1 "$@"
