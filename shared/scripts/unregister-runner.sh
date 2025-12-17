#!/bin/bash
set -eo pipefail

# Unregister/delete a Bitbucket repository runner
# Usage: unregister-runner.sh
#
# Required environment variables:
#   WORKSPACE_UUID - Bitbucket workspace UUID (with curly braces)
#   REPO_UUID - Bitbucket repository UUID (with curly braces)
#   RUNNER_UUID - Runner UUID to delete (with curly braces)
#
# Authentication (one of the following):
#   Option 1 - OAuth Consumer:
#     BITBUCKET_OAUTH_CLIENT_ID - OAuth Consumer Key
#     BITBUCKET_OAUTH_CLIENT_SECRET - OAuth Consumer Secret
#
#   Option 2 - App Password:
#     BITBUCKET_USERNAME - Bitbucket username
#     BITBUCKET_APP_PASSWORD - Bitbucket app password

: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required'}
: ${REPO_UUID:?'REPO_UUID is required'}
: ${RUNNER_UUID:?'RUNNER_UUID is required'}

SCRIPTS_DIR="$(dirname "$0")"

# URL-encode UUIDs (curly braces must be encoded)
WORKSPACE_UUID_ENCODED=$(echo "$WORKSPACE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
REPO_UUID_ENCODED=$(echo "$REPO_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
RUNNER_UUID_ENCODED=$(echo "$RUNNER_UUID" | sed 's/{/%7B/g; s/}/%7D/g')

API_URL="https://api.bitbucket.org/internal/repositories/${WORKSPACE_UUID_ENCODED}/${REPO_UUID_ENCODED}/pipelines-config/runners/${RUNNER_UUID_ENCODED}"

echo "Unregistering runner: ${RUNNER_UUID}"
echo "  Workspace: ${WORKSPACE_UUID}"
echo "  Repository: ${REPO_UUID}"

# Get authentication header
AUTH_HEADER=$("${SCRIPTS_DIR}/bitbucket-auth.sh")

RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X DELETE "${API_URL}" \
  -H "Authorization: ${AUTH_HEADER}" \
  -H "Content-Type: application/json")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
  echo "Runner unregistered successfully"
elif [ "$HTTP_CODE" = "404" ]; then
  echo "Runner not found (already deleted or never existed)"
else
  echo "Failed to unregister runner (HTTP ${HTTP_CODE}):"
  echo "$BODY"
  # Don't exit with error - cleanup should be best-effort
fi
