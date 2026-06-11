#!/usr/bin/env bash
# Deploy one ARC scale-set (= one Helm release).
#
# Usage:
#   APP_ID=… PRIVATE_KEY_FILE=path INSTALL_ID=… ORG=… NAME=… [IMAGE=…] [MAX=…] \
#     scripts/deploy-scale-set.sh
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
: "${PRIVATE_KEY_FILE:?PRIVATE_KEY_FILE required — path to App's PEM file}"
IMAGE="${IMAGE:-ghcr.io/jakwuh/actions-runner:latest}"
MAX="${MAX:-8}"
MIN="${MIN:-1}"
# Per-runner CPU/memory requests (no limits → burstable). These bound the
# scheduler so it never overpacks dind pods — without them every pod is
# "weightless" → CPU contention → dind's managed containerd misses its 15s
# startup window → dind exits 1, runner hangs Running (1/2 Error forever),
# build times climb. Sized from p90 of live builds (runner 1.6 cores / 0.9Gi).
CPU_REQUEST="${CPU_REQUEST:-1}"
MEM_REQUEST="${MEM_REQUEST:-1.5Gi}"

NS="arc-$(echo "$ORG" | tr '[:upper:]' '[:lower:]')"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PRIV_KEY=$(cat "$PRIVATE_KEY_FILE")

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" delete secret github-app --ignore-not-found
kubectl -n "$NS" create secret generic github-app \
  --from-literal=github_app_id="$APP_ID" \
  --from-literal=github_app_installation_id="$INSTALL_ID" \
  --from-literal=github_app_private_key="$PRIV_KEY"

# Build a full-spec overlay so helm never has to construct partial array
# elements (--set containers[0].x replaces the entire element, losing
# name/image/command/etc. and producing an invalid AutoscalingRunnerSet).
OVERLAY=$(mktemp /tmp/arc-overlay-XXXXXX.yaml)
trap "rm -f $OVERLAY" EXIT

cat > "$OVERLAY" << YAML
minRunners: $MIN
maxRunners: $MAX
template:
  spec:
    imagePullSecrets:
    - name: ghcr-pull
    initContainers:
    - name: init-dind-externals
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: [cp, -r, /home/runner/externals/., /home/runner/tmpDir/]
      volumeMounts:
      - { mountPath: /home/runner/tmpDir, name: dind-externals }
    containers:
    - name: runner
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command:
      - /bin/bash
      - -c
      - until /usr/bin/docker info >/dev/null 2>&1; do sleep 1; done; exec /home/runner/run.sh
      env:
      - { name: DOCKER_HOST, value: unix:///var/run/docker.sock }
      resources:
        requests:
          cpu: "$CPU_REQUEST"
          memory: $MEM_REQUEST
      volumeMounts:
      - { mountPath: /home/runner/_work, name: work }
      - { mountPath: /var/run, name: dind-sock }
    - name: dind
      image: mirror.gcr.io/library/docker:dind
      imagePullPolicy: IfNotPresent
      args:
      - dockerd
      - --host=unix:///var/run/docker.sock
      - --group=123
      - --registry-mirror=https://mirror.gcr.io
      securityContext:
        privileged: true
      volumeMounts:
      - { mountPath: /home/runner/_work, name: work }
      - { mountPath: /var/run, name: dind-sock }
      - { mountPath: /home/runner/externals, name: dind-externals }
    volumes:
    - { name: work,           emptyDir: { medium: Memory, sizeLimit: 16Gi  } }
    - { name: dind-sock,      emptyDir: { medium: Memory, sizeLimit: 256Mi } }
    - { name: dind-externals, emptyDir: { medium: Memory, sizeLimit: 1Gi   } }
YAML

helm upgrade --install "$NAME" \
  --namespace "$NS" \
  --set githubConfigUrl="https://github.com/$ORG" \
  --set githubConfigSecret=github-app \
  --set "runnerScaleSetName=$NAME" \
  -f "$OVERLAY" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

kubectl -n "$NS" get autoscalingrunnerset
