#!/bin/bash
set -eo pipefail

# Cleanup existing runners for a repository with matching labels
# This prevents race conditions when starting new runners.
#
# Required environment variables:
#   WORKSPACE_UUID - Bitbucket workspace UUID (with curly braces)
#   REPO_UUID - Bitbucket repository UUID (with curly braces)
#   RUNNER_LABELS - Comma-separated labels to match (e.g., "linux.shell,codebuild,api")
#
# Authentication:
#   BITBUCKET_OAUTH_CLIENT_ID + BITBUCKET_OAUTH_CLIENT_SECRET
#   or BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD

: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required'}
: ${REPO_UUID:?'REPO_UUID is required'}
: ${RUNNER_LABELS:=''}

SCRIPTS_DIR="$(dirname "$0")"

echo "Cleaning up existing runners..."

# Get authentication header
AUTH_HEADER=$("${SCRIPTS_DIR}/bitbucket-auth.sh")

# URL-encode UUIDs
WORKSPACE_UUID_ENCODED=$(echo "$WORKSPACE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
REPO_UUID_ENCODED=$(echo "$REPO_UUID" | sed 's/{/%7B/g; s/}/%7D/g')

RUNNERS_URL="https://api.bitbucket.org/internal/repositories/${WORKSPACE_UUID_ENCODED}/${REPO_UUID_ENCODED}/pipelines-config/runners"
EXISTING_RUNNERS_JSON=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: ${AUTH_HEADER}" "${RUNNERS_URL}")

# Check if response is valid JSON with values array
if ! echo "$EXISTING_RUNNERS_JSON" | jq -e '.values' > /dev/null 2>&1; then
  echo "  No runners found or API error, skipping cleanup"
  echo "  Response: $(echo "$EXISTING_RUNNERS_JSON" | head -c 200)"
  echo "Cleanup complete"
  exit 0
fi

# Convert our labels to sorted array for comparison
OUR_LABELS_SORTED=$(echo "$RUNNER_LABELS" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')

# Process each runner - only cleanup OFFLINE/UNREGISTERED runners with matching labels
# Valid states: UNREGISTERED, ONLINE, OFFLINE, DISABLED, ENABLED
echo "$EXISTING_RUNNERS_JSON" | jq -c '.values[]? | select(type == "object")' | while read -r runner; do
  if [ -n "$runner" ]; then
    OLD_RUNNER_UUID=$(echo "$runner" | jq -r '.uuid // empty')
    if [ -z "$OLD_RUNNER_UUID" ]; then
      continue
    fi
    
    # Get runner's labels sorted - check labels first to skip unrelated runners
    # Labels can be either strings or objects with .name property
    RUNNER_LABELS_SORTED=$(echo "$runner" | jq -r '[.labels[]? | if type == "string" then . elif type == "object" then .name // empty else empty end] | sort | join(",")')
    if [ "$RUNNER_LABELS_SORTED" != "$OUR_LABELS_SORTED" ]; then
      continue
    fi
    
    # Check runner state - only delete OFFLINE or UNREGISTERED runners
    RUNNER_STATE=$(echo "$runner" | jq -r '.state.status // "UNKNOWN"')
    if [ "$RUNNER_STATE" != "OFFLINE" ] && [ "$RUNNER_STATE" != "UNREGISTERED" ]; then
      echo "  Skipping runner: ${OLD_RUNNER_UUID} (state: ${RUNNER_STATE})"
      continue
    fi
    
    OLD_RUNNER_UUID_ENCODED=$(echo "$OLD_RUNNER_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
    echo "  Deleting runner: ${OLD_RUNNER_UUID} (state: ${RUNNER_STATE})"
    curl -s --connect-timeout 10 --max-time 30 -X DELETE -H "Authorization: ${AUTH_HEADER}" "${RUNNERS_URL}/${OLD_RUNNER_UUID_ENCODED}" || true
  fi
done

echo "Cleanup complete"
