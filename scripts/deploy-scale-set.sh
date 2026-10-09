#!/usr/bin/env bash
# Deploy one ARC scale-set (= one Helm release).
#
# Usage:
#   APP_ID=… PRIVATE_KEY_FILE=path INSTALL_ID=… ORG=… NAME=… [IMAGE=…] [MAX=…] \
#     scripts/deploy-scale-set.sh
#
# Optional, and mandatory when the pool's namespace or Helm release name is not
# the derived default: NAMESPACE, RELEASE. Plus sizing: CPU_REQUEST,
# MEM_LIMIT, DIND_CPU_REQUEST, DIND_MEM_REQUEST, DIND_CPU_LIMIT,
# DIND_MEM_LIMIT, REGISTRY_MIRRORS ("host1 host2", highest priority first).
# Pod shape: PRIORITY_CLASS, DIND, DIND_EXTERNALS, CI_HOST_CACHE, CACHE_TIER, WORK_SIZE, CONTAINER_MODE.
#
# Prerequisites (once per namespace):
#   kubectl -n arc-<org> create secret docker-registry ghcr-pull \
#     --docker-server=ghcr.io \
#     --docker-username=<github-user> \
#     --docker-password=<PAT with packages:read>
#
# Examples:
#   APP_ID=123 INSTALL_ID=456 ORG=my-org NAME=my-org-linux MAX=8 \
#     PRIVATE_KEY_FILE=/etc/build-server/my-org.pem scripts/deploy-scale-set.sh
set -euo pipefail

: "${APP_ID:?GITHUB_APP_ID required}"
: "${INSTALL_ID:?GITHUB_APP_INSTALLATION_ID required}"
: "${ORG:?ORG required (GitHub org or user)}"
: "${NAME:?NAME required — scale-set name, must match runs-on: label in workflows}"
# No apostrophe in a :? message — inside ${VAR:?word} it opens a single quote
# that never closes, and the whole script dies at parse time.
: "${PRIVATE_KEY_FILE:?PRIVATE_KEY_FILE required — path to the GitHub App PEM file}"
IMAGE="${IMAGE:-ghcr.io/jakwuh/actions-runner:latest}"
MAX="${MAX:-8}"
MIN="${MIN:-1}"
# Per-container CPU/memory requests. These bound the scheduler so it never
# overpacks the node — without them a container is "weightless" → CPU contention
# → dind's managed containerd misses its 15s startup window → dind exits 1,
# runner hangs Running (1/2 Error forever), build times climb. The dind container
# is the one that runs dockerd + that managed containerd (and every
# `docker build`), so it MUST carry its OWN request — a requested runner sitting
# next to a weightless dind still lets the scheduler overpack dind and starve
# containerd at startup. Sized from p90 of live builds (runner 1.6 cores / 0.9Gi).
CPU_REQUEST="${CPU_REQUEST:-1}"
MEM_REQUEST="${MEM_REQUEST:-1.5Gi}"
DIND_CPU_REQUEST="${DIND_CPU_REQUEST:-1}"
DIND_MEM_REQUEST="${DIND_MEM_REQUEST:-1.5Gi}"
# Memory limits are mandatory, not tuning. A request only tells the scheduler how
# many pods fit; it does not stop one of them from eating the box. On 2026-09-24
# bld1 (24 vCPU / 62 GiB) ran 20 runners whose real footprint was 2.3–7.8 GiB per
# pod against a 1.75 GiB request: 58 GiB used, swap thrashing at 50 MB/s, load
# 351. k3s lost to the builds — kine answered in 18–83 s, the apiserver returned
# `Handler timeout`, kubelet reported `PLEG is not healthy`, and the node flapped
# NotReady long enough for the taint manager to evict the ARC listeners and for
# the kernel OOM killer to take arc-gha-rs-controller (exit 137). With no
# listener GitHub has nowhere to place jobs, and CI queues silently — the exact
# outage arc-watchdog was written for, except the watchdog cannot cure it.
# With a limit the offending container is OOM-killed alone and one job goes red.
MEM_LIMIT="${MEM_LIMIT:-6Gi}"
DIND_MEM_LIMIT="${DIND_MEM_LIMIT:-4Gi}"
# CPU limits, for the same reason as the memory ones. dind is where `docker
# build` actually runs, and buildkit fans out to every core it can see: measured
# on bld1 on 2026-09-24, one pod was taking 14.8 of 24 cores while its runner
# container sat under its own 4-core cap — the whole 14.8 was in the uncapped
# dind. A pod ceiling of CPU_LIMIT + DIND_CPU_LIMIT keeps one job from
# monopolising the box while leaving burst room for compile-heavy steps.
CPU_LIMIT="${CPU_LIMIT:-4}"
DIND_CPU_LIMIT="${DIND_CPU_LIMIT:-4}"
# Extra dockerd registry mirrors, highest priority first (space-separated). The
# built-in https://mirror.gcr.io is always appended last.
REGISTRY_MIRRORS="${REGISTRY_MIRRORS:-}"
# Pinned: unpinned, a redeploy of an unchanged scale-set silently moves the pool
# to whatever ARC released since. Must match the controller version setup.sh
# installs — the listener image comes from the controller, the runner spec from
# this chart, and ARC does not support them drifting apart.
CHART_VERSION="${CHART_VERSION:-0.14.2}"

# Namespace defaults to the lowercased org, but the two are not the same fact:
# `githubConfigUrl` must carry the org exactly as GitHub spells it, while the
# namespace is whatever the pool was first created under. bld1 runs the Miraj-OS
# pool in `arc-miraj`, not the `arc-miraj-os` this default would derive — deploy
# it without the override and you get a second, parallel scale-set long-polling
# the same org for the same `runs-on` label instead of an upgrade of the first.
NAMESPACE="${NAMESPACE:-}"
NS="${NAMESPACE:-arc-$(echo "$ORG" | tr '[:upper:]' '[:lower:]')}"
# Same story for the Helm release name: it defaults to the scale-set name, but
# the two are independent and on bld1 they differ — the Miraj-OS pool is the
# release `miraj-self-hosted` serving `runs-on: self-hosted`. Get it wrong and
# helm refuses outright ("cannot be imported into the current release"), which
# is the pleasant failure; the namespace one above fails silently.
RELEASE="${RELEASE:-$NAME}"
# PriorityClass for the runner pods (manifests/runner-priority-classes.yaml).
# When the node is full, the scheduler places a higher-priority pending pod
# first. The classes use preemptionPolicy: Never, so a running job is never evicted.
PRIORITY_CLASS="${PRIORITY_CLASS:-}"
# DIND=false — runner without the dind sidecar, for jobs that never call docker
# (API calls, git, curl, node/flutter checks). A dind pod reserves runner + dind
# requests and pays the externals init copy on start; on 2026-10-01 and 10-05 such
# jobs sat Pending on "Insufficient memory" next to real builds.
DIND="${DIND:-true}"
# DIND_EXTERNALS=false — no init copy of the runner externals into the dind
# sidecar. They exist only for `container:` jobs and docker-based actions; a pool
# whose org uses neither (izi-x: none of its 22 actions is docker-based) pays
# ~0.6 GB of writes per pod start for nothing.
DIND_EXTERNALS="${DIND_EXTERNALS:-true}"
# CI_HOST_CACHE=true — mount the node-local tool cache and dependency caches
# (scripts/install-ci-host-cache.sh) into the runner container.
CI_HOST_CACHE="${CI_HOST_CACHE:-false}"
# CACHE_TIER=pr|trusted — which copy of the node caches the pool mounts
# (/opt/ci-tier/<tier>: toolcache at /opt/hostedtoolcache, dependency and test caches
# at /ci-cache). PR code runs as the same uid as main/release jobs, so a shared copy
# would let it replace the node/flutter binaries, pub packages or generated code that
# trusted builds execute — the same line the two buildkitd draw. Required with
# CI_HOST_CACHE=true and with CONTAINER_MODE.
CACHE_TIER="${CACHE_TIER:-}"
# CONTAINER_MODE=kubernetes-novolume — jobs with `container:`/`services:` run as a pod of
# their own that the runner creates through the API (ARC container hooks), with images
# from the node's containerd: they stay cached between jobs, where a dind sidecar pulled
# and unpacked them into an empty store every time. Every job on such a pool must declare
# `container:`. The job pod gets the pool's CPU/memory requests and limits through a hook
# template; services get the namespace LimitRange defaults
# (manifests/limitrange-arc-izi-x.yaml).
CONTAINER_MODE="${CONTAINER_MODE:-none}"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

for flag in DIND DIND_EXTERNALS CI_HOST_CACHE; do
  case "${!flag}" in true|false) ;; *) echo "$flag must be true or false, got: ${!flag}" >&2; exit 1 ;; esac
done
if [ "$CI_HOST_CACHE" = "true" ] || [ "$CONTAINER_MODE" != "none" ]; then
  case "$CACHE_TIER" in pr|trusted) ;; *) echo "CACHE_TIER must be pr or trusted, got: '$CACHE_TIER'" >&2; exit 1 ;; esac
fi
case "$CONTAINER_MODE" in
  none) ;;
  kubernetes-novolume)
    [ "$DIND" = "false" ] || { echo "CONTAINER_MODE=$CONTAINER_MODE needs DIND=false" >&2; exit 1; } ;;
  *) echo "CONTAINER_MODE must be none or kubernetes-novolume, got: $CONTAINER_MODE" >&2; exit 1 ;;
esac
# A runner pod naming a missing PriorityClass is rejected (Forbidden); ARC 0.14 marks
# the runner Failed and counts it toward maxRunners for good — the pool dies with
# nothing red anywhere. Refuse to deploy instead.
[ -z "$PRIORITY_CLASS" ] || kubectl get priorityclass "$PRIORITY_CLASS" >/dev/null

PRIV_KEY=$(cat "$PRIVATE_KEY_FILE")

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# apply, not delete+create: every pool in the namespace reads this one secret, and
# a create that fails after the delete (apiserver timeouts under load, 2026-09-24)
# would leave all of them unable to create runners, with nothing red anywhere.
kubectl -n "$NS" create secret generic github-app \
  --from-literal=github_app_id="$APP_ID" \
  --from-literal=github_app_installation_id="$INSTALL_ID" \
  --from-literal=github_app_private_key="$PRIV_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Build a full-spec overlay so helm never has to construct partial array
# elements (--set containers[0].x replaces the entire element, losing
# name/image/command/etc. and producing an invalid AutoscalingRunnerSet).
OVERLAY=$(mktemp /tmp/arc-overlay-XXXXXX.yaml)
trap 'rm -f "$OVERLAY"' EXIT

MIRROR_ARGS=""
for mirror in $REGISTRY_MIRRORS https://mirror.gcr.io; do
  MIRROR_ARGS+="
      - --registry-mirror=$mirror"
done

cat > "$OVERLAY" << YAML
minRunners: $MIN
maxRunners: $MAX
listenerTemplate:
  spec:
    priorityClassName: ci-infra
    # The listener is the only thing that can accept a job from GitHub, and on a
    # single-node cluster there is nowhere to reschedule it — the default 300s
    # NoExecute tolerations only guarantee that a node blip takes the pool
    # offline. bld1 on 2026-09-24: the node flapped NotReady under CI load, the
    # taint manager evicted both listener pods, and the pool then sat without a
    # listener for 42 minutes while jobs queued with no red check anywhere.
    tolerations:
    - { key: node.kubernetes.io/not-ready,   operator: Exists, effect: NoExecute }
    - { key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute }
    containers:
    # Requests, so the listener is not BestEffort: that QoS class is what the
    # kernel OOM killer reaches for first, and it is exactly the pod whose death
    # is invisible. Measured usage is 3m CPU / 10Mi.
    - name: listener
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits: { memory: 256Mi }
YAML

# Runner-container fragments for CI_HOST_CACHE, spliced into both pod templates.
CACHE_ENV=""; CACHE_MOUNTS=""; CACHE_VOLUMES=""
if [ "$CI_HOST_CACHE" = "true" ]; then
CACHE_ENV="
      - { name: RUNNER_TOOL_CACHE, value: /opt/hostedtoolcache }
      - { name: npm_config_cache,  value: /ci-cache/npm }
      - { name: PUB_CACHE,         value: /ci-cache/pub }"
CACHE_MOUNTS="
      - { mountPath: /opt/hostedtoolcache, name: toolcache }
      - { mountPath: /ci-cache,            name: ci-cache }"
CACHE_VOLUMES="
    - { name: toolcache, hostPath: { path: /opt/ci-tier/$CACHE_TIER/toolcache, type: Directory } }
    - { name: ci-cache,  hostPath: { path: /opt/ci-tier/$CACHE_TIER/cache,     type: Directory } }"
fi
EXTERNALS_INIT=""; EXTERNALS_MOUNT=""; EXTERNALS_VOLUME=""
if [ "$DIND_EXTERNALS" = "true" ]; then
EXTERNALS_INIT="
    initContainers:
    - name: init-dind-externals
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: [cp, -r, /home/runner/externals/., /home/runner/tmpDir/]
      volumeMounts:
      - { mountPath: /home/runner/tmpDir, name: dind-externals }"
EXTERNALS_MOUNT="
      - { mountPath: /home/runner/externals, name: dind-externals }"
EXTERNALS_VOLUME="
    - { name: dind-externals, emptyDir: { sizeLimit: 1Gi   } }"
fi

HOOK_ENV=""; HOOK_MOUNT=""; HOOK_VOLUME=""
if [ "$CONTAINER_MODE" != "none" ]; then
# The job pod's spec: the hooks merge it into the pod they create (`$job` = the job
# container) — its limits and its node cache. Job images run as root, so their cache is
# a tree of its own (/opt/ci-tier/<tier>-containers): root-owned entries in the
# runner-uid trees would lock those jobs out of them.
# Job images are referenced by mutable tags (izi-x e2e: `e2e-tests:dev`); without a
# policy Kubernetes takes IfNotPresent and the node runs whatever it pulled first —
# e2e kept the image without its spec cache for a day after it was rebuilt. Always
# only resolves the tag's digest against the registry; unchanged layers stay in containerd.
kubectl -n "$NS" create configmap "$RELEASE-hook-template" \
  --from-literal=template.yaml="spec:${PRIORITY_CLASS:+
  priorityClassName: $PRIORITY_CLASS}
  containers:
    - name: \$job
      imagePullPolicy: Always
      resources:
        requests: { cpu: \"$CPU_REQUEST\", memory: $MEM_REQUEST }
        limits: { cpu: \"$CPU_LIMIT\", memory: $MEM_LIMIT }
      env:
        - { name: npm_config_cache, value: /ci-cache/npm }
      volumeMounts:
        - { mountPath: /ci-cache, name: ci-cache-containers }
  volumes:
    - { name: ci-cache-containers, hostPath: { path: /opt/ci-tier/$CACHE_TIER-containers, type: Directory } }
" --dry-run=client -o yaml | kubectl apply -f -
cat >> "$OVERLAY" << YAML
containerMode:
  type: $CONTAINER_MODE
YAML
# The runner container only drives the hooks; the job's resources above belong to the job pod.
CPU_REQUEST=100m MEM_REQUEST=256Mi CPU_LIMIT=1 MEM_LIMIT=1Gi
HOOK_ENV="
      - { name: ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE, value: /home/runner/hook-template/template.yaml }"
HOOK_MOUNT="
      - { mountPath: /home/runner/hook-template, name: hook-template }"
HOOK_VOLUME="
    - { name: hook-template, configMap: { name: $RELEASE-hook-template } }"
fi

RUNNER_ENV="$CACHE_ENV$HOOK_ENV"
if [ "$DIND" = "false" ]; then
cat >> "$OVERLAY" << YAML
template:
  spec:${PRIORITY_CLASS:+
    priorityClassName: $PRIORITY_CLASS}
    imagePullSecrets:
    - name: ghcr-pull
    containers:
    - name: runner
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: [/home/runner/run.sh]
      env:${RUNNER_ENV:- []}
      resources:
        requests:
          cpu: "$CPU_REQUEST"
          memory: $MEM_REQUEST
        limits:
          cpu: "$CPU_LIMIT"
          memory: $MEM_LIMIT
      volumeMounts:
      - { mountPath: /home/runner/_work, name: work }$CACHE_MOUNTS$HOOK_MOUNT
    volumes:
    - { name: work, emptyDir: { sizeLimit: ${WORK_SIZE:-4Gi} } }$CACHE_VOLUMES$HOOK_VOLUME
YAML
else
cat >> "$OVERLAY" << YAML
template:
  spec:${PRIORITY_CLASS:+
    priorityClassName: $PRIORITY_CLASS}
    imagePullSecrets:
    - name: ghcr-pull$EXTERNALS_INIT
    containers:
    - name: runner
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command:
      - /bin/bash
      - -c
      - until /usr/bin/docker info >/dev/null 2>&1; do sleep 1; done; exec /home/runner/run.sh
      env:
      - { name: DOCKER_HOST, value: unix:///var/run/docker.sock }$CACHE_ENV
      resources:
        requests:
          cpu: "$CPU_REQUEST"
          memory: $MEM_REQUEST
        limits:
          cpu: "$CPU_LIMIT"
          memory: $MEM_LIMIT
      volumeMounts:
      - { mountPath: /home/runner/_work, name: work }
      - { mountPath: /var/run, name: dind-sock }$CACHE_MOUNTS
    - name: dind
      image: mirror.gcr.io/library/docker:dind
      imagePullPolicy: IfNotPresent
      args:
      - dockerd
      - --host=unix:///var/run/docker.sock
      - --group=123$MIRROR_ARGS
      securityContext:
        privileged: true
      resources:
        requests:
          cpu: "$DIND_CPU_REQUEST"
          memory: $DIND_MEM_REQUEST
        limits:
          cpu: "$DIND_CPU_LIMIT"
          memory: $DIND_MEM_LIMIT
      volumeMounts:
      - { mountPath: /home/runner/_work, name: work }
      - { mountPath: /var/run, name: dind-sock }$EXTERNALS_MOUNT
    volumes:
    # work and dind-externals are node disk, not tmpfs. medium: Memory makes the
    # volume RAM the scheduler cannot see — emptyDir does not enter a pod's
    # memory request, and sizeLimit is per volume, so maxRunners: 20 promised
    # 320 GiB of tmpfs on a 62 GiB box. bld1 held 33.8 GiB of RAM in 72 such
    # volumes on 2026-09-24 while its disk sat 31% used; tmpfs pages can only
    # leave RAM through swap, which is what put the node into thrash and took
    # k3s down with it. The job tree belongs on the disk that has 134 GiB free.
    - { name: work,           emptyDir: { sizeLimit: 16Gi  } }
    - { name: dind-sock,      emptyDir: { medium: Memory, sizeLimit: 256Mi } }$EXTERNALS_VOLUME$CACHE_VOLUMES
YAML
fi

helm upgrade --install "$RELEASE" \
  --namespace "$NS" \
  --set githubConfigUrl="https://github.com/$ORG" \
  --set githubConfigSecret=github-app \
  --set "runnerScaleSetName=$NAME" \
  -f "$OVERLAY" \
  --version "$CHART_VERSION" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

kubectl -n "$NS" get autoscalingrunnerset
