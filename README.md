# build-server

Self-hosted GitHub Actions runner pool on a single host, powered by upstream [actions-runner-controller](https://github.com/actions/actions-runner-controller) (ARC) on k3s. ARC uses GitHub's **Just-in-Time runner configs** — each pod is bound to one specific job, so there is no shared org pool and no spawn race.

This repo provides:
- Deploy scaffolding (`setup.sh`, `scripts/deploy-scale-set.sh`).
- A reference generic runner image at `ghcr.io/jakwuh/actions-runner:latest` (Dockerfile in `runner-image/`). It's an upstream `actions-runner` + the minimum CLI toolkit (`gh`, `aws`, `jq`, `git`, `curl`, `unzip`, `zip`, `xz`, `rsync`, `gnupg`) — everything else (Node, Java, Flutter, Playwright, Android SDK, Python …) is installed on demand by workflow steps via `setup-*` actions, cached through `actions/cache`. Use this for every scale-set unless you have a reason not to.

## Architecture

```
GitHub Actions broker ──long-poll──► ARC listener ─► ARC controller ─► k8s pod (JIT runner) ──► job
```

One **scale-set** per `(GitHub org, runner image)` pair. The scale-set's name becomes the `runs-on:` label workflows use.

## Bootstrap a host

```bash
# Fresh host (24+ vCPU, 16+ GB RAM recommended for production load):
ssh root@<HOST>
bash <(curl -fsSL https://raw.githubusercontent.com/jakwuh/build-server/main/setup.sh)
```

`setup.sh` installs k3s + helm + the ARC controller into namespace `arc-systems`. Then deploy one scale-set per `(org, image)` you need.

## Deploy a scale-set

```bash
APP_ID=<github-app-id> \
INSTALL_ID=<github-app-installation-id> \
ORG=<github-org-or-user> \
NAME=<scale-set-name>           # = the runs-on: label \
IMAGE=ghcr.io/your-org/your-runner:tag \
MAX=20 \
PRIVATE_KEY_FILE=/path/to/app-private-key.pem \
scripts/deploy-scale-set.sh
```

The GitHub App webhook URL is **not used** — ARC pulls from GitHub's runner broker via long-polling with the App credentials.

### The scale-sets on `bld1`

Written down because the sizing is not the defaults, and re-running the script without
these would quietly shrink the pools and drop miraj's local registry mirror. `PRIVATE_KEY_FILE`
is the **jakwuh-build-server** App PEM; App id `3743839` for both.

```bash
# Miraj-OS org — `runs-on: self-hosted`; also pulls through the in-cluster registry cache.
# NAMESPACE is mandatory here: the pool lives in arc-miraj, while the default
# derived from the org would be arc-miraj-os. Deploy without it and you get a
# second scale-set sharing the same GitHub registration instead of an upgrade.
APP_ID=3743839 INSTALL_ID=133143010 ORG=Miraj-OS NAME=self-hosted MIN=0 MAX=8 \
  NAMESPACE=arc-miraj RELEASE=miraj-self-hosted \
  CPU_REQUEST=500m MEM_REQUEST=2Gi DIND_CPU_REQUEST=250m DIND_MEM_REQUEST=1Gi \
  REGISTRY_MIRRORS=http://10.43.104.17:5000 \
  IMAGE=ghcr.io/jakwuh/actions-runner:<sha> \
  PRIVATE_KEY_FILE=<app>.pem scripts/deploy-scale-set.sh
```

Miraj sizing was approved on 2026-10-03: keep the pool and shared BuildKit,
scale idle runners to zero, and reserve 500m CPU for runner + 250m for DinD.
Memory requests stay 2Gi + 1Gi, CPU limits 4 + 4, memory limits 6Gi + 4Gi,
and maxRunners stays 8. A cold job may wait for a new runner; compare queue and
execution time before treating the smaller reservation as an improvement.
Rollback sizing: `MIN=1 CPU_REQUEST=1 DIND_CPU_REQUEST=1`, retaining every
other value. For an existing release, save `helm get values` and upgrade the
same pinned chart with a full values file that changes only these three fields;
do not redeploy GitHub credentials just to change sizing.

#### izi-x: one pool per (priority tier × size)

ARC cannot size or prioritise a pod per job: a scale set is one pod template, and the
pod exists before GitHub tells it which job it runs. So the two axes are two choices
made by the workflow's `runs-on`:

- **tier** — `release` (push/dispatch/schedule on `release`, `mobile-widget/release`,
  `mobile-widget/pre-release`), `main` (the same events on `main`), `pr` (everything else —
  `pull_request_target` and `issue_comment` report `ref_name=main`, hence the event check).
  Release and main have their own `maxRunners`, so they never queue behind PR jobs for a
  runner, and a PriorityClass that puts their pods first when the node is full;
- **size** — `small` (no dind: gates, deploy, schema audit, secret scan, and every image
  build — they are only clients of a persistent buildkitd), `heavy` (no dind: validate
  api/crm, mobile checks), `k8s` (`CONTAINER_MODE=kubernetes-novolume`: jobs with
  `container:`/`services:` — migrations compat, e2e — run as their own pod on images the
  node's containerd keeps; in dind they were pulled and unpacked into an empty store on
  every job, 173–1648 s to start).

Image builds run on two persistent buildkitd: `buildkitd` (PR code,
`vars.PR_BUILDKIT_ENDPOINT`) and `buildkitd-trusted` (main/release only, NetworkPolicy,
`vars.TRUSTED_BUILDKIT_ENDPOINT`) — a cache mount shared with PR code could poison a prod
image. arm64 runs through the host's binfmt (`qemu-user-static`, setup.sh).

Sizing — below the table.

| scale set | tier | PriorityClass | runner req → lim | job pod req → lim | MAX |
| --- | --- | --- | --- | --- | --- |
| `izi-x-pr-small` | pr (idle) | — | 10m/512Mi → 2/1Gi | — | 48 |
| `izi-x-pr-heavy` | pr (idle) | — | 10m/6Gi → 4/6Gi | — | 9 |
| `izi-x-pr-k8s` | pr (idle) | — | 100m/256Mi → 1/1Gi | 10m/1.5Gi → 4/6Gi | 16 |
| `izi-x-pr-required` | pr | `ci-pr-required` | 2/4.5Gi → 4/6Gi | — | 7 |
| `izi-x-pr-required-small` | pr | `ci-pr-required` | 50m/512Mi → 2/1Gi | — | 6 |
| `izi-x-main-small` | main | `ci-main` | 100m/512Mi → 2/1Gi | — | 22 |
| `izi-x-main-heavy` | main | `ci-main` | 2/6Gi → 4/6Gi | — | 5 |
| `izi-x-main-k8s` | main | `ci-main` | 100m/256Mi → 1/1Gi | 1/6Gi → 4/6Gi | 1 |
| `izi-x-release-small` | release | `ci-release` | 50m/512Mi → 2/1Gi | — | 17 |
| `izi-x-release-large` | release | `ci-release` | 2/6Gi → 4/6Gi | — | 3 |

Sizing, from 2026-10-08 (GitHub jobs API: queue and run times of every job; cAdvisor: CPU and
memory per job; job budget = allocatable − non-job requests = 17.4 CPU, 50.3 GiB):

- Memory request = p95 working set of the pool's jobs. Below it the kubelet evicts work under
  pressure; above it memory sits reserved and unused. The scheduler then packs by real memory
  and hands freed memory to the Pending queue in priority order.
- CPU request = the mean cores a job of the pool uses; optional PR pools 10m (`cpu.idle`).
- Priority pools: MAX = peak demand (queued + running). Their joint peak — 16.4 CPU of
  requests, 31.6 GB of real memory — fits the budget, so they never wait on a ceiling.
- Optional PR pools: MAX = min(17.4 CPU / mean cores per job, peak demand) — past CPU saturation
  more pods only wait. pr-heavy min(9, 24), pr-k8s min(60, 16), pr-small min(96, 48).
- meta and the validate gates (7–9 s) have `izi-x-pr-required-small`: in `izi-x-pr-required`
  they held 309 of 478 slots of 2 CPU / 4 GiB that validate waited for.

## Tier isolation

PriorityClasses order only the Pending queue (`preemptionPolicy: Never`); a running optional PR job
used to share CPU with a release build by requests and the disk equally. Now:

- `scripts/ci-tier-weights.sh` (`ci-tier-weights.service`) puts every optional PR pod — pr-small,
  pr-heavy, pr-k8s and their `-workflow` pods, and the PR buildkitd — into the idle tier on its pod
  slice through systemd: `CPUWeight=idle` (cpu.idle — runs only on CPU no other pod wants) and
  `IOWeight=1` (others 100). A direct write to the cgroup file does not hold: systemd re-applies a
  slice's properties whenever a container scope starts under it.
- `iocost.service` enables blk-iocost on `sda` at boot with `/etc/iocost.model`, the output of the
  kernel's `tools/cgroup/iocost_coef_gen.py` run on this disk with no jobs running:
  `python3 iocost_coef_gen.py --testfile-size-gb 16 > /etc/iocost.model`. bld1, 2026-10-09 01:45 UTC:
  `8:0 rbps=810426024 rseqiops=23498 rrandiops=7315 wbps=127570737 wseqiops=11981 wrandiops=3735`.
  The model sets the relative cost of IO kinds; the QoS stays at the kernel's defaults, so the
  controller scales the issue rate by the device's own saturation state.
- Optional PR pools request `CPU_REQUEST=10m`: their CPU is bounded by `cpu.idle`, not by the
  scheduler, so a PR reservation can no longer keep a main/release pod Pending. pr-heavy `MAX=9`:
  the job budget of 17.4 CPU over 1.83 cores per pr-heavy job (2026-10-08) — past that more pods
  only wait. main-small / release-small request the average they use (0.06 / 0.03 cores; they
  wait on buildkitd), rounded up to 50m.
- CPU limits stay: Node, Go and Gradle size their worker pools from `cpu.max`.

Required PR checks (validate api/crm, behind the merge gates) have their own pool,
`izi-x-pr-required`, at `ci-pr-required`: ahead of every optional PR job (mobile checks, compat,
schema audit), behind main and release.

Listeners, buildkitd and the registry cache run at `ci-infra` (above every job, never
preempting): otherwise a listener recreated by a pool upgrade waits Pending behind jobs on a
full node and its pool takes nothing meanwhile.

All izi-x pools run with `DIND_EXTERNALS=false` and `CI_HOST_CACHE=true`
(`scripts/install-ci-host-cache.sh` must have run on the node first). `CACHE_TIER` is `pr` for the
PR pools and `trusted` for main/release, and every host cache exists once per tier under
`/opt/ci-tier/<tier>`: PR code runs as the same uid as trusted jobs, and the toolcache (node,
flutter), pub (it checks a package against its stored hash file, not the unpacked files) and
build_runner output are all executed by release builds. npm's cacache is content-verified on read,
but it is split too, for one rule instead of a per-cache exception. Jobs link `node_modules` to a
tree installed once per package-lock in `/ci-cache/node_modules` (izi-x
`.github/actions/node-modules`): on 2026-10-08 the per-job copies (690 MB / 70k files for api or
crm, ~280 GB of ~1 TB in 7 h) were the disk's write ceiling. Service containers of
`k8s` jobs get the `manifests/limitrange-arc-izi-x.yaml` defaults.

```bash
# First: kubectl apply -f manifests/runner-priority-classes.yaml -f manifests/limitrange-arc-izi-x.yaml
COMMON="APP_ID=3743839 INSTALL_ID=133105803 ORG=izi-x NAMESPACE=arc-izi-x IMAGE=ghcr.io/jakwuh/actions-runner:<sha> PRIVATE_KEY_FILE=<app>.pem DIND_EXTERNALS=false CI_HOST_CACHE=true"
SMALL="DIND=false CPU_REQUEST=250m MEM_REQUEST=512Mi CPU_LIMIT=2 MEM_LIMIT=1Gi WORK_SIZE=4Gi"
HEAVY="DIND=false CPU_REQUEST=2 MEM_REQUEST=6Gi CPU_LIMIT=4 MEM_LIMIT=6Gi WORK_SIZE=16Gi"
K8S="DIND=false CONTAINER_MODE=kubernetes-novolume CPU_REQUEST=1 MEM_REQUEST=2Gi CPU_LIMIT=4 MEM_LIMIT=6Gi WORK_SIZE=8Gi"
env $COMMON $SMALL CPU_REQUEST=10m  NAME=izi-x-pr-small          MIN=1 MAX=48 CACHE_TIER=pr scripts/deploy-scale-set.sh
env $COMMON $HEAVY CPU_REQUEST=10m  NAME=izi-x-pr-heavy          MIN=0 MAX=9  CACHE_TIER=pr scripts/deploy-scale-set.sh
env $COMMON $K8S   CPU_REQUEST=10m MEM_REQUEST=1536Mi NAME=izi-x-pr-k8s MIN=0 MAX=16 CACHE_TIER=pr scripts/deploy-scale-set.sh
env $COMMON $HEAVY MEM_REQUEST=4608Mi NAME=izi-x-pr-required     MIN=0 MAX=7  CACHE_TIER=pr PRIORITY_CLASS=ci-pr-required scripts/deploy-scale-set.sh
env $COMMON $SMALL CPU_REQUEST=50m  NAME=izi-x-pr-required-small MIN=0 MAX=6  CACHE_TIER=pr PRIORITY_CLASS=ci-pr-required scripts/deploy-scale-set.sh
env $COMMON $SMALL CPU_REQUEST=100m NAME=izi-x-main-small        MIN=0 MAX=22 CACHE_TIER=trusted PRIORITY_CLASS=ci-main scripts/deploy-scale-set.sh
env $COMMON $HEAVY                  NAME=izi-x-main-heavy        MIN=0 MAX=5  CACHE_TIER=trusted PRIORITY_CLASS=ci-main scripts/deploy-scale-set.sh
env $COMMON $K8S   MEM_REQUEST=6Gi  NAME=izi-x-main-k8s          MIN=0 MAX=1  CACHE_TIER=trusted PRIORITY_CLASS=ci-main scripts/deploy-scale-set.sh
env $COMMON $SMALL CPU_REQUEST=50m  NAME=izi-x-release-small     MIN=0 MAX=17 CACHE_TIER=trusted PRIORITY_CLASS=ci-release scripts/deploy-scale-set.sh
env $COMMON $HEAVY                  NAME=izi-x-release-large     MIN=0 MAX=3  CACHE_TIER=trusted PRIORITY_CLASS=ci-release scripts/deploy-scale-set.sh
```

To change only sizing on a live pool: `helm upgrade --reuse-values --set-json maxRunners=N
--set-json minRunners=M` with the same pinned chart. Plain `--set` fails: the chart compares
`minRunners` (float64 from the stored values) with the int64 from `--set`.
Changing a pool's pod template recreates its listener: the controller deletes the old one, which
shows `Terminating` for up to its 30 s grace period, then the new one starts. That is the normal
shutdown, not a hang (2026-10-08: `Killing` events 09:04:59–09:05:47, volumes unmounted from
09:05:31) — no force delete.

Retiring a pool — order matters, or jobs queue for 24h for a label nobody serves: change the
workflows' `runs-on` first, wait until no queued job asks for the label, then
`helm uninstall <release> -n arc-izi-x` (keep `github-app` and `ghcr-pull` — shared).

Pin `IMAGE` to a commit sha, never `:latest` — a scale-set is only rolled when its pod
template changes, so a moving tag means the pool keeps running whatever it pulled first.

## Runner image contract

The reference image (`runner-image/`) and any custom image you want to use must satisfy ARC's DinD container mode:

1. **Base on `ghcr.io/actions/actions-runner:latest`** (or any image that ships the upstream runner layout). That gets you everything below for free.
2. **`/home/runner/{run.sh,config.sh,bin,externals,k8s,env.sh,...}`** must be present. The chart's `init-dind-externals` init container `cp -r`s from `/home/runner/externals`; the runner container `exec`s `/home/runner/run.sh`. Missing either → `Init:Error` or `OCI runtime ... no such file or directory`.
3. **`runner` user must be in a group with GID 123.** The chart hardcodes `DOCKER_GROUP_GID=123` for the dind sidecar, so the docker socket ends up owned `root:123` — the runner needs that group to use it. The upstream image already puts `runner` in `docker:123`. Without it: `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`.

`myoung34/github-runner` does **not** satisfy any of the above. It has no `run.sh`, no `externals/`, and its `docker` group is GID 500. Don't use it as a base — there's no clean ARC-DinD adapter that doesn't end up being a wrapper image with the missing pieces re-copied in.

## Not in this repo

`setup.sh` gets a fresh box to a working pool, but it cannot produce these. Check them off by
hand when you rebuild or move the host, or the box will come up looking healthy and quietly
serving nothing:

| What | Where it comes from |
|---|---|
| Tailnet membership + the `tag:buildsrv` tag | `tailscale up --authkey` with an auth key from 1Password; the tag is what the tailnet policy grants on |
| Tailnet grants to reach the clusters | the tailnet ACL (`tag:buildsrv` → `tag:k8s-operator`, impersonating a group that RBAC binds inside the target cluster) |
| `github-app` secret in each `arc-*` namespace | GitHub App **jakwuh-build-server** (app id, installation id, private key) — the same App the runner healthcheck mints tokens from |
| `ghcr-pull` secret in each `arc-*` namespace | **Deliberately empty** (`{"auths":{}}`) since 2026-09-25. `ghcr.io/jakwuh/actions-runner` and the ARC charts are public and pull anonymously. A credential here is worse than none: once the token expires, ghcr answers `403 denied` instead of falling through to anonymous access, and kubelet does not retry anonymously either — the next new runner tag would sit in `ImagePullBackOff`. That is how the old token (issued 2026-05-18) was found dead in both namespaces. The same goes for a `ghcr.io` entry in root's `~/.docker/config.json`: it breaks `helm upgrade … oci://ghcr.io/actions/…`, so keep it absent. Only put a real `read:packages` token here if the runner image becomes private. The pool spec still references the secret, so keep it present, even when empty. |
| `/etc/arc-watchdog/{tg-token,config}` | alerts bot token + chat id; without them the watchdog heals silently |
| Anything izi-x-specific | lives in `izi-x/izi-x-infra`, not here — e.g. `ops/pr-stand-janitor` |

The rule for what belongs where: this repo is the **build server as a machine** — the pool,
the image, the things that keep the pool alive. Anything that knows about a particular
product's clusters, namespaces or databases belongs to that product's repo, even when it
physically runs on this host.

## Self-heal watchdog

`scripts/arc-watchdog.sh` (installed by `setup.sh` as an `arc-watchdog.timer` firing every
3 minutes) exists because ARC can die in ways that produce **no red check anywhere** — jobs
simply queue forever. Both of these happened for real on 2026-08-06/07 after a GitHub Actions
outage and cost ~12 hours:

- the `AutoscalingListener` CR keeps pointing at a deleted `EphemeralRunnerSet`, so the
  listener pod crash-loops on `could not patch ephemeral runner set ... not found`;
- the controller wedges outright (log frozen mid `deleting runner scale set`) and no listener
  is created at all;
- the listener pod stays Running and Ready, but after a network outage its long-poll to the
  GitHub broker never returns again (2026-10-08: ten listeners, `Client.Timeout exceeded while
  awaiting headers`, until their pods were recreated). A healthy listener logs
  `Calculated target runner count` after every poll (~50 s); none in 10 minutes is a strike.

The watchdog heals on the second consecutive unhealthy check — deleting the stale listener CR
in the first case, restarting the controller in the second, deleting the listener pod in the third — and announces what it did to
Telegram if `/etc/arc-watchdog/tg-token` (chmod 600) and `TG_CHAT=` in `/etc/arc-watchdog/config`
are present. Without those it heals silently.

**The restart is not a reliable cure.** On 2026-09-24 both pools had no listener from 15:31 to
16:13 UTC and seven restarts, one every six minutes, changed nothing; what brought them back was
a helm upgrade that altered the runner pod template and so forced a fresh EphemeralRunnerSet and
listener. A repeating alert therefore means the repair is *not* working — treat it as a page, not
as a resolution. Before each heal the watchdog now dumps the controller and listener logs, the
CRs, the pods and the events to `/var/lib/arc-watchdog/incident-<ts>-<ns>_<name>/` (last 20 kept),
because `rollout restart` destroys the controller pod and its log, which is why the 2026-09-24
wedge can no longer be explained. It also no longer counts a strike when the API is unreadable:
a starved apiserver is not an absent listener, and restarting the controller against one only
adds a full re-LIST to the queue it is already drowning in.

```bash
systemctl list-timers arc-watchdog.timer arc-runner-janitor.timer
journalctl -u arc-watchdog.service --since -1h
/opt/build-server/arc-watchdog.sh          # run once by hand; silence == healthy
```

`scripts/arc-runner-janitor.sh` (every 5 minutes) covers the neighbouring failure: the dind
sidecar exits while the runner container keeps running, so the pod sits at `1/2 Error`
forever — taking no work, holding its CPU requests. Enough of them and the node hits its
requests ceiling, the next dind's containerd misses its startup window and becomes another
zombie. That loop stalled CI on 2026-08-06 after a reboot: 23 queued runs against a pool that
looked healthy. Deleting the pod is safe — ARC recreates it, GitHub re-assigns the job.

## Operations

```bash
# List scale-sets and pods
kubectl get autoscalingrunnerset -A
kubectl get pods -A | grep -E '^arc-'

# Tail listener logs
kubectl -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener -f

# Bump max runners on an existing release
helm upgrade <release> -n <namespace> --reuse-values --set maxRunners=50 \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

## Tuning

- **Per-host capacity**: `maxRunners` per scale-set + pod template resource *requests* decide how many pods the scheduler admits. They do not decide how much a pod may then take — that is the *limits*, and a pool without them will eventually take the node down instead of failing one job. `MEM_LIMIT` / `DIND_MEM_LIMIT` / `CPU_LIMIT` / `DIND_CPU_LIMIT` in `scripts/deploy-scale-set.sh` are not optional tuning. Cap `dind` as hard as the runner: buildkit fans out to every core it can see, and on 2026-09-24 a single pod was taking 14.8 of 24 cores through its uncapped dind while the runner container beside it sat under its own 4-core cap.
- **The control plane does not compete.** `setup.sh` reserves CPU and memory for k3s and the system through `/etc/rancher/k3s/config.yaml`. Without it the apiserver and kine lose to the builds, the node flaps NotReady, and the ARC listeners get evicted — the pool dies with jobs queuing and nothing red anywhere.
- **Never put the job tree in tmpfs.** `emptyDir: { medium: Memory }` is RAM the scheduler cannot account for — it is charged to nobody's request, and `sizeLimit` is per volume, so `maxRunners: 20` with a 16 GiB `work` volume promises 320 GiB on the box. It ends in swap thrash, not in an eviction. `work` and `dind-externals` are node disk; only the 32 KB `dind-sock` stays in memory.
- **Burst latency**: first pull of a runner image is slow (~1-2 min for multi-GB images). Subsequent spawns hit local cache and start in ~30s.
