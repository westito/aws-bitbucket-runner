#!/bin/bash
set -eo pipefail

# start-runner - Start AWS CodeBuild runner from Bitbucket Pipeline
#
# Triggers AWS CodeBuild via OIDC and waits for runner to be ready.
#
# Usage:
#   start-runner [OPTIONS]
#   start-runner --project my-project --region eu-central-1
#
# Options (or use environment variables):
#   -p, --project         CodeBuild project name (CODEBUILD_PROJECT)
#   -r, --region          AWS region (CODEBUILD_REGION)
#   --role                IAM role ARN (AWS_ROLE_ARN)
#   --timeout             Build timeout in minutes (CODEBUILD_TIMEOUT)
#   --queued-timeout      Queued timeout in minutes (CODEBUILD_QUEUED_TIMEOUT)
#   --compute-type        Compute type override (CODEBUILD_COMPUTE_TYPE)
#   --image               Build image override (CODEBUILD_IMAGE)

#   CODEBUILD_ENV_*       Extra env vars forwarded as * (e.g., CODEBUILD_ENV_FOO becomes FOO)
#   --startup-timeout     Max wait time for runner startup in seconds (default: 600)
#   --containerd          Enable Docker containerd snapshotter (DOCKER_CONTAINERD=true)
#   --custom-buildspec    Use CodeBuild project's buildspec (CUSTOM_BUILDSPEC=true)
#   --label               Custom runner label (RUNNER_LABEL) - added to default labels
#   --multi-step          Wait for full pipeline completion (MULTI_STEP=true)
#   -h, --help            Show this help
#
# Authentication (one of the following):
#   Option 1 - OAuth from pipeline (forwarded to CodeBuild):
#     BITBUCKET_OAUTH_CLIENT_ID + BITBUCKET_OAUTH_CLIENT_SECRET
#   Option 2 - OAuth stored in CodeBuild project environment variables
#
# Required Bitbucket variables (auto-provided by Bitbucket Pipelines):
#   BITBUCKET_STEP_OIDC_TOKEN - OIDC token (when oidc: true)
#   BITBUCKET_PIPELINE_UUID - Pipeline UUID
#   BITBUCKET_REPO_UUID - Repository UUID
#   BITBUCKET_REPO_OWNER_UUID - Workspace UUID (for YAML templating)
#   BITBUCKET_BRANCH - Branch name (on branch builds)
#   BITBUCKET_BUILD_NUMBER - Build number
#
# Note: WORKSPACE_UUID must be provided via pipeline variables if BITBUCKET_REPO_OWNER_UUID
# is not available in your Bitbucket plan.

# RUNNER_TYPE is set at Docker build time (docker or shell)
: ${RUNNER_TYPE:?'RUNNER_TYPE is required (docker or shell)'}

STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-600}
# RUNNER_VERSION is set at Docker build time from VERSION file

show_help() {
  sed -n '3,27p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 0
}

# Default buildspec that downloads runner from GitHub releases
generate_buildspec() {
  cat <<EOF
version: 0.2
phases:
  install:
    commands:
      - curl -sL --connect-timeout 30 --max-time 60 "https://github.com/westito/aws-bitbucket-runner/releases/latest/download/install-${RUNNER_TYPE}.sh" | sh
  pre_build:
    commands:
      - /runner/pre_build.sh
  build:
    commands:
      - /runner/build.sh
  post_build:
    commands:
      - /runner/post_build.sh
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -p|--project) CODEBUILD_PROJECT="$2"; shift 2 ;;
    -r|--region) CODEBUILD_REGION="$2"; shift 2 ;;
    --role) AWS_ROLE_ARN="$2"; shift 2 ;;
    --timeout) CODEBUILD_TIMEOUT="$2"; shift 2 ;;
    --queued-timeout) CODEBUILD_QUEUED_TIMEOUT="$2"; shift 2 ;;
    --compute-type) CODEBUILD_COMPUTE_TYPE="$2"; shift 2 ;;
    --image) CODEBUILD_IMAGE="$2"; shift 2 ;;
    --startup-timeout) STARTUP_TIMEOUT="$2"; shift 2 ;;
    --containerd) DOCKER_CONTAINERD="true"; shift ;;
    --custom-buildspec) CUSTOM_BUILDSPEC="true"; shift ;;
    --label) RUNNER_LABEL="$2"; shift 2 ;;
    --multi-step) MULTI_STEP="true"; shift ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
done

# Validate required variables
: ${BITBUCKET_STEP_OIDC_TOKEN:?'BITBUCKET_STEP_OIDC_TOKEN is required (set oidc: true)'}
: ${AWS_ROLE_ARN:?'AWS_ROLE_ARN is required (--role or AWS_ROLE_ARN)'}
: ${CODEBUILD_REGION:?'CODEBUILD_REGION is required (--region or CODEBUILD_REGION)'}
: ${CODEBUILD_PROJECT:?'CODEBUILD_PROJECT is required (--project or CODEBUILD_PROJECT)'}
: ${BITBUCKET_PIPELINE_UUID:?'BITBUCKET_PIPELINE_UUID is required (auto-provided by Bitbucket)'}
: ${BITBUCKET_REPO_UUID:?'BITBUCKET_REPO_UUID is required (auto-provided by Bitbucket)'}

# WORKSPACE_UUID: try BITBUCKET_REPO_OWNER_UUID first, fall back to WORKSPACE_UUID variable
WORKSPACE_UUID="${BITBUCKET_REPO_OWNER_UUID:-${WORKSPACE_UUID:-}}"
: ${WORKSPACE_UUID:?'WORKSPACE_UUID is required (set BITBUCKET_REPO_OWNER_UUID or WORKSPACE_UUID in pipeline variables)'}

# Use BITBUCKET_BRANCH if available, otherwise use BITBUCKET_TAG or default
SOURCE_VERSION="${BITBUCKET_BRANCH:-${BITBUCKET_TAG:-main}}"

echo "=========================================="
echo "Starting CodeBuild Runner (${RUNNER_TYPE})"
echo "=========================================="
echo "Project: ${CODEBUILD_PROJECT}"
echo "Source: ${SOURCE_VERSION}"
echo "Region: ${CODEBUILD_REGION}"
echo "Workspace UUID: ${WORKSPACE_UUID}"
echo "Repo UUID: ${BITBUCKET_REPO_UUID}"
echo "Pipeline UUID: ${BITBUCKET_PIPELINE_UUID}"
echo "Runner version: ${RUNNER_VERSION}"
echo "Startup timeout: ${STARTUP_TIMEOUT}s"
[ -n "$CODEBUILD_TIMEOUT" ] && echo "Build timeout: ${CODEBUILD_TIMEOUT} min"
[ -n "$CODEBUILD_COMPUTE_TYPE" ] && echo "Compute: ${CODEBUILD_COMPUTE_TYPE}"
echo "=========================================="

# Configure OIDC authentication (restrict permissions)
umask 077
echo "${BITBUCKET_STEP_OIDC_TOKEN}" > /tmp/web-identity-token
export AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/web-identity-token
export AWS_ROLE_SESSION_NAME="bitbucket-${BITBUCKET_BUILD_NUMBER:-0}"

# Strip curly braces from UUIDs for safe forwarding
WORKSPACE_UUID_CLEAN=$(echo "$WORKSPACE_UUID" | tr -d '{}')
REPO_UUID_CLEAN=$(echo "$BITBUCKET_REPO_UUID" | tr -d '{}')
PIPELINE_UUID_CLEAN=$(echo "$BITBUCKET_PIPELINE_UUID" | tr -d '{}')

# Build CLI input JSON file (safest way to pass complex data to AWS CLI)
umask 077
CLI_INPUT_FILE="/tmp/start-build-input.json"

# Build environment variables array using jq for proper JSON construction
ENV_VARS=$(jq -n \
  --arg workspace "$WORKSPACE_UUID_CLEAN" \
  --arg repo "$REPO_UUID_CLEAN" \
  --arg pipeline "$PIPELINE_UUID_CLEAN" \
  --arg branch "${BITBUCKET_BRANCH:-}" \
  --arg tag "${BITBUCKET_TAG:-}" \
  --arg commit "${BITBUCKET_COMMIT:-}" \
  --arg oauth_id "${BITBUCKET_OAUTH_CLIENT_ID:-}" \
  --arg oauth_secret "${BITBUCKET_OAUTH_CLIENT_SECRET:-}" \
  --arg containerd "${DOCKER_CONTAINERD:-false}" \
  --arg custom_label "${RUNNER_LABEL:-}" \
  --arg multi_step "${MULTI_STEP:-false}" \
  '[
    {name: "WORKSPACE_UUID", value: $workspace, type: "PLAINTEXT"},
    {name: "REPO_UUID", value: $repo, type: "PLAINTEXT"},
    {name: "PIPELINE_UUID", value: $pipeline, type: "PLAINTEXT"}
  ] + (if $branch != "" then [{name: "BITBUCKET_BRANCH", value: $branch, type: "PLAINTEXT"}] else [] end)
    + (if $tag != "" then [{name: "BITBUCKET_TAG", value: $tag, type: "PLAINTEXT"}] else [] end)
    + (if $commit != "" then [{name: "BITBUCKET_COMMIT", value: $commit, type: "PLAINTEXT"}] else [] end)
    + (if $oauth_id != "" and $oauth_secret != "" then [
        {name: "BITBUCKET_OAUTH_CLIENT_ID", value: $oauth_id, type: "PLAINTEXT"},
        {name: "BITBUCKET_OAUTH_CLIENT_SECRET", value: $oauth_secret, type: "PLAINTEXT"}
      ] else [] end)
    + (if $containerd == "true" then [{name: "DOCKER_CONTAINERD", value: "true", type: "PLAINTEXT"}] else [] end)
    + (if $custom_label != "" then [{name: "RUNNER_LABEL", value: $custom_label, type: "PLAINTEXT"}] else [] end)
    + (if $multi_step == "true" then [{name: "MULTI_STEP", value: "true", type: "PLAINTEXT"}] else [] end)
  ')

# Log OAuth forwarding if credentials provided
if [ -n "$BITBUCKET_OAUTH_CLIENT_ID" ] && [ -n "$BITBUCKET_OAUTH_CLIENT_SECRET" ]; then
  echo "Forwarding OAuth credentials to CodeBuild"
fi

# Reserved variable names (Bitbucket defaults + internal)
RESERVED_VARS="WORKSPACE_UUID REPO_UUID PIPELINE_UUID BITBUCKET_BRANCH BITBUCKET_TAG BITBUCKET_COMMIT BITBUCKET_PIPELINE_UUID BITBUCKET_REPO_UUID BITBUCKET_REPO_OWNER_UUID BITBUCKET_BUILD_NUMBER BITBUCKET_STEP_OIDC_TOKEN BITBUCKET_OAUTH_CLIENT_ID BITBUCKET_OAUTH_CLIENT_SECRET"

# Auto-forward CODEBUILD_ENV_* variables (strip prefix)
while IFS='=' read -r name value; do
  if [[ "$name" == CODEBUILD_ENV_* ]]; then
    VAR_NAME="${name#CODEBUILD_ENV_}"
    # Check if variable name is reserved
    if echo "$RESERVED_VARS" | grep -qw "$VAR_NAME"; then
      echo "ERROR: Cannot override reserved variable: $VAR_NAME (via $name)"
      exit 1
    fi
    echo "Forwarding: $name -> $VAR_NAME"
    # Add to ENV_VARS using jq for safe JSON escaping
    ENV_VARS=$(echo "$ENV_VARS" | jq --arg n "$VAR_NAME" --arg v "$value" '. + [{name: $n, value: $v, type: "PLAINTEXT"}]')
  fi
done < <(env)

# Build the complete CLI input JSON using jq
jq -n \
  --arg project "$CODEBUILD_PROJECT" \
  --arg source "$SOURCE_VERSION" \
  --argjson envVars "$ENV_VARS" \
  '{
    projectName: $project,
    sourceVersion: $source,
    environmentVariablesOverride: $envVars
  }' > "$CLI_INPUT_FILE"

# Add buildspec override unless custom buildspec is used
if [ "${CUSTOM_BUILDSPEC:-false}" != "true" ]; then
  BUILDSPEC_CONTENT=$(generate_buildspec)
  jq --arg bs "$BUILDSPEC_CONTENT" '. + {buildspecOverride: $bs}' "$CLI_INPUT_FILE" > "${CLI_INPUT_FILE}.tmp"
  mv "${CLI_INPUT_FILE}.tmp" "$CLI_INPUT_FILE"
fi

# Add optional overrides
if [ -n "$CODEBUILD_TIMEOUT" ]; then
  jq --argjson t "$CODEBUILD_TIMEOUT" '. + {timeoutInMinutesOverride: $t}' "$CLI_INPUT_FILE" > "${CLI_INPUT_FILE}.tmp"
  mv "${CLI_INPUT_FILE}.tmp" "$CLI_INPUT_FILE"
fi
if [ -n "$CODEBUILD_QUEUED_TIMEOUT" ]; then
  jq --argjson t "$CODEBUILD_QUEUED_TIMEOUT" '. + {queuedTimeoutInMinutesOverride: $t}' "$CLI_INPUT_FILE" > "${CLI_INPUT_FILE}.tmp"
  mv "${CLI_INPUT_FILE}.tmp" "$CLI_INPUT_FILE"
fi
if [ -n "$CODEBUILD_COMPUTE_TYPE" ]; then
  jq --arg t "$CODEBUILD_COMPUTE_TYPE" '. + {computeTypeOverride: $t}' "$CLI_INPUT_FILE" > "${CLI_INPUT_FILE}.tmp"
  mv "${CLI_INPUT_FILE}.tmp" "$CLI_INPUT_FILE"
fi
if [ -n "$CODEBUILD_IMAGE" ]; then
  jq --arg t "$CODEBUILD_IMAGE" '. + {imageOverride: $t}' "$CLI_INPUT_FILE" > "${CLI_INPUT_FILE}.tmp"
  mv "${CLI_INPUT_FILE}.tmp" "$CLI_INPUT_FILE"
fi

# Start CodeBuild using --cli-input-json (with retry for concurrency limit)
echo "Starting CodeBuild..."
MAX_RETRIES=60
RETRY_INTERVAL=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  START_OUTPUT=$(aws codebuild start-build \
    --cli-input-json "file://${CLI_INPUT_FILE}" \
    --region "${CODEBUILD_REGION}" \
    --output json 2>&1) && break
  
  # Check if it's a concurrency limit error
  if echo "$START_OUTPUT" | grep -q "AccountLimitExceededException\|Concurrent build limit exceeded"; then
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "  Build queued (attempt ${RETRY_COUNT}/${MAX_RETRIES}) - waiting ${RETRY_INTERVAL}s..."
    sleep $RETRY_INTERVAL
  else
    echo "ERROR: Failed to start CodeBuild:"
    echo "$START_OUTPUT"
    exit 1
  fi
done

if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
  echo "ERROR: Timeout waiting for available build slot after ${MAX_RETRIES} attempts"
  exit 1
fi

BUILD_ID=$(echo "$START_OUTPUT" | jq -r '.build.id')

# Validate BUILD_ID
if [ -z "$BUILD_ID" ] || [ "$BUILD_ID" = "None" ] || [ "$BUILD_ID" = "null" ]; then
  echo "ERROR: Failed to start CodeBuild - no build ID returned"
  echo "$START_OUTPUT"
  exit 1
fi

echo "CodeBuild started: ${BUILD_ID}"

# Wait for CodeBuild to reach BUILD phase (runner is ONLINE)
echo "Waiting for runner to be ready..."
ELAPSED=0
POLL_INTERVAL=5

while [ $ELAPSED -lt $STARTUP_TIMEOUT ]; do
  BUILD_STATUS=$(aws codebuild batch-get-builds \
    --ids ${BUILD_ID} \
    --region ${CODEBUILD_REGION} \
    --query 'builds[0].currentPhase' \
    --output text)
  
  echo "  CodeBuild phase: ${BUILD_STATUS} (${ELAPSED}s)"
  
  if [ "$BUILD_STATUS" = "BUILD" ]; then
    echo "Runner is ready!"
    break
  fi
  
  if [ "$BUILD_STATUS" = "COMPLETED" ] || [ "$BUILD_STATUS" = "FAILED" ]; then
    echo "CodeBuild ended unexpectedly: ${BUILD_STATUS}"
    exit 1
  fi
  
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ $ELAPSED -ge $STARTUP_TIMEOUT ]; then
  echo "Timeout waiting for runner to start (${STARTUP_TIMEOUT}s)"
  exit 1
fi

echo "=========================================="
echo "Runner started successfully"
echo "=========================================="
