# build-server

Self-hosted GitHub Actions runner pool, powered by [actions-runner-controller](https://github.com/actions/actions-runner-controller) (ARC) on single-node k3s.

This repo holds the deployment scripts — the runtime is upstream ARC. Previously this repo held a custom Python orchestrator (`runner_pool/`); it was retired after migrating to ARC, which uses GitHub's **Just-in-Time runner configs** (each spawn is bound to one specific job, so no org-pool race).

## Architecture

```
GitHub Actions broker ──long-poll──► ARC listener ─► ARC controller ─► k8s pod (JIT runner) ──► job
```

One **scale-set** per (org, runner-image). On this host:

| Namespace | Scale-set name | Image | Used by `runs-on:` |
|---|---|---|---|
| `arc-izi-x` | `izi-x-linux` | `ghcr.io/actions/actions-runner:latest` | `izi-x-linux` |
| `arc-izi-x` | `izi-x-flutter` | `ghcr.io/izi-x/actions-runner-flutter:latest` | `izi-x-flutter` |
| `arc-miraj` | `self-hosted` | `ghcr.io/actions/actions-runner:latest` | `self-hosted` |
| `arc-miraj` | `miraj-e2e` | `ghcr.io/miraj-os/e2e-runner:1.52.0-node20` | `miraj-e2e` |

## Setup

```bash
# Fresh host (24+ vCPU, 16+ GB RAM recommended for prod):
ssh root@<HOST>
bash <(curl -fsSL https://raw.githubusercontent.com/jakwuh/build-server/main/setup.sh)
```

`setup.sh` installs k3s + helm + ARC controller in `arc-systems`. Then run `scripts/deploy-scale-set.sh` for each scale-set you need.

GitHub App webhook URL is **not used** — ARC pulls from GitHub's runner-broker via long-polling with App credentials.

## Operations

```bash
# List scale-sets and pods
kubectl get autoscalingrunnerset -A
kubectl get pods -A | grep -E '^arc-'

# Tail listener logs
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener -f

# Bump max runners
helm upgrade <release> -n <namespace> --reuse-values --set maxRunners=50 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

## Custom runner images

Each project owns its runner image — this repo only deploys helm releases that reference an image URL. The image **must** satisfy ARC's DinD-mode contract:

1. **Base on `ghcr.io/actions/actions-runner:latest`** (or any image that ships the upstream runner layout). That gets you everything below for free.
2. **`/home/runner/{run.sh,config.sh,bin,externals,k8s,env.sh,...}`** must be present. The chart's `init-dind-externals` init container `cp -r`s from `/home/runner/externals`; the runner container `exec`s `/home/runner/run.sh`. Missing either → `Init:Error` or `OCI runtime ... no such file or directory`.
3. **`runner` user must be in a group with GID 123.** The chart hardcodes `DOCKER_GROUP_GID=123` for the dind sidecar, so the docker socket ends up owned `root:123` — the runner needs that group to use it. The upstream image already puts `runner` in `docker:123`. Without it: `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`.

`myoung34/github-runner` does **not** satisfy any of the above. It has no `run.sh`, no `externals/`, and its `docker` group is GID 500. Don't use it as a base — there's no clean ARC-DinD adapter that doesn't end up being a wrapper image with all the same pieces re-copied in.

Project-owned image sources currently in use:
- `ghcr.io/miraj-os/e2e-runner` — built from [Miraj-OS/miraj `.github/runner-images/e2e/`](https://github.com/Miraj-OS/miraj/tree/main/.github/runner-images/e2e)
- `ghcr.io/izi-x/actions-runner-flutter` — built from [izi-x/izi-x-infra `tools/runner-image-flutter/`](https://github.com/izi-x/izi-x-infra/tree/main/tools/runner-image-flutter)

## Tuning

- **Per-host capacity**: limit via `maxRunners` per scale-set + pod template resource requests.
- **Burst latency**: first pull of a runner image is slow (~1-2 min for large images like the flutter SDK at ~6 GB). Subsequent spawns hit local cache and start in ~30s.
