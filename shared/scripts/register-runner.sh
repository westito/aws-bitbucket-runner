#!/bin/bash
set -eo pipefail

# Register a new Bitbucket repository runner
# Usage: register-runner.sh
#
# Required environment variables:
#   WORKSPACE_UUID - Bitbucket workspace UUID (with curly braces)
#   REPO_UUID - Bitbucket repository UUID (with curly braces)  
#   RUNNER_NAME - Name for the runner
#
# Authentication (one of the following):
#   Option 1 - OAuth Consumer:
#     BITBUCKET_OAUTH_CLIENT_ID - OAuth Consumer Key
#     BITBUCKET_OAUTH_CLIENT_SECRET - OAuth Consumer Secret
#
#   Option 2 - App Password:
#     BITBUCKET_USERNAME - Bitbucket username
#     BITBUCKET_APP_PASSWORD - Bitbucket app password
#
# Optional:
#   RUNNER_LABELS - Comma-separated labels (set by codebuild-entrypoint.sh based on architecture)
#
# Outputs runner credentials as JSON to stdout

: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required'}
: ${REPO_UUID:?'REPO_UUID is required'}
: ${RUNNER_NAME:?'RUNNER_NAME is required'}
: ${RUNNER_LABELS:?'RUNNER_LABELS is required (set by codebuild-entrypoint.sh)'}

SCRIPTS_DIR="$(dirname "$0")"

# URL-encode UUIDs (curly braces must be encoded)
WORKSPACE_UUID_ENCODED=$(echo "$WORKSPACE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
REPO_UUID_ENCODED=$(echo "$REPO_UUID" | sed 's/{/%7B/g; s/}/%7D/g')

API_URL="https://api.bitbucket.org/internal/repositories/${WORKSPACE_UUID_ENCODED}/${REPO_UUID_ENCODED}/pipelines-config/runners"

echo "Registering runner: ${RUNNER_NAME}" >&2
echo "  Workspace: ${WORKSPACE_UUID}" >&2
echo "  Repository: ${REPO_UUID}" >&2
echo "  Labels: ${RUNNER_LABELS}" >&2

# Get authentication header
AUTH_HEADER=$("${SCRIPTS_DIR}/bitbucket-auth.sh")

# Convert comma-separated labels to JSON array
LABELS_JSON=$(echo "$RUNNER_LABELS" | jq -R 'split(",")')

RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X POST "${API_URL}" \
  -H "Authorization: ${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"${RUNNER_NAME}\", \"labels\": ${LABELS_JSON}}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

# Check HTTP status
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "Error registering runner (HTTP ${HTTP_CODE}):" >&2
  echo "$BODY" >&2
  exit 1
fi

# Check for error in response body
if echo "$BODY" | jq -e '.error' > /dev/null 2>&1; then
  echo "Error registering runner:" >&2
  echo "$BODY" | jq -r '.error.message // .error' >&2
  exit 1
fi

# Extract runner UUID to verify success
RUNNER_UUID=$(echo "$BODY" | jq -r '.uuid // empty')

if [ -z "$RUNNER_UUID" ]; then
  echo "Failed to get runner UUID from response:" >&2
  echo "$BODY" >&2
  exit 1
fi

echo "Runner registered successfully: ${RUNNER_UUID}" >&2

# Output full response as JSON for parsing by caller
echo "$BODY"
