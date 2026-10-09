#!/usr/bin/env bash
# Bootstrap a fresh single-node host:
#   1. k3s (lightweight Kubernetes, single-node)
#   2. firewall (the box is meant to be reachable over the tailnet only)
#   3. Helm + the ARC controller in namespace `arc-systems`
#   4. the janitors/watchdogs that keep the pool alive, and the node-local CI caches
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
# arm64 image builds (prod-sa) on the persistent buildkitd: qemu-user-static registers
# the binfmt handlers with the F flag through systemd-binfmt, so they survive a reboot —
# the setup-qemu-action registration did not, and cost every job 150–270 s.
apt-get install -y -qq qemu-user-static

echo "=== Kernel and disk ==="
# Kernel 6.8 (the 24.04 GA kernel) ran into a cgroup writeback storm under CI load on
# 2026-10-08: 620–1900 inode_switch_wbs kworkers, load up to 785, processes stuck in D
# state. The HWE kernel (7.0, fix of CVE-2026-64378) does not; the meta package keeps it
# updated. --no-install-recommends: the recommends drag in firmware this VM has no use for.
# Takes effect after a reboot.
apt-get install -y -qq --no-install-recommends linux-generic-hwe-24.04
# The cloud image mounts / with `discard`: every deleted block is trimmed synchronously,
# and CI deletes all the time (work dirs, node_modules, buildkit snapshots). On
# 2026-10-08 that was 4852 discards/s (155 MB/s) at 89% disk util. Trim in one batch a
# day instead.
sed -i 's#^\(LABEL=cloudimg-rootfs\s\+/\s\+ext4\s\+\)discard,#\1#' /etc/fstab
mount -o remount,nodiscard /
mkdir -p /etc/systemd/system/fstrim.timer.d
cat > /etc/systemd/system/fstrim.timer.d/daily.conf << 'UNIT'
[Timer]
OnCalendar=
OnCalendar=daily
RandomizedDelaySec=1h
UNIT
systemctl daemon-reload
systemctl enable --now fstrim.timer

echo "=== k3s (single-node Kubernetes) ==="
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=servicelb --write-kubeconfig-mode=644" sh -
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "=== containerd: volatile overlay mounts ==="
# overlayfs syncs the upper filesystem when a container's rootfs is unmounted. On the one
# CI disk that sync waits for everyone's writeback: on 2026-10-08 container stops hung for
# minutes with shim threads in sync_inodes_sb / wb_wait_for_completion, and every pool
# listener sat in Terminating until force-deleted. CI rootfs is disposable, so skip the sync
# (overlayfs `volatile`, kernel ≥ 5.10; containerd overlayfs `mount_options`). After a host
# crash a volatile upperdir is refused on remount — containers then get fresh snapshots.
install -d /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
cat > /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/overlay-volatile.toml << 'TOML'
[plugins.'io.containerd.snapshotter.v1.overlayfs']
  mount_options = ["volatile"]
TOML
systemctl restart k3s
kubectl wait --for=condition=Ready node --all --timeout=180s

echo "=== Control-plane reservation ==="
# k3s — apiserver, kine and kubelet in one process — shares this box with the
# builds, and out of the box nothing is held back for it. Under CI load on
# 2026-09-24 the builds won: kine answered in 18–83 s, the apiserver returned
# `Handler timeout`, kubelet reported `PLEG is not healthy` and missed its node
# lease, the node flapped NotReady, and the taint manager evicted the ARC
# listeners. The pool went dead with jobs queuing and no red check anywhere.
#
# Sized from measurement on bld1, not from a rule of thumb: the k3s service
# holds 1.94 GiB and pins about a core under reconcile churn; containerd,
# tailscaled, sshd and journald together come to ~0.35 GiB. The eviction
# threshold is what makes kubelet kill a runner pod before the kernel OOM killer
# starts choosing for it — on 2026-09-24 its choice was the ARC controller.
install -d /etc/rancher/k3s
RESERVATION=$(cat <<'YAML'
# Managed by build-server setup.sh — see the reservation block there.
kubelet-arg:
  - "kube-reserved=cpu=2000m,memory=3Gi"
  - "system-reserved=cpu=500m,memory=1Gi"
  - "eviction-hard=memory.available<1Gi,nodefs.available<10%"
YAML
)
if [[ "$(cat /etc/rancher/k3s/config.yaml 2>/dev/null)" != "$RESERVATION" ]]; then
  printf '%s\n' "$RESERVATION" > /etc/rancher/k3s/config.yaml
  systemctl restart k3s
  kubectl wait --for=condition=Ready node --all --timeout=180s
fi
kubectl get node -o jsonpath='{range .items[*]}{.metadata.name}{" allocatable cpu="}{.status.allocatable.cpu}{" mem="}{.status.allocatable.memory}{"\n"}{end}'

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
# The chart ships `resources: {}`, which lands the controller in BestEffort —
# the QoS class the kernel OOM killer empties first. On 2026-09-24 that is
# exactly what happened (exit 137), and with the controller gone no listener is
# recreated, so the pools stay dead. Measured usage is 16m CPU / 43Mi.
# The NoExecute tolerations are unbounded on purpose: this is a single-node
# cluster, so evicting the controller can only mean "nowhere", never "elsewhere".
# Pinned, and the same version scripts/deploy-scale-set.sh pins: the listener
# image comes from the controller chart and the runner spec from the scale-set
# chart, and ARC does not support the two drifting apart. Unpinned, rebuilding
# the box would silently install whatever ARC has released since.
ARC_VERSION="${ARC_VERSION:-0.14.2}"
helm upgrade --install arc \
  --namespace arc-systems --create-namespace \
  --set-json 'resources={"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"memory":"512Mi"}}' \
  --set-json 'tolerations=[{"key":"node.kubernetes.io/not-ready","operator":"Exists","effect":"NoExecute"},{"key":"node.kubernetes.io/unreachable","operator":"Exists","effect":"NoExecute"}]' \
  --version "$ARC_VERSION" \
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
# ci-cache-prune: the shared dependency caches below grow with every new package
# version; files nobody read for 14 days go.
curl -fsSL "$RAW/systemd/ci-cache-prune.service" -o /etc/systemd/system/ci-cache-prune.service
curl -fsSL "$RAW/systemd/ci-cache-prune.timer" -o /etc/systemd/system/ci-cache-prune.timer
# Tier isolation: optional PR pods run in the idle CPU/IO tier (scripts/ci-tier-weights.sh);
# iocost needs /etc/iocost.model, measured once on this disk (README, "Tier isolation").
curl -fsSL "$RAW/scripts/ci-tier-weights.sh" -o /opt/build-server/ci-tier-weights.sh
chmod +x /opt/build-server/ci-tier-weights.sh
curl -fsSL "$RAW/systemd/ci-tier-weights.service" -o /etc/systemd/system/ci-tier-weights.service
curl -fsSL "$RAW/systemd/iocost.service" -o /etc/systemd/system/iocost.service
systemctl daemon-reload
systemctl enable --now arc-watchdog.timer arc-runner-janitor.timer arc-prune.timer ci-cache-prune.timer
systemctl enable --now iocost.service ci-tier-weights.service

echo "=== CI host cache ==="
# Tool cache and dependency caches the pools mount with CI_HOST_CACHE=true; a pool
# deployed with it before this runs fails to start its pods (hostPath type Directory).
curl -fsSL "$RAW/scripts/install-ci-host-cache.sh" -o /opt/build-server/install-ci-host-cache.sh
chmod +x /opt/build-server/install-ci-host-cache.sh
/opt/build-server/install-ci-host-cache.sh

echo "=== In-cluster helpers ==="
# Pull-through registry cache (docker.io/ghcr rate limits + cold-pull latency)
# and the shared buildkitd the miraj scale-set builds against. These used to be
# applied by hand, which is why a rebuilt box came up subtly slower.
kubectl apply -f "$RAW/manifests/registry-cache.yaml"
kubectl apply -f "$RAW/manifests/registry-ghcr-cache.yaml"
kubectl apply -f "$RAW/manifests/buildkitd-arc-miraj.yaml"
kubectl apply -f "$RAW/manifests/buildkitd-arc-izi-x.yaml"
kubectl apply -f "$RAW/manifests/buildkitd-trusted-arc-izi-x.yaml"
kubectl apply -f "$RAW/manifests/limitrange-arc-izi-x.yaml"
# Runner pod priorities — a pool deployed with PRIORITY_CLASS dies silently without them.
kubectl apply -f "$RAW/manifests/runner-priority-classes.yaml"

echo
echo "ARC installed. Deploy scale-sets with: scripts/deploy-scale-set.sh"
echo "Self-heal announces repairs to Telegram if you drop a bot token in"
echo "/etc/arc-watchdog/tg-token and TG_CHAT=... in /etc/arc-watchdog/config."
