#!/usr/bin/env bash
# Clamp TCP MSS for forwarded (container-egress) traffic to fit the flannel
# VXLAN overlay MTU (1450).
#
# k3s installs flannel with MTU 1450, but the CI build bridges (dockerd's
# docker0, the ARC dind sidecar) default to 1500. The TCP handshake (small
# packets) succeeds, so a socket reaches ESTABLISHED — but bulk data at a full
# 1500-byte MSS is silently dropped on the overlay with no ICMP (a PMTU
# blackhole). Symptom: a cross-arch `RUN apk add` under QEMU opens a connection
# to the package CDN and then hangs forever in read(), 0% CPU. Native (amd64)
# builds dodge it only while the layer is cache-warm and never refetches.
#
# Clamping the MSS on every forwarded SYN caps segment size end-to-end, so no
# oversized packet is ever generated. MSS 1410 = 1450 (overlay MTU) - 40
# (IPv4 + TCP headers). Lives in the mangle/FORWARD chain, which k3s/kube-proxy
# do not rewrite, so it survives reconcile; the unit re-applies it on boot.
set -euo pipefail

MSS="${MSS:-1410}"
RULE=(-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS")

# Idempotent: drop any prior copies, then add exactly one.
while iptables -t mangle -C FORWARD "${RULE[@]}" 2>/dev/null; do
  iptables -t mangle -D FORWARD "${RULE[@]}"
done
iptables -t mangle -A FORWARD "${RULE[@]}"

echo "MSS clamp active: mangle/FORWARD TCP SYN --set-mss $MSS"
