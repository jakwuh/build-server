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

## Tuning

- **Per-host capacity**: limit via `maxRunners` per scale-set + pod template resource requests.
- **Burst latency**: first pull of a runner image is slow (~1-2 min for large images like the flutter SDK). Subsequent spawns hit local cache and start in ~30s.
- **Custom images**: must include `/home/runner/{run.sh,config.sh,bin,externals}` (standard GitHub Actions runner layout). Both `myoung34/github-runner`-based and `ghcr.io/actions/actions-runner`-based images work out of the box.
