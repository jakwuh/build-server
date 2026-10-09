#!/usr/bin/env bash
# Node-local tool cache and dependency caches shared by the runner pods.
#
# Every job used to start in an empty pod and rebuild the same things on the one
# VPS disk: setup-node downloaded Node, subosito downloaded the Flutter SDK, pub
# and npm pulled their packages from the GitHub cache over the internet. On bld1
# that was 6.7% (setup-node) and 9.1% (Flutter) of all runner pod-minutes over
# 2026-10-05..07, and the disk sat at its ~1.5k writes/s ceiling.
#
# The runner takes its tool cache from RUNNER_TOOL_CACHE (actions/runner
# HostContext.cs); setup-node looks there first (tc.find → <tool>/<ver>/<arch> +
# <arch>.complete) and subosito skips the download when
# <cache>/flutter/stable-<ver>-x64/flutter/bin/flutter exists. A version that is
# not preinstalled here is downloaded once by the first job and kept.
#
# npm (cacache: lockless, verified on read) and pub (download to a temp dir, then
# rename) are safe to share between concurrent pods. So is the Dart analyzer
# result cache (FileByteStore: temp file + rename); the analyzer plugin directory
# is not — it is recompiled in place on every start — and stays per pod.
#
#   install-ci-host-cache.sh [NODE_VERSION] [FLUTTER_VERSION]
set -euo pipefail

NODE_VERSION="${1:-24.21.0}"
FLUTTER_VERSION="${2:-3.44.2}"
# uid/gid of `runner` in ghcr.io/actions/actions-runner.
RUNNER_UID=1001

# One copy per trust tier (deploy-scale-set.sh CACHE_TIER): PR jobs never write what
# main/release jobs execute. <tier>/toolcache is the pods' /opt/hostedtoolcache,
# <tier>/cache their /ci-cache; <tier>-containers is the /ci-cache of `container:` jobs,
# which run as root.
for tier in pr trusted; do
  root=/opt/ci-tier/$tier
  toolcache=$root/toolcache
  node_dir=$toolcache/node/$NODE_VERSION/x64
  flutter_dir=$toolcache/flutter/stable-$FLUTTER_VERSION-x64
  install -d -o "$RUNNER_UID" -g "$RUNNER_UID"     "$root" "$toolcache" "$node_dir" "$flutter_dir"     "$root/cache" "$root/cache/npm" "$root/cache/pub" "$root/cache/dart-analysis-driver"     "$root/cache/vitest-crm" "$root/cache/jest-api" "$root/cache/build-runner" "$root/cache/node_modules"     "$root/cache/android-sdk" "$root/cache/gradle"
  install -d "/opt/ci-tier/$tier-containers" "/opt/ci-tier/$tier-containers/npm"     "/opt/ci-tier/$tier-containers/node_modules"

  if [ ! -f "$node_dir.complete" ]; then
    curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz"       | tar -xJ --strip-components=1 -C "$node_dir"
    touch "$node_dir.complete"
  fi
  if [ ! -x "$flutter_dir/flutter/bin/flutter" ]; then
    curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"       | tar -xJ -C "$flutter_dir"
  fi
  chown -R "$RUNNER_UID:$RUNNER_UID" "$toolcache"
  # The Android build used to install its SDK and every Gradle dependency into an empty
  # pod — 12.8 GB of disk writes per APK (bld1, 2026-10-08). The job installs into
  # android-sdk under flock (izi-x build-mobile-widget.yml). Gradle releases its cache
  # locks when another Gradle asks over localhost, and every pod has its own, so the
  # job runs Gradle one at a time per tier under flock, and without a daemon that would
  # keep the locks after its build. The user-home properties win over the project's.
  # One JVM fits the heavy pod's 6 GiB: Gradle at -Xmx3g peaks at 3.9 GB RSS. The Kotlin
  # plugin reads its execution strategy as a Gradle property only — passed as -D in
  # jvmargs it is ignored and a KotlinCompileDaemon with its own -Xmx3g starts beside
  # Gradle (OOM, bld1 2026-10-09 03:57).
  install -m 0644 -o "$RUNNER_UID" -g "$RUNNER_UID" /dev/stdin "$root/cache/gradle/gradle.properties" << 'PROPS'
org.gradle.jvmargs=-Xmx3g
org.gradle.workers.max=4
org.gradle.daemon=false
kotlin.compiler.execution.strategy=in-process
PROPS
  # Pull the engine artifacts once, as the user the jobs run as. flutter inspects the
  # working directory for a project, so run it from one the runner user can read.
  (cd /tmp && setpriv --reuid="$RUNNER_UID" --regid="$RUNNER_UID" --clear-groups     env HOME=/tmp PUB_CACHE="$root/cache/pub" "$flutter_dir/flutter/bin/flutter" precache)
done

# The shared node_modules trees live in RAM. bld1's disk answers a read in ~7 ms and a
# write in ~14 ms under CI load (iostat, 2026-10-08); node loading a cold tree waits on
# each file, which put single jest tests at 2.4 s. A tree is ~700 MB, a tier holds a few
# (one per package-lock), RAM has ~55 GB available. tmpfs comes back empty after a
# reboot and the first job of each lock reinstalls it. A mount made here does not reach
# pods already running (hostPath has no mount propagation): they keep the disk copy.
mount_ram() {  # <dir> <size> <uid>
  grep -q " $1 tmpfs " /etc/fstab ||
    echo "tmpfs $1 tmpfs size=$2,mode=0755,uid=$3,gid=$3,noatime 0 0" >> /etc/fstab
  mountpoint -q "$1" && return 0
  mount "$1"
  # Seed the RAM copy from the disk directory it now covers: a non-recursive bind of
  # the parent shows what is under the new mount.
  local under; under=$(mktemp -d)
  mount --bind "$(dirname "$1")" "$under"
  cp -a "$under/$(basename "$1")/." "$1/"
  umount "$under"
  rmdir "$under"
}
for tier in pr trusted; do
  mount_ram "/opt/ci-tier/$tier/cache/node_modules" 8g "$RUNNER_UID"
  mount_ram "/opt/ci-tier/$tier-containers/node_modules" 4g 0
done
