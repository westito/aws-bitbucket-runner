#!/bin/bash
set -eo pipefail

# Bitbucket-Invoker Mode: CodeBuild Entrypoint
#
# This mode is triggered by Bitbucket Pipeline via OIDC.
# The Bitbucket pipeline starts CodeBuild, which:
# 1. PRE_BUILD: Registers and starts the Bitbucket runner
# 2. PRE_BUILD: Waits until runner is ONLINE (so Bitbucket step 2 can pick it up)
# 3. BUILD: Polls the invoking pipeline until BUILD step completes
# 4. POST_BUILD: Unregisters the runner
#
# Flow: Bitbucket Pipeline Step 1 -> OIDC -> AWS CodeBuild -> Runner ONLINE
#       Bitbucket Pipeline Step 2 -> Runs on self-hosted runner
#       CodeBuild waits for pipeline completion -> Cleanup
#
# This script is called by buildspec with different phases:
#   ./codebuild-entrypoint.sh pre_build
#   ./codebuild-entrypoint.sh build
#   ./codebuild-entrypoint.sh post_build
#
# Required environment variables (forwarded from Bitbucket via start-runner.sh):
#   WORKSPACE_UUID - Bitbucket workspace UUID (BITBUCKET_REPO_OWNER_UUID)
#   REPO_UUID - Bitbucket repository UUID (BITBUCKET_REPO_UUID)
#   PIPELINE_UUID - The invoking Bitbucket pipeline UUID (BITBUCKET_PIPELINE_UUID)
#
# Authentication:
#   BITBUCKET_OAUTH_CLIENT_ID - OAuth Consumer Key (from Parameter Store or pipeline)
#   BITBUCKET_OAUTH_CLIENT_SECRET - OAuth Consumer Secret (from Parameter Store or pipeline)

: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required (forwarded from BITBUCKET_REPO_OWNER_UUID)'}
: ${REPO_UUID:?'REPO_UUID is required (forwarded from BITBUCKET_REPO_UUID)'}
: ${PIPELINE_UUID:?'PIPELINE_UUID is required (forwarded from BITBUCKET_PIPELINE_UUID)'}

# Ensure UUIDs have curly braces (Bitbucket API requires them)
[[ ! "$WORKSPACE_UUID" =~ ^\{ ]] && WORKSPACE_UUID="{${WORKSPACE_UUID}}"
[[ ! "$REPO_UUID" =~ ^\{ ]] && REPO_UUID="{${REPO_UUID}}"
[[ ! "$PIPELINE_UUID" =~ ^\{ ]] && PIPELINE_UUID="{${PIPELINE_UUID}}"

PHASE="${1:-build}"
SCRIPTS_DIR="/runner/scripts"
STATE_FILE="/tmp/runner-state.json"

# Shell runner label (add custom label if provided)
if [ -n "${RUNNER_LABEL:-}" ]; then
  RUNNER_LABELS="linux.shell,codebuild,${RUNNER_LABEL}"
else
  RUNNER_LABELS="linux.shell,codebuild"
fi

# Generate unique runner name
BUILD_ID_SAFE=$(echo "${CODEBUILD_BUILD_ID:-$(date +%s)}" | tr ':' '-' | tr '/' '-')
RUNNER_NAME="bb-${BUILD_ID_SAFE}"
RUNNER_NAME="${RUNNER_NAME:0:50}"

echo "=========================================="
echo "Bitbucket-Invoker Mode: Phase ${PHASE}"
echo "=========================================="
echo "Runner name: ${RUNNER_NAME}"
echo "Workspace: ${WORKSPACE_UUID}"
echo "Repository: ${REPO_UUID}"
echo "Pipeline UUID: ${PIPELINE_UUID:-not-set}"
echo "Labels: ${RUNNER_LABELS}"
echo ""

case "$PHASE" in
  pre_build)
    # PRE_BUILD: Register runner, start it, wait for ONLINE
    echo "=========================================="
    echo "PRE_BUILD: Starting Runner"
    echo "=========================================="
    
    # Configure Docker with containerd snapshotter (default: disabled)
    # This enables buildx cache export/import to registries like ECR
    if [ "${DOCKER_CONTAINERD:-false}" = "true" ]; then
      echo "Configuring Docker with containerd snapshotter..."
      mkdir -p /etc/docker
      echo '{"features":{"containerd-snapshotter":true}}' > /etc/docker/daemon.json
      
      # Restart Docker daemon with new config
      echo "Restarting Docker daemon..."
      if [ -f /var/run/docker.pid ]; then
        kill $(cat /var/run/docker.pid) 2>/dev/null || true
        rm -f /var/run/docker.pid
      fi
      nohup /usr/local/bin/dockerd --host=unix:///var/run/docker.sock --host=tcp://127.0.0.1:2375 --storage-driver=overlayfs &
      timeout 30 sh -c "until docker info >/dev/null 2>&1; do echo 'Waiting for Docker...'; sleep 1; done"
      echo "Docker daemon ready with containerd snapshotter"
    fi
    
    # Cleanup existing runners with matching labels
    "${SCRIPTS_DIR}/cleanup-runners.sh"
    
    # Register runner
    echo ""
    echo "Registering runner..."
    REGISTER_RESPONSE=$(RUNNER_NAME="$RUNNER_NAME" \
      RUNNER_LABELS="$RUNNER_LABELS" \
      "${SCRIPTS_DIR}/register-runner.sh")
    
    # Parse registration response
    RUNNER_UUID=$(echo "$REGISTER_RESPONSE" | jq -r '.uuid')
    RUNNER_OAUTH_CLIENT_ID=$(echo "$REGISTER_RESPONSE" | jq -r '.oauth_client.id // .oauth_client_id // empty')
    RUNNER_OAUTH_CLIENT_SECRET=$(echo "$REGISTER_RESPONSE" | jq -r '.oauth_client.secret // .oauth_client_secret // empty')
    
    if [ -z "$RUNNER_UUID" ] || [ "$RUNNER_UUID" = "null" ]; then
      echo "Failed to register runner - no UUID returned"
      exit 1
    fi
    
    if [ -z "$RUNNER_OAUTH_CLIENT_ID" ] || [ -z "$RUNNER_OAUTH_CLIENT_SECRET" ]; then
      echo "Failed to get OAuth credentials from registration response"
      exit 1
    fi
    
    echo "Runner registered: ${RUNNER_UUID}"
    
    # Save state for later phases
    echo "{\"runner_uuid\": \"${RUNNER_UUID}\", \"oauth_client_id\": \"${RUNNER_OAUTH_CLIENT_ID}\", \"oauth_client_secret\": \"${RUNNER_OAUTH_CLIENT_SECRET}\"}" > "$STATE_FILE"
    
    # Start runner process
    export RUNNER_UUID
    export RUNNER_OAUTH_CLIENT_ID
    export RUNNER_OAUTH_CLIENT_SECRET
    
    WORK_DIR="/tmp/runner-work"
    mkdir -p "$WORK_DIR"
    
    cd /runner/bin
    export JAVA_OPTS="-Dlogback.configurationFile=/runner/scripts/logback-console.xml"
    nohup ./start.sh \
      --accountUuid "${WORKSPACE_UUID}" \
      --repositoryUuid "${REPO_UUID}" \
      --runnerUuid "${RUNNER_UUID}" \
      --OAuthClientId "${RUNNER_OAUTH_CLIENT_ID}" \
      --OAuthClientSecret "${RUNNER_OAUTH_CLIENT_SECRET}" \
      --runtime linux-shell \
      --workingDirectory "${WORK_DIR}" 2>&1 | tee /tmp/runner.log &
    
    RUNNER_PID=$!
    echo "$RUNNER_PID" > /tmp/runner.pid
    echo "Runner started with PID: ${RUNNER_PID}"
    
    # Wait for runner to become ONLINE
    export RUNNER_PID
    "${SCRIPTS_DIR}/wait-runner-online.sh"
    
    echo ""
    echo "PRE_BUILD complete - runner is ONLINE"
    echo "Bitbucket pipeline step 2 can now use self-hosted runner"
    ;;
    
  build)
    # BUILD: Poll pipeline state until completion
    echo "=========================================="
    echo "BUILD: Waiting for Pipeline Completion"
    echo "=========================================="
    
    if [ ! -f "$STATE_FILE" ]; then
      echo "Error: State file not found. PRE_BUILD must run first."
      exit 1
    fi
    
    # Read runner PID if exists
    if [ -f /tmp/runner.pid ]; then
      export RUNNER_PID=$(cat /tmp/runner.pid)
    fi
    
    # If PIPELINE_UUID is not set, we need to find the current pipeline
    if [ -z "$PIPELINE_UUID" ]; then
      echo "PIPELINE_UUID not set - attempting to find invoking pipeline..."
      
      AUTH_HEADER=$("${SCRIPTS_DIR}/bitbucket-auth.sh")
      WORKSPACE_UUID_ENCODED=$(echo "$WORKSPACE_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
      REPO_UUID_ENCODED=$(echo "$REPO_UUID" | sed 's/{/%7B/g; s/}/%7D/g')
      
      # Get recent pipelines and find one in BUILDING state
      PIPELINES_URL="https://api.bitbucket.org/2.0/repositories/${WORKSPACE_UUID_ENCODED}/${REPO_UUID_ENCODED}/pipelines/?sort=-created_on&pagelen=5"
      PIPELINES_RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -H "Authorization: ${AUTH_HEADER}" "${PIPELINES_URL}")
      
      # Find pipeline in BUILDING state (the one that invoked us)
      export PIPELINE_UUID=$(echo "$PIPELINES_RESPONSE" | jq -r '.values[] | select(.state.name == "IN_PROGRESS" or .state.name == "PENDING") | .uuid' | head -n1)
      
      if [ -z "$PIPELINE_UUID" ]; then
        echo "Could not find invoking pipeline"
        echo "Pipelines response:"
        echo "$PIPELINES_RESPONSE" | jq '.values[] | {uuid, state: .state.name}'
        exit 1
      fi
      
      echo "Found invoking pipeline: ${PIPELINE_UUID}"
    fi
    
    export PIPELINE_UUID
    "${SCRIPTS_DIR}/poll-pipeline.sh"
    ;;
    
  post_build)
    # POST_BUILD: Cleanup - stop runner and unregister
    echo "=========================================="
    echo "POST_BUILD: Cleanup"
    echo "=========================================="
    
    # Stop runner process
    if [ -f /tmp/runner.pid ]; then
      RUNNER_PID=$(cat /tmp/runner.pid)
      if kill -0 $RUNNER_PID 2>/dev/null; then
        echo "Stopping runner process (PID: ${RUNNER_PID})..."
        kill $RUNNER_PID 2>/dev/null || true
        wait $RUNNER_PID 2>/dev/null || true
      fi
    fi
    
    # Unregister runner
    if [ -f "$STATE_FILE" ]; then
      export RUNNER_UUID=$(jq -r '.runner_uuid' "$STATE_FILE")
      if [ -n "$RUNNER_UUID" ] && [ "$RUNNER_UUID" != "null" ]; then
        echo "Unregistering runner: ${RUNNER_UUID}"
        "${SCRIPTS_DIR}/unregister-runner.sh" || true
      fi
    else
      echo "No state file found - skipping unregister"
    fi
    
    echo "POST_BUILD complete"
    ;;
    
  *)
    echo "Unknown phase: $PHASE"
    echo "Usage: $0 [pre_build|build|post_build]"
    exit 1
    ;;
esac
