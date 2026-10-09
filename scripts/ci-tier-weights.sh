#!/usr/bin/env bash
# CPU and disk priority between izi-x CI tiers on one node.
#
# PriorityClasses only order the Pending queue (preemptionPolicy: Never): once running, an
# optional PR job and a release build share CPU by their requests and the disk equally
# (io.weight 100 for everyone). This puts every optional PR pod — the pr-small, pr-heavy
# and pr-k8s pools and their -workflow pods, which carry no PriorityClass, and the PR
# buildkitd — into the idle tier on its pod cgroup:
#
#   CPUWeight=idle  cpu.idle 1, SCHED_IDLE for the group: it runs only on CPU no sibling wants.
#   IOWeight=1      io.weight 1, the smallest iocost share (others keep 100); iocost is
#                   work-conserving, so with no contention the idle tier still gets the disk.
#
# The kubelet writes a pod cgroup's resources only when it creates it
# (pod_container_manager_linux.go EnsureExists). With the systemd cgroup driver the pod
# cgroup is a systemd slice, and systemd re-applies its own properties to it whenever a
# container scope starts under it — a value written to the cgroup file is reset. The tier
# is therefore set as the slice's systemd properties (CPUWeight=idle is cpu.idle, IOWeight
# is io.weight), which systemd then keeps. iocost itself is enabled by iocost.service.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NS=arc-izi-x

log() { echo "$(date -u +%FT%TZ) $*"; }

idle_tier() {  # <pod name> <priorityClassName>
  # The PR buildkitd runs at ci-infra so it is never Pending behind jobs, but the builds
  # it runs are PR builds.
  case "$1" in buildkitd-trusted-*) return 1 ;; buildkitd-*) return 0 ;; esac
  case "$2" in ci-release|ci-main|ci-pr-required|ci-infra) return 1 ;; esac
  case "$1" in izi-x-pr-*) return 0 ;; esac
  return 1
}

declare -A done
k3s kubectl -n "$NS" get pods --watch --output-watch-events \
  -o jsonpath='{.object.metadata.uid} {.object.metadata.name} {.object.spec.priorityClassName}{"\n"}' |
while read -r uid name pc; do
  [ -n "$uid" ] && [ -z "${done[$uid]:-}" ] || continue
  idle_tier "$name" "${pc:-}" || { done[$uid]=skip; continue; }
  cg=$(ls -d /sys/fs/cgroup/kubepods.slice/kubepods-pod"${uid//-/_}".slice \
             /sys/fs/cgroup/kubepods.slice/kubepods-*.slice/kubepods-*-pod"${uid//-/_}".slice 2>/dev/null | head -1)
  # The cgroup appears when the pod is admitted; a later watch event of the same pod retries.
  [ -n "$cg" ] || continue
  if systemctl set-property --runtime "$(basename "$cg")" CPUWeight=idle IOWeight=1; then
    done[$uid]=idle
    log "idle tier: $name"
  else
    log "could not set idle tier on $name ($cg)"
  fi
done
