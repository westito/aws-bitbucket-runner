#!/bin/bash
set -eo pipefail

# Poll Bitbucket Pipeline state until completion
# This script monitors a pipeline and exits when it completes.
#
# Required environment variables:
#   WORKSPACE_UUID - Bitbucket workspace UUID (with curly braces)
#   REPO_UUID - Bitbucket repository UUID (with curly braces)
#   PIPELINE_UUID - Pipeline UUID to monitor
#
# Authentication (OAuth Consumer OR App Password):
#   BITBUCKET_OAUTH_CLIENT_ID + BITBUCKET_OAUTH_CLIENT_SECRET
#   or BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD
#
# Optional:
#   BITBUCKET_POLL_INTERVAL - Interval between checks in seconds (default: 10)
#   RUNNER_CONTAINER_NAME - Docker container name to check if alive (docker runner)
#   RUNNER_PID - Process ID to check if alive (shell runner)
#   MULTI_STEP - If false (default), stop after first step completion. If true, wait for pipeline completion.
#
# Outputs:
#   PIPELINE_STATE - Final state (exported)
#   PIPELINE_RESULT - Final result (exported)
#   Exit code 0 if SUCCESSFUL or STOPPED, 1 otherwise

: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required'}
: ${REPO_UUID:?'REPO_UUID is required'}
: ${PIPELINE_UUID:?'PIPELINE_UUID is required'}

POLL_INTERVAL=${BITBUCKET_POLL_INTERVAL:-10}
MULTI_STEP=${MULTI_STEP:-false}
SCRIPTS_DIR="$(dirname "$0")"

echo "=========================================="
echo "Monitoring Pipeline State"
echo "=========================================="

# Get auth header for API calls
AUTH_HEADER=$("${SCRIPTS_DIR}/bitbucket-auth.sh")

# URL-encode UUIDs
WORKSPACE_UUID_ENCODED=$(echo "$WORKSPACE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
REPO_UUID_ENCODED=$(echo "$REPO_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
PIPELINE_UUID_ENCODED=$(echo "$PIPELINE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')

PIPELINE_STATE_URL="https://api.bitbucket.org/2.0/repositories/${WORKSPACE_UUID_ENCODED}/${REPO_UUID_ENCODED}/pipelines/${PIPELINE_UUID_ENCODED}"

export PIPELINE_STATE=""
export PIPELINE_RESULT=""
RUNNER_EXITED=false
RUNNER_FAILED=false

while true; do
  # If MULTI_STEP=false, check if runner completed steps by looking at log
  if [ "$MULTI_STEP" = "false" ]; then
    if [ -f /tmp/runner.log ]; then
      if grep -q "Completing step with result Result{status=" /tmp/runner.log 2>/dev/null; then
        if [ "$RUNNER_EXITED" = "false" ]; then
          STEP_COMPLETED=$(grep -c "Completing step with result Result{status=" /tmp/runner.log 2>/dev/null | tail -1)
          echo "Runner completed $STEP_COMPLETED step(s)"
          
          # Check if any step failed
          if grep -q "Completing step with result Result{status=FAILED" /tmp/runner.log 2>/dev/null; then
            echo "Runner step failed!"
            RUNNER_FAILED=true
          fi
          
          RUNNER_EXITED=true
        fi
      fi
    fi
    
    # Check if runner process is still alive (fallback)
    if [ "$RUNNER_EXITED" = "false" ]; then
      if [ -n "$RUNNER_CONTAINER_NAME" ]; then
        if ! docker ps -q -f name="${RUNNER_CONTAINER_NAME}" | grep -q .; then
          echo "Runner container exited"
          RUNNER_EXITED=true
        fi
      elif [ -n "$RUNNER_PID" ]; then
        if ! kill -0 $RUNNER_PID 2>/dev/null; then
          echo "Runner process exited"
          wait $RUNNER_PID 2>/dev/null || true
          RUNNER_EXITED=true
        fi
      fi
    fi
    
    # If runner completed, we're done - don't wait for other steps (e.g., deploy on cloud)
    if [ "$RUNNER_EXITED" = "true" ]; then
      echo "Runner finished, exiting without waiting for remaining steps"
      break
    fi
  fi
  
  # Query pipeline state
  PIPELINE_STATE_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: ${AUTH_HEADER}" "${PIPELINE_STATE_URL}")
  PIPELINE_STATE=$(echo "$PIPELINE_STATE_RESPONSE" | jq -r '.state.name // empty')
  PIPELINE_RESULT=$(echo "$PIPELINE_STATE_RESPONSE" | jq -r '.state.result.name // empty')
  PIPELINE_STAGE=$(echo "$PIPELINE_STATE_RESPONSE" | jq -r '.state.stage.name // empty')
  
  echo "  Pipeline state: ${PIPELINE_STATE} | stage: ${PIPELINE_STAGE} | result: ${PIPELINE_RESULT:-pending}"
  
  # Check if pipeline completed
  if [ "$PIPELINE_STATE" = "COMPLETED" ]; then
    break
  fi
  
  # Check for terminal states
  if [ "$PIPELINE_STATE" = "FAILED" ] || [ "$PIPELINE_STATE" = "ERROR" ] || [ "$PIPELINE_STATE" = "STOPPED" ]; then
    break
  fi
  
  sleep $POLL_INTERVAL
done

echo ""
echo "=========================================="
echo "Pipeline Monitoring Complete"
echo "=========================================="
echo "  State: ${PIPELINE_STATE}"
echo "  Result: ${PIPELINE_RESULT}"
echo "  Runner exited: ${RUNNER_EXITED}"
echo ""

# Exit with appropriate code
if [ "$RUNNER_FAILED" = "true" ]; then
  echo "Self-hosted runner step failed"
  exit 1
elif [ "$RUNNER_EXITED" = "true" ]; then
  echo "Self-hosted runner completed successfully"
  exit 0
elif [ "$PIPELINE_RESULT" = "SUCCESSFUL" ] || [ "$PIPELINE_STATE" = "STOPPED" ]; then
  exit 0
else
  exit 1
fi
