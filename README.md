# aws-bitbucket-runner

AWS CodeBuild Runner project extension to support Bitbucket Pipelines.

## Overview

AWS CodeBuild natively supports managed runners for GitHub Actions, GitLab, and Buildkite - but not Bitbucket. This image bridges that gap by enabling dynamic runner deployment: Bitbucket Pipelines triggers CodeBuild via OIDC, which spins up an ephemeral self-hosted Bitbucket runner on-demand.

## Runner Types

Two runner types are available:

| Type | Image | Description |
|------|-------|-------------|
| **Docker** | `ghcr.io/westito/aws-bitbucket-runner-docker` | Runs Bitbucket's official Docker runner container |
| **Shell** | `ghcr.io/westito/aws-bitbucket-runner-shell` | Runs shell runner binary directly (requires Java 11+) |

### Shell Runner
- No need to define `image` in pipeline step - scripts run directly on CodeBuild image
- Uses tools installed on CodeBuild image (like running via `buildspec.yaml`)
- Faster startup - no Docker overhead

### Docker Runner
- Requires `image` in pipeline step (or defaults to Bitbucket's default image)
- Runs like standard Bitbucket Pipelines
- More isolation between builds

Runner labels are auto-detected based on architecture:
- **x86_64**: `linux,codebuild`
- **ARM64**: `linux.arm64,codebuild`

## Usage

```yaml
pipelines:
  default:
    - step:
        name: Start CodeBuild Runner
        image: ghcr.io/westito/aws-bitbucket-runner-shell:latest  # or -docker
        oidc: true
        clone:
          enabled: false  # Skip clone to speed up - not needed for starter step
        script:
          - export CODEBUILD_REGION="eu-central-1"
          - export CODEBUILD_PROJECT="my-project"
          - export AWS_ROLE_ARN="arn:aws:iam::ACCOUNT_ID:role/BitbucketPipelineRole"
          - start-runner
    - step:
        name: Build
        # Note: No image needed for shell runner (linux.shell) - runs directly on CodeBuild image
        # For Docker runner (linux/linux.arm64), image definition IS required
        runs-on:
          - self.hosted
          - linux.shell
          - codebuild
        script:
          - echo "Running on CodeBuild runner!"
```

### Docker Build Example (Shell Runner)

```yaml
pipelines:
  default:
    - step:
        name: Start CodeBuild Runner
        image: ghcr.io/westito/aws-bitbucket-runner-shell:latest
        oidc: true
        clone:
          enabled: false  # Skip clone to speed up - not needed for starter step
        script:
          - export DOCKER_CONTAINERD="true"
          - export CODEBUILD_PROJECT="my-project"
          - start-runner
    - step:
        name: Build Docker Image
        # Note: No image needed for shell runner - runs directly on CodeBuild image
        runs-on:
          - self.hosted
          - linux.shell
          - codebuild
        script:
          - aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
          - docker build -t $ECR_REGISTRY/$ECR_REPO:$BITBUCKET_COMMIT .
          - docker push $ECR_REGISTRY/$ECR_REPO:$BITBUCKET_COMMIT
```

### NPM Build Example (Docker Runner)

```yaml
pipelines:
  default:
    - step:
        name: Start CodeBuild Runner
        image: ghcr.io/westito/aws-bitbucket-runner-docker:latest
        oidc: true
        clone:
          enabled: false  # Skip clone to speed up - not needed for starter step
        script:
          - export CODEBUILD_PROJECT="my-project"
          - start-runner
    - step:
        name: Build NPM Project
        image: node:20
        runs-on:
          - self.hosted
          - linux
          - codebuild
        script:
          - npm ci
          - npm run build
          - npm test
```

## Caching

### Docker Layer Cache with Containerd

For Docker builds with layer caching, enable containerd snapshotter:

```yaml
pipelines:
  default:
    - step:
        name: Start CodeBuild Runner
        image: ghcr.io/westito/aws-bitbucket-runner-shell:latest
        oidc: true
        clone:
          enabled: false  # Skip clone to speed up - not needed for starter step
        script:
          - export DOCKER_CONTAINERD="true"
          - start-runner
    - step:
        name: Build
        # Note: No image needed for shell runner - runs directly on CodeBuild image
        runs-on:
          - self.hosted
          - linux.shell
          - codebuild
        script:
          - aws ecr get-login-password --region eu-central-1 | docker login --username AWS --password-stdin $ECR_REGISTRY
          - docker buildx build \
              --cache-from type=registry,ref=$ECR_REPO:cache \
              --cache-to type=registry,ref=$ECR_REPO:cache \
              -t $ECR_REPO:$BITBUCKET_COMMIT \
              --push .
```

### Cache Warning

**Warning:** Avoid using Bitbucket's built-in cache feature with self-hosted runners. Cache download/upload traffic goes through Bitbucket's servers, which can be slow and incur significant data transfer costs.

**Recommended alternatives:**
- **Docker layers:** Enable Docker layer cache in CodeBuild project settings, or use ECR registry cache with containerd (see [Docker Containerd Snapshotter](#docker-containerd-snapshotter))
- **NPM/Node modules:** Use S3 bucket or EBS volumes
- **General caching:** Configure CodeBuild's built-in caching with S3

> **Important:** Use containerd snapshotter to avoid needing `docker buildx create --driver docker-container`. The docker-container driver breaks CodeBuild's Docker layer cache because it runs a separate BuildKit container. With containerd enabled, the default driver supports registry cache export/import directly.

## Authentication

The runner needs Bitbucket API access to register/unregister self-hosted runners.

Create an OAuth Consumer in Bitbucket workspace settings with the following permissions:

| Permission | Level |
|------------|-------|
| Repositories | Read |
| Webhooks | Read and write |
| Pipelines | Read, Write, Edit variables |
| Runners | Read, Write |

**Pass from pipeline** (credentials forwarded to CodeBuild):
```yaml
script:
  - export BITBUCKET_OAUTH_CLIENT_ID=$BITBUCKET_OAUTH_CLIENT_ID
  - export BITBUCKET_OAUTH_CLIENT_SECRET=$BITBUCKET_OAUTH_CLIENT_SECRET
  - start-runner
```

**Or store in CodeBuild** project environment variables (from AWS Parameter Store - no pipeline config needed).

## Command Line Options

You can use environment variables or command line arguments:

```bash
start-runner --project my-project --region eu-central-1 --role arn:aws:iam::123:role/MyRole
```

| Option | Env Variable | Description |
|--------|--------------|-------------|
| `-p, --project` | `CODEBUILD_PROJECT` | CodeBuild project name |
| `-r, --region` | `CODEBUILD_REGION` | AWS region |
| `--role` | `AWS_ROLE_ARN` | IAM role ARN |
| `--timeout` | `CODEBUILD_TIMEOUT` | Build timeout (minutes) |
| `--queued-timeout` | `CODEBUILD_QUEUED_TIMEOUT` | Queued timeout (minutes) |
| `--compute-type` | `CODEBUILD_COMPUTE_TYPE` | Compute type override |
| `--image` | `CODEBUILD_IMAGE` | Build image override |
| `--startup-timeout` | `STARTUP_TIMEOUT` | Max wait for runner startup in seconds (default: 600) |
| `--containerd` | `DOCKER_CONTAINERD=true` | Enable Docker containerd snapshotter |
| `--custom-buildspec` | `CUSTOM_BUILDSPEC=true` | Use CodeBuild project's buildspec instead of generated one |
| `--label` | `RUNNER_LABEL` | Custom runner label (added to default labels) |
| `--multi-step` | `MULTI_STEP=true` | Wait for full pipeline completion (default: stop after first step) |

### Multi-Step Pipelines

By default, the runner stops after the first self-hosted step completes. This is optimal when you have a single build step followed by cloud-based steps (like deploy):

```yaml
pipelines:
  branches:
    dev:
      - step:
          name: Start CodeBuild Runner
          image: ghcr.io/westito/aws-bitbucket-runner-shell:latest
          oidc: true
          clone:
            enabled: false
          script:
            - start-runner --project my-project
      - step:
          name: Build
          # Note: No image needed for shell runner - runs directly on CodeBuild image
          runs-on:
            - self.hosted
            - linux.shell
            - codebuild
          script:
            - npm run build
      - step:
          name: Deploy  # Runs on Bitbucket cloud, not self-hosted
          deployment: dev
          oidc: true
          clone:
            enabled: false
          script:
            - pipe: atlassian/aws-ecs-deploy:1.15.0
```

For pipelines with **multiple self-hosted steps**, use `--multi-step` to keep the runner alive until the entire pipeline completes:

```yaml
script:
  - start-runner --project my-project --multi-step
# or
script:
  - export MULTI_STEP="true"
  - start-runner --project my-project
```

### Concurrency

Multiple concurrent builds are supported - you can spin up multiple runners for a single repo. However, since dynamic labels cannot be added to pipeline `runs-on` at runtime, concurrent pipelines may cause issues where a build step gets picked up by a runner that is about to terminate, resulting in canceled builds.

> **Note:** Using `--multi-step` increases the chance of concurrency issues because the runner stays alive longer, giving it more opportunity to pick up steps from other pipelines.

To prevent this:
1. Set **concurrency limit to 1** in your AWS CodeBuild project settings (or higher if using custom labels)
2. Use custom labels for different branches/stages
3. Add `concurrency-group` to **all steps** in your pipeline:

```yaml
pipelines:
  branches:
    dev:
      - step:
          name: Start CodeBuild Runner
          image: ghcr.io/westito/aws-bitbucket-runner-shell:latest
          oidc: true
          clone:
            enabled: false  # Skip clone to speed up - not needed for starter step
          concurrency-group: dev-build
          script:
            - export RUNNER_LABEL="dev"
            - start-runner
      - step:
          name: Build
          # Note: No image needed for shell runner - runs directly on CodeBuild image
          concurrency-group: dev-build
          runs-on:
            - self.hosted
            - linux.shell
            - codebuild
            - dev  # matches RUNNER_LABEL
          script:
            - echo "Building..."
```

This ensures:
- Each branch/stage has its own runner label
- `concurrency-group` prevents multiple pipelines from the same group running simultaneously
- Runners only pick up builds with matching labels

> **Note:** Concurrency groups are not required for concurrent builds to work, but without them you may experience canceled builds when a terminating runner picks up a step from a different pipeline.

### Docker Containerd Snapshotter

By default, the containerd snapshotter is **disabled**. Enable it if you need `docker buildx` cache export/import to container registries (like ECR).

```yaml
script:
  - export DOCKER_CONTAINERD="true"
  - start-runner
# or
script:
  - start-runner --containerd
```

> **Note:** This option controls Docker on the CodeBuild host, so it's only useful in **Shell mode**. If you need Docker commands, prefer Shell mode over Docker mode.

> **Important:** Use containerd snapshotter to avoid needing `docker buildx create --driver docker-container`. The docker-container driver breaks CodeBuild's Docker layer cache because it runs a separate BuildKit container. With containerd enabled, the default driver supports registry cache export/import directly.

### Custom Environment Variables

Use `CODEBUILD_ENV_*` prefix to forward custom variables to CodeBuild (prefix is stripped):

```yaml
script:
  - export CODEBUILD_ENV_MY_VAR="my-value"      # Becomes MY_VAR in CodeBuild
  - export CODEBUILD_ENV_DATABASE_URL=$DB_URL   # Becomes DATABASE_URL in CodeBuild
  - start-runner
```

Note: Bitbucket default variables cannot be overridden.

## How It Works

The `start-runner` command:

1. Generates a buildspec that downloads the runner bundle from GitHub releases
2. Starts CodeBuild with the buildspec override
3. Waits for CodeBuild to reach BUILD phase (runner is online)

### Custom Buildspec

By default, `start-runner` generates and sends the buildspec to CodeBuild automatically. **You do not need to configure any buildspec in your CodeBuild project.**

If you need to customize the build process, use `--custom-buildspec` flag to use a buildspec defined in your CodeBuild project instead:

```yaml
script:
  - export CUSTOM_BUILDSPEC="true"
  - start-runner
# or
script:
  - start-runner --custom-buildspec
```

**Important:** Only use this option if you need to customize the build process. Your custom buildspec **must** include the runner installation and phase scripts:

```yaml
version: 0.2
phases:
  install:
    commands:
      # Downloads and installs the runner (uses latest release)
      - curl -sL "https://github.com/westito/aws-bitbucket-runner/releases/latest/download/install-shell.sh" | sh
  pre_build:
    commands:
      - /runner/pre_build.sh
  build:
    commands:
      - /runner/build.sh
  post_build:
    commands:
      - /runner/post_build.sh
```

Install scripts are available for both runner types:

```bash
# Shell runner
curl -sL https://github.com/westito/aws-bitbucket-runner/releases/latest/download/install-shell.sh | sh

# Docker runner
curl -sL https://github.com/westito/aws-bitbucket-runner/releases/latest/download/install-docker.sh | sh

# Install to custom directory
curl -sL .../install-shell.sh | sh -s -- --dest /opt/runner
```

## CodeBuild Project Requirements

- **Image**: Any image with Docker support and required tools. Recommended AWS managed images:
  - ARM: `aws/codebuild/amazonlinux-aarch64-standard:3.0`
  - x86_64: `aws/codebuild/amazonlinux-x86_64-standard:5.0`
- **Architecture**: Both `arm64` and `x86_64` are supported
- **Privileged mode**: Required (for Docker builds)
- **Source**: Can be `NO_SOURCE` (runner scripts are downloaded from GitHub releases)
- **Required tools** (included in recommended images):
  - `jq` - JSON processing
  - `curl` - HTTP requests
  - `unzip` - Extracting runner bundle
  - Java 11+ - Only for shell runner (not needed for docker runner)

### CodeBuild Environment Variables

Optional environment variables that can be set in CodeBuild project settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `BITBUCKET_POLL_INTERVAL` | `10` | Pipeline state polling interval in seconds |

> **Note:** Bitbucket API rate limit is 1000 requests/hour. With default 10s interval, a single build uses ~360 requests/hour. For many concurrent builds, increase this value to avoid rate limiting. However, higher intervals mean the runner stays alive longer after completion and may pick up other jobs - use `concurrency-group` to prevent this (see [Concurrency](#concurrency)).

## Links

- [AWS CodeBuild Runner Projects](https://docs.aws.amazon.com/codebuild/latest/userguide/runner-projects.html)
- [Bitbucket OIDC](https://support.atlassian.com/bitbucket-cloud/docs/integrate-pipelines-with-resource-servers-using-oidc/)
- [GitHub Releases](https://github.com/westito/aws-bitbucket-runner/releases)
