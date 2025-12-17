#!/bin/bash
set -eo pipefail

# install-{{RUNNER_TYPE}}.sh - Install aws-bitbucket-runner ({{RUNNER_TYPE}}) to CodeBuild
#
# Usage:
#   curl -sL https://github.com/westito/aws-bitbucket-runner/releases/latest/download/install-{{RUNNER_TYPE}}.sh | sh
#
# Options:
#   --dest DIR        Installation directory (default: /runner)
#   -h, --help        Show this help

RUNNER_TYPE="{{RUNNER_TYPE}}"
VERSION="{{VERSION}}"
INSTALL_DIR="${INSTALL_DIR:-/runner}"
GITHUB_REPO="westito/aws-bitbucket-runner"

show_help() {
  sed -n '3,10p' "$0" | sed 's/^# //' | sed 's/^#//'
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dest) INSTALL_DIR="$2"; shift 2 ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
done

DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/latest/download/runner-${RUNNER_TYPE}.zip"

echo "=========================================="
echo "Installing aws-bitbucket-runner"
echo "=========================================="
echo "Type: ${RUNNER_TYPE}"
echo "Version: ${VERSION}"
echo "Destination: ${INSTALL_DIR}"
echo "=========================================="

# Check required tools
for cmd in curl unzip; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: Required tool not found: $cmd"
    exit 1
  fi
done

# Create temp directory
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Download runner bundle
echo "Downloading runner bundle..."
if ! curl -sL --connect-timeout 30 --max-time 300 -o "${TMP_DIR}/runner.zip" "$DOWNLOAD_URL"; then
  echo "ERROR: Failed to download runner bundle"
  echo "URL: ${DOWNLOAD_URL}"
  exit 1
fi

# Verify download
if [ ! -s "${TMP_DIR}/runner.zip" ]; then
  echo "ERROR: Downloaded file is empty"
  exit 1
fi

# Extract bundle
echo "Extracting runner bundle..."
if ! unzip -q "${TMP_DIR}/runner.zip" -d "${TMP_DIR}"; then
  echo "ERROR: Failed to extract runner bundle"
  exit 1
fi

# Create destination directory
echo "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"

# Copy files (runner.zip extracts to 'runner/' subdirectory)
if [ -d "${TMP_DIR}/runner" ]; then
  cp -r "${TMP_DIR}/runner/"* "${INSTALL_DIR}/"
else
  echo "ERROR: Unexpected bundle structure"
  ls -la "${TMP_DIR}"
  exit 1
fi

# Make scripts executable
chmod +x "${INSTALL_DIR}"/*.sh 2>/dev/null || true
chmod +x "${INSTALL_DIR}"/scripts/*.sh 2>/dev/null || true
if [ -d "${INSTALL_DIR}/bin" ]; then
  chmod +x "${INSTALL_DIR}/bin"/*.sh 2>/dev/null || true
fi

echo "=========================================="
echo "Installation complete!"
echo "=========================================="
