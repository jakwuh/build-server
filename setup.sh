#!/usr/bin/env bash
# Bootstrap a fresh single-node host:
#   1. k3s (lightweight Kubernetes, single-node)
#   2. firewall (the box is meant to be reachable over the tailnet only)
#   3. Helm + the ARC controller in namespace `arc-systems`
#   4. the janitors/watchdogs that keep the pool alive
#   5. the in-cluster helpers (pull-through registry cache, buildkitd)
#
# After this finishes, run scripts/deploy-scale-set.sh for each scale-set you
# need. What this script canNOT do for you is listed under "Not in this repo"
# in the README — read it before assuming a fresh box is complete.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."; exit 1
fi

echo "=== System packages ==="
apt-get update -qq
apt-get install -y -qq curl git jq ufw

echo "=== k3s (single-node Kubernetes) ==="
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== Firewall ==="
# k3s binds the kube API on :6443 and the kubelet on :10250 to 0.0.0.0, and
# sshd sits on :22 — on a public-IP box all three would face the internet.
# This host is meant to be reachable over the tailnet only, and the firewall
# is the thing that actually enforces it. Everything else here is a workaround
# for one k3s requirement: pod traffic is *routed*, not delivered locally.
#
# DEFAULT_FORWARD_POLICY must be ACCEPT. ufw's default DROP silently kills pod
# networking — runners go offline with no obvious cause (seen for real on
# 2026-08-06).
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force default deny incoming
ufw --force default allow outgoing
ufw --force default allow routed
ufw allow in on tailscale0 comment 'tailnet interface'
ufw allow from 100.64.0.0/10 comment 'tailnet'
ufw allow from 10.42.0.0/16 comment 'k3s pods'
ufw allow from 10.43.0.0/16 comment 'k3s services'
ufw --force enable
ufw status verbose | head -12

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

echo "=== Janitors and watchdogs ==="
# arc-watchdog: a wedged controller, or a listener pointing at a deleted
#   EphemeralRunnerSet, leaves every pool dead with zero red checks anywhere —
#   jobs just queue.
# arc-runner-janitor: a pod whose dind died holds its CPU requests forever and
#   starves the next dind into the same state.
# Both failure modes are silent by construction; see each script's header.
for j in arc-watchdog arc-runner-janitor; do
  curl -fsSL "$RAW/scripts/$j.sh" -o "/opt/build-server/$j.sh"
  chmod +x "/opt/build-server/$j.sh"
  curl -fsSL "$RAW/systemd/$j.service" -o "/etc/systemd/system/$j.service"
  curl -fsSL "$RAW/systemd/$j.timer" -o "/etc/systemd/system/$j.timer"
done
# arc-prune: runner images land in containerd and never leave on their own; a
# build box fills its disk in weeks without this.
curl -fsSL "$RAW/systemd/arc-prune.service" -o /etc/systemd/system/arc-prune.service
curl -fsSL "$RAW/systemd/arc-prune.timer" -o /etc/systemd/system/arc-prune.timer
systemctl daemon-reload
systemctl enable --now arc-watchdog.timer arc-runner-janitor.timer arc-prune.timer

echo "=== In-cluster helpers ==="
# Pull-through registry cache (docker.io/ghcr rate limits + cold-pull latency)
# and the shared buildkitd the miraj scale-set builds against. These used to be
# applied by hand, which is why a rebuilt box came up subtly slower.
kubectl apply -f "$RAW/manifests/registry-cache.yaml"
kubectl apply -f "$RAW/manifests/buildkitd-arc-miraj.yaml"

echo
echo "ARC installed. Deploy scale-sets with: scripts/deploy-scale-set.sh"
echo "Self-heal announces repairs to Telegram if you drop a bot token in"
echo "/etc/arc-watchdog/tg-token and TG_CHAT=... in /etc/arc-watchdog/config."
