#!/usr/bin/env bash
# Bootstrap a fresh single-node host:
#   1. k3s (lightweight Kubernetes, single-node)
#   2. Helm
#   3. ARC controller in namespace `arc-systems`
#
# After this finishes, run scripts/deploy-scale-set.sh for each scale-set you need.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

echo "=== System packages ==="
apt-get update -qq
apt-get install -y -qq curl git

echo "=== k3s (single-node Kubernetes) ==="
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== MSS clamp (flannel VXLAN MTU blackhole fix) ==="
# k3s flannel runs at MTU 1450 while the CI build bridges default to 1500;
# without this, bulk container egress blackholes (see mss-clamp.sh header).
RAW=https://raw.githubusercontent.com/jakwuh/build-server/main
install -d /opt/build-server
curl -fsSL "$RAW/systemd/build-server-mss-clamp.sh" -o /opt/build-server/mss-clamp.sh
chmod +x /opt/build-server/mss-clamp.sh
curl -fsSL "$RAW/systemd/build-server-mss-clamp.service" -o /etc/systemd/system/build-server-mss-clamp.service
systemctl daemon-reload
systemctl enable --now build-server-mss-clamp.service

echo "=== Helm ==="
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "=== actions-runner-controller (ARC) ==="
helm upgrade --install arc \
  --namespace arc-systems --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

echo "=== Wait for controller ==="
kubectl -n arc-systems rollout status deploy/arc-gha-rs-controller --timeout=120s

echo "=== ARC self-heal watchdog ==="
# A wedged controller or a listener pointed at a deleted EphemeralRunnerSet leaves
# every pool dead with zero red checks — jobs just queue. See arc-watchdog.sh header.
curl -fsSL "$RAW/scripts/arc-watchdog.sh" -o /opt/build-server/arc-watchdog.sh
chmod +x /opt/build-server/arc-watchdog.sh
curl -fsSL "$RAW/systemd/arc-watchdog.service" -o /etc/systemd/system/arc-watchdog.service
curl -fsSL "$RAW/systemd/arc-watchdog.timer" -o /etc/systemd/system/arc-watchdog.timer
systemctl daemon-reload
systemctl enable --now arc-watchdog.timer

echo
echo "ARC installed. Deploy scale-sets with: scripts/deploy-scale-set.sh"
echo "Self-heal announces repairs to Telegram if you drop a bot token in"
echo "/etc/arc-watchdog/tg-token and TG_CHAT=... in /etc/arc-watchdog/config."
