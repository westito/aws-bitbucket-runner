#!/bin/bash
set -eo pipefail

# Wait for Bitbucket runner to become ONLINE
# This script polls the Bitbucket API until the runner is ready.
#
# Required environment variables:
#   WORKSPACE_UUID - Bitbucket workspace UUID (with curly braces)
#   REPO_UUID - Bitbucket repository UUID (with curly braces)
#   RUNNER_UUID - Runner UUID to check
#
# Runner type detection (one required):
#   RUNNER_CONTAINER_NAME - Docker container name (for docker runner)
#   RUNNER_PID - Process ID (for shell runner)
#
# Authentication (OAuth Consumer OR App Password):
#   BITBUCKET_OAUTH_CLIENT_ID + BITBUCKET_OAUTH_CLIENT_SECRET
#   or BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD
#
# Optional:
#   MAX_WAIT - Max wait time in seconds (default: 60)

: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required'}
: ${REPO_UUID:?'REPO_UUID is required'}
: ${RUNNER_UUID:?'RUNNER_UUID is required'}

# Detect runner type based on which variable is set
if [ -n "$RUNNER_CONTAINER_NAME" ]; then
  RUNNER_TYPE="docker"
elif [ -n "$RUNNER_PID" ]; then
  RUNNER_TYPE="shell"
else
  echo "ERROR: Either RUNNER_CONTAINER_NAME or RUNNER_PID must be set"
  exit 1
fi

MAX_WAIT=${MAX_WAIT:-60}
SCRIPTS_DIR="$(dirname "$0")"

echo "Waiting for runner to become ONLINE (type: ${RUNNER_TYPE})..."

# Get auth header for API calls
AUTH_HEADER=$("${SCRIPTS_DIR}/bitbucket-auth.sh")

# URL-encode UUIDs
WORKSPACE_UUID_ENCODED=$(echo "$WORKSPACE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
REPO_UUID_ENCODED=$(echo "$REPO_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
RUNNER_UUID_ENCODED=$(echo "$RUNNER_UUID" | sed 's/{/%7B/g; s/}/%7D/g')

RUNNER_STATE_URL="https://api.bitbucket.org/internal/repositories/${WORKSPACE_UUID_ENCODED}/${REPO_UUID_ENCODED}/pipelines-config/runners/${RUNNER_UUID_ENCODED}"

WAITED=0
RUNNER_ONLINE=false

# Function to check if runner is alive based on type
check_runner_alive() {
  if [ "$RUNNER_TYPE" = "docker" ]; then
    docker ps -q -f name="${RUNNER_CONTAINER_NAME}" | grep -q .
  else
    kill -0 $RUNNER_PID 2>/dev/null
  fi
}

# Function to show runner logs/status on failure
show_runner_failure_info() {
  if [ "$RUNNER_TYPE" = "docker" ]; then
    echo "Container logs:"
    docker logs "${RUNNER_CONTAINER_NAME}" 2>&1 || true
  else
    echo "Runner process died unexpectedly"
  fi
}

while [ $WAITED -lt $MAX_WAIT ]; do
  # Check if runner is still alive
  if ! check_runner_alive; then
    echo "Runner died unexpectedly"
    show_runner_failure_info
    exit 1
  fi
  
  # Check runner state via API
  STATE_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: ${AUTH_HEADER}" "${RUNNER_STATE_URL}")
  RUNNER_STATE=$(echo "$STATE_RESPONSE" | jq -r '.state.status // empty')
  
  if [ "$RUNNER_STATE" = "ONLINE" ]; then
    echo "Runner is ONLINE!"
    RUNNER_ONLINE=true
    break
  fi
  
  echo "  Runner state: ${RUNNER_STATE:-unknown} (waiting...)"
  sleep 2
  WAITED=$((WAITED + 2))
done

if [ "$RUNNER_ONLINE" != "true" ]; then
  echo "Timeout waiting for runner to become ONLINE"
  show_runner_failure_info
  exit 1
fi
