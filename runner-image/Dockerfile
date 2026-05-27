# Generic actions-runner base image for ARC scale-sets.
#
# Adds the minimum CLI toolkit that github-hosted ubuntu-latest workflows take
# for granted: gh, aws, jq, common shell tools. Everything else (Node, Java,
# Flutter, Playwright, Android SDK, Python, etc.) is installed on-demand by
# workflow steps via setup-* actions, cached through actions/cache.
#
# Anyone consuming this image only needs to know:
#   - /home/runner/{run.sh,config.sh,bin,externals,k8s,env.sh,...} (from upstream)
#   - runner user is in the docker group (GID 123) — works with ARC's DinD sidecar
#
# Build is reproducible from this repo; nothing project-specific lives here.

FROM ghcr.io/actions/actions-runner:latest

USER root

# Core CLI tools every workflow expects:
#   - ca-certificates, curl, gnupg, lsb-release — needed by gh/aws install steps
#   - git, unzip, zip, xz-utils — needed by checkout & setup-* actions
#   - jq — used by most "configure from JSON output" steps
#   - rsync — used by upload/deploy scripts
RUN mkdir -p /etc/apt/keyrings \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release \
      git unzip zip xz-utils \
      jq rsync \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI (cli.github.com supports Ubuntu 24.04 noble).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (the apt awscli is v1 and EOL).
RUN ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) AWS_ARCH=x86_64 ;; \
      arm64) AWS_ARCH=aarch64 ;; \
      *) echo "unsupported arch: $ARCH"; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscliv2.zip

# In CI we trust every repo we operate on. Disable git's "dubious ownership"
# safety check (introduced in 2.35 by CVE-2022-24765). Without this, any step
# that touches /opt/hostedtoolcache/... after a sudo apt install (which
# changes mtimes/ownership) fails on `fatal: detected dubious ownership`.
RUN git config --system --add safe.directory '*'

# run.sh refuses to start as root when the sudo group has NOPASSWD ALL
# (which the upstream actions-runner ships). Switch back to runner explicitly.
USER runner
