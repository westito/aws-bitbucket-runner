#!/bin/bash
set -eo pipefail
exec /runner/scripts/codebuild-entrypoint.sh pre_build
