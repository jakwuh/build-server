#!/usr/bin/env bash
# Reaps ARC runner pods whose dind sidecar died while the runner container
# stayed alive.
#
# Why: such a pod sits at 1/2 Error forever. It takes no work but still holds
# its CPU/memory requests. A handful of them and the node hits its requests
# ceiling; the next dind's managed containerd then misses its startup window,
# exits 1, and produces another zombie — the loop closes. That is exactly how
# CI stalled on 2026-08-06 after a bld1 reboot: 23 queued runs against a pool
# that looked healthy.
#
# Deleting the pod is safe: ARC recreates it and GitHub re-assigns the job.
#
# Covers every arc-* namespace, not just one — both scale sets live on this box
# and either can produce the zombie.
set -uo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="${KUBECTL:-/usr/local/bin/kubectl}"

namespaces=$("$KUBECTL" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^arc-' | grep -v '^arc-systems$')
[ -n "$namespaces" ] || { echo "no arc-* runner namespaces found (cluster unreachable?)" >&2; exit 0; }

for ns in $namespaces; do
  stuck=$("$KUBECTL" -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 == "Error" { print $1 }')
  [ -n "$stuck" ] || continue
  echo "$ns: $(echo "$stuck" | wc -w) stuck runner(s), deleting: $stuck"
  # shellcheck disable=SC2086 # word splitting is the point — one pod per arg
  "$KUBECTL" -n "$ns" delete pod $stuck --wait=false
done
