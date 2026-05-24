#!/usr/bin/env bash
# Deploy one ARC scale-set (= one Helm release).
#
# Usage:
#   APP_ID=… PRIVATE_KEY_FILE=path INSTALL_ID=… ORG=… NAME=… [IMAGE=…] [MAX=…] \
#     scripts/deploy-scale-set.sh
#
# Examples:
#   APP_ID=123 INSTALL_ID=456 ORG=izi-x NAME=izi-x-linux MAX=30 scripts/deploy-scale-set.sh
#   APP_ID=123 INSTALL_ID=789 ORG=Miraj-OS NAME=miraj-e2e \
#     IMAGE=ghcr.io/miraj-os/e2e-runner:1.52.0-node20 MAX=20 scripts/deploy-scale-set.sh
set -euo pipefail

: "${APP_ID:?GITHUB_APP_ID required}"
: "${INSTALL_ID:?GITHUB_APP_INSTALLATION_ID required}"
: "${ORG:?ORG required (e.g. izi-x or Miraj-OS)}"
: "${NAME:?NAME required — scale-set name, must match runs-on: label in workflows}"
: "${PRIVATE_KEY_FILE:?PRIVATE_KEY_FILE required — path to App's PEM file}"
IMAGE="${IMAGE:-ghcr.io/actions/actions-runner:latest}"
MAX="${MAX:-20}"
MIN="${MIN:-0}"

NS="arc-$(echo "$ORG" | tr '[:upper:]' '[:lower:]')"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PRIV_KEY=$(cat "$PRIVATE_KEY_FILE")

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS" delete secret github-app --ignore-not-found
kubectl -n "$NS" create secret generic github-app \
  --from-literal=github_app_id="$APP_ID" \
  --from-literal=github_app_installation_id="$INSTALL_ID" \
  --from-literal=github_app_private_key="$PRIV_KEY"

helm upgrade --install "$NAME" \
  --namespace "$NS" \
  --set githubConfigUrl="https://github.com/$ORG" \
  --set githubConfigSecret=github-app \
  --set "runnerScaleSetName=$NAME" \
  --set "minRunners=$MIN" \
  --set "maxRunners=$MAX" \
  --set "containerMode.type=dind" \
  --set "template.spec.containers[0].name=runner" \
  --set "template.spec.containers[0].image=$IMAGE" \
  --set "template.spec.containers[0].command={/home/runner/run.sh}" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

kubectl -n "$NS" get autoscalingrunnerset
