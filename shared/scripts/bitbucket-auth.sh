#!/bin/bash
set -eo pipefail

# Get Bitbucket API authentication header
# 
# Authentication priority:
#   1. OAuth Consumer credentials (BITBUCKET_OAUTH_CLIENT_ID + BITBUCKET_OAUTH_CLIENT_SECRET)
#      - Can be forwarded from pipeline or stored in CodeBuild env vars
#   2. App Password (BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD)
#
# Output:
#   Prints the authentication header value to stdout
#   For OAuth: "Bearer <access_token>"
#   For App Password: "Basic <base64_encoded_credentials>"
#   For Token: "Bearer <token>"

OAUTH_TOKEN_URL="https://bitbucket.org/site/oauth2/access_token"

# Option 1: OAuth Client Credentials flow (recommended)
if [ -n "$BITBUCKET_OAUTH_CLIENT_ID" ] && [ -n "$BITBUCKET_OAUTH_CLIENT_SECRET" ]; then
  echo "Using OAuth Client Credentials authentication" >&2
  
  RESPONSE=$(curl -s --connect-timeout 10 --max-time 30 -X POST "$OAUTH_TOKEN_URL" \
    -u "${BITBUCKET_OAUTH_CLIENT_ID}:${BITBUCKET_OAUTH_CLIENT_SECRET}" \
    -d "grant_type=client_credentials")
  
  # Check for errors
  if echo "$RESPONSE" | jq -e '.error' > /dev/null 2>&1; then
    echo "OAuth token error:" >&2
    echo "$RESPONSE" | jq -r '.error_description // .error' >&2
    exit 1
  fi
  
  ACCESS_TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')
  
  if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
    echo "Failed to get access token from response:" >&2
    echo "$RESPONSE" >&2
    exit 1
  fi
  
  EXPIRES_IN=$(echo "$RESPONSE" | jq -r '.expires_in // "unknown"')
  echo "Token obtained, expires in ${EXPIRES_IN}s" >&2
  
  echo "Bearer ${ACCESS_TOKEN}"

# Option 2: Basic Auth with App Password
elif [ -n "$BITBUCKET_USERNAME" ] && [ -n "$BITBUCKET_APP_PASSWORD" ]; then
  echo "Using App Password authentication" >&2
  
  BASIC_AUTH=$(echo -n "${BITBUCKET_USERNAME}:${BITBUCKET_APP_PASSWORD}" | base64)
  
  echo "Basic ${BASIC_AUTH}"

else
  echo "============================================" >&2
  echo "ERROR: No Bitbucket authentication provided" >&2
  echo "============================================" >&2
  echo "" >&2
  echo "Provide one of the following:" >&2
  echo "" >&2
  echo "Option 1 - OAuth Consumer (recommended):" >&2
  echo "  Set in bitbucket-pipelines.yml variables:" >&2
  echo "    BITBUCKET_OAUTH_CLIENT_ID: \$BITBUCKET_OAUTH_CLIENT_ID" >&2
  echo "    BITBUCKET_OAUTH_CLIENT_SECRET: \$BITBUCKET_OAUTH_CLIENT_SECRET" >&2
  echo "  Or store in CodeBuild project environment variables" >&2
  echo "" >&2
  echo "Option 2 - App Password:" >&2
  echo "  BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD" >&2
  echo "" >&2
  exit 1
fi
