# AGENTS.md - aws-bitbucket-runner

## Project Overview
Self-hosted Bitbucket Pipelines runner using AWS CodeBuild. Enables Bitbucket Pipelines to run on AWS infrastructure via OIDC authentication.

**Version**: See `VERSION` file (currently 1.0.0)

**Flow**: Bitbucket Step 1 -> OIDC -> AWS CodeBuild -> Self-hosted Runner -> Bitbucket Step 2+ runs on runner -> Cleanup

## Runner Types

| Type | Image | Description |
|------|-------|-------------|
| **Shell** (recommended) | `ghcr.io/westito/aws-bitbucket-runner-shell` | Runs binary directly, faster startup, full Docker access |
| **Docker** | `ghcr.io/westito/aws-bitbucket-runner-docker` | Runs Atlassian container, more isolation |

**Recommendation**: Use Shell runner for Docker builds (better Docker access), Docker runner for builds requiring specific image.

## Labels (Auto-detected)

| Architecture | Labels | Pipeline runs-on |
|--------------|--------|------------------|
| x86_64 | `linux,codebuild` | `[self.hosted, linux, codebuild]` |
| ARM64 | `linux.arm64,codebuild` | `[self.hosted, linux.arm64, codebuild]` |

## Folder Structure
```
aws-bitbucket-runner/
├── shared/                         # Common code shared between runners
│   ├── start-runner.sh             # Triggers CodeBuild, uses RUNNER_TYPE env var
│   └── scripts/
│       ├── bitbucket-auth.sh       # OAuth/App Password authentication
│       ├── cleanup-runners.sh      # Remove stale runners
│       ├── register-runner.sh      # Register runner with Bitbucket
│       ├── unregister-runner.sh    # Unregister runner
│       ├── wait-runner-online.sh   # Wait for runner to come online
│       └── poll-pipeline.sh        # Poll pipeline until completion
├── bitbucket-runner-docker/        # Docker image (ghcr.io/westito/aws-bitbucket-runner-docker)
│   └── Dockerfile                  # Sets RUNNER_TYPE=docker
├── bitbucket-runner-shell/         # Docker image (ghcr.io/westito/aws-bitbucket-runner-shell)
│   └── Dockerfile                  # Sets RUNNER_TYPE=shell
├── codebuild-runner-docker/        # Bundled as runner-docker.zip
│   ├── pre_build.sh, build.sh, post_build.sh
│   └── scripts/
│       └── codebuild-entrypoint.sh  # Runs Atlassian Docker container
├── codebuild-runner-shell/         # Bundled as runner-shell.zip
│   ├── pre_build.sh, build.sh, post_build.sh
│   └── scripts/
│       └── codebuild-entrypoint.sh  # Runs start.sh binary directly
├── .github/workflows/release.yml
├── VERSION, README.md, AGENTS.md
```

**Note**: The release workflow copies `shared/scripts/*` to both bundles, plus type-specific `codebuild-entrypoint.sh`.

## How It Works

```
Bitbucket Pipeline Step 1 (start-runner)
    │
    ├─ OIDC auth → Assume AWS IAM role
    ├─ Generate buildspec (downloads runner zip)
    ├─ Start CodeBuild
    └─ Wait for BUILD phase (runner ONLINE)
           │
           ▼
AWS CodeBuild
    │
    ├─ INSTALL: Download runner-{shell|docker}.zip from GitHub releases
    ├─ PRE_BUILD:
    │     ├─ Configure containerd (if enabled)
    │     ├─ Cleanup stale runners
    │     ├─ Register runner with Bitbucket API
    │     ├─ Shell: nohup ./start.sh --runtime linux-shell
    │     └─ Docker: docker run atlassian/bitbucket-pipelines-runner
    │
    ├─ BUILD: Poll pipeline until completion (runner serves Step 2+)
    │
    └─ POST_BUILD: Stop runner, unregister from Bitbucket
           │
           ▼
Bitbucket Pipeline Step 2+ (runs-on: self.hosted)
    └─ Executes on CodeBuild runner
```

## Configuration Options

| Option | Env Variable | CLI Flag | Description |
|--------|--------------|----------|-------------|
| Project | `CODEBUILD_PROJECT` | `-p, --project` | CodeBuild project name (required) |
| Region | `CODEBUILD_REGION` | `-r, --region` | AWS region (required) |
| IAM Role | `AWS_ROLE_ARN` | `--role` | IAM role for OIDC (required) |
| Timeout | `CODEBUILD_TIMEOUT` | `--timeout` | Build timeout (minutes) |
| Compute | `CODEBUILD_COMPUTE_TYPE` | `--compute-type` | Compute type override |
| Image | `CODEBUILD_IMAGE` | `--image` | Build image override |
| Containerd | `DOCKER_CONTAINERD=true` | `--containerd` | Enable containerd snapshotter |
| Custom buildspec | `CUSTOM_BUILDSPEC=true` | `--custom-buildspec` | Use project's buildspec |
| Custom vars | `CODEBUILD_ENV_*` | - | Forward to CodeBuild (prefix stripped) |

## Authentication

### AWS (OIDC)
- `BITBUCKET_STEP_OIDC_TOKEN` - Auto-provided by Bitbucket when `oidc: true`
- Assumes IAM role specified in `AWS_ROLE_ARN`

### Bitbucket API (OAuth Consumer)
Required permissions: Repositories (Read), Webhooks (Read/Write), Pipelines (Read/Write/Edit), Runners (Read/Write)

Pass via pipeline or store in CodeBuild project env vars (from AWS Parameter Store):
- `BITBUCKET_OAUTH_CLIENT_ID`
- `BITBUCKET_OAUTH_CLIENT_SECRET`

## CodeBuild Project Requirements

- **Image**: Docker support + required tools
  - ARM: `aws/codebuild/amazonlinux-aarch64-standard:3.0`
  - x86_64: `aws/codebuild/amazonlinux-x86_64-standard:5.0`
- **Privileged mode**: Required (for Docker)
- **Source**: `NO_SOURCE` (scripts downloaded from GitHub releases)
- **Required tools** (included in recommended images):
  - `jq` - JSON processing
  - `curl` - HTTP requests
  - `unzip` - Extracting runner bundle
  - Java 11+ - Only for shell runner

## Release Process

1. Bump `VERSION` file
2. Push to main
3. GitHub Actions builds:
   - Docker images: `ghcr.io/westito/aws-bitbucket-runner-{docker|shell}:vX.Y.Z`
   - Bundles: `runner-docker.zip`, `runner-shell.zip`
   - GitHub release with tag `vX.Y.Z`

## Caching

**Warning**: Avoid Bitbucket's cache feature - traffic goes through Bitbucket servers.

**Use instead**:
- Docker layers: CodeBuild cache or ECR registry cache with containerd
- NPM/Node: S3 bucket or EBS volumes
- General: CodeBuild S3 caching

## Code Style
- Shell: `#!/bin/bash`, `set -eo pipefail`
- Scripts: lowercase with hyphens
- Env vars: UPPER_SNAKE_CASE
- Functions: lowercase with underscores
- Never log secrets
- All curl commands must have `--connect-timeout` and `--max-time`
- Use `jq` for JSON construction (not string interpolation)
- Use `umask 077` before writing sensitive files
