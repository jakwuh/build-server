#!/usr/bin/env bash
# ARC self-heal — keeps every runner scale-set's listener alive.
#
# Fixes three failure modes, both observed live on 2026-08-06/07 in the wake of a
# GitHub Actions outage, which together left every self-hosted pool dead for ~12h:
#
#   1. The AutoscalingListener CR points at an EphemeralRunnerSet that no longer
#      exists. The listener pod starts, fails with
#        "could not patch ephemeral runner set ... not found"
#      exits, gets recreated with the same stale spec, and loops forever. No
#      runners are ever created. Cure: delete the listener CR — the controller
#      recreates it against the current EphemeralRunnerSet.
#
#   2. The controller itself wedges (last observed hung on "deleting runner scale
#      set", log frozen, single AutoscalingRunnerSet worker blocked) and no
#      listener exists at all. Attempted cure: rollout restart the controller.
#
#   3. The listener pod is Running and Ready but its broker long-poll never
#      returns again (after a network outage, 2026-10-08). Cure: delete the pod.
#
# All leave zero red checks anywhere — jobs just queue silently — so the repair
# is announced to Telegram when configured.
#
# The restart is not a reliable cure, and this script should not be read as one.
# On 2026-09-24 both pools had no listener from 15:31 to 16:13 UTC; seven
# restarts, one every six minutes, changed nothing. What brought them back was a
# helm upgrade that altered the runner pod template and so forced the controller
# to build a fresh EphemeralRunnerSet and listener. Until a capture below
# explains the wedge, a repeat of this alert means the repair is not working —
# it is a page, not a resolution.
#
# Config (optional), /etc/arc-watchdog/config:
#   TG_CHAT=-1001234567890          # chat to announce repairs to
# plus the bot token in /etc/arc-watchdog/tg-token (chmod 600). Without either,
# the watchdog still heals, just silently.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KC="${KC:-k3s kubectl}"
STATE=/var/lib/arc-watchdog
CONFIG=/etc/arc-watchdog/config
TG_TOKEN_FILE=/etc/arc-watchdog/tg-token
TG_CHAT=""
# One check can catch a listener mid-restart; only heal on the second strike.
STRIKES_TO_HEAL=2

# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"
mkdir -p "$STATE"

log() { echo "$(date -u +%FT%TZ) $*"; }

notify() {
  [ -n "$TG_CHAT" ] && [ -r "$TG_TOKEN_FILE" ] || return 0
  curl -fsS --max-time 15 -X POST \
    "https://api.telegram.org/bot$(cat "$TG_TOKEN_FILE")/sendMessage" \
    -d chat_id="$TG_CHAT" -d parse_mode=HTML -d disable_web_page_preview=true \
    --data-urlencode text="$1" >/dev/null || log "telegram send failed"
}

# Everything the next reader will want and cannot get afterwards. `rollout
# restart` deletes the controller pod, and with it the only log of whatever it
# was doing; /var/log/pods is garbage-collected soon after. On 2026-09-24 the
# pools sat without a listener for 42 minutes across seven of these restarts and
# the reason is now unrecoverable for exactly that reason.
capture() {
  local ns="$1" name="$2"
  local dir
  dir="$STATE/incident-$(date -u +%Y%m%dT%H%M%SZ)-${ns}_${name}"
  mkdir -p "$dir"
  $KC -n arc-systems logs deploy/arc-gha-rs-controller --tail=4000 >"$dir/controller.log" 2>&1
  $KC -n arc-systems logs -l app.kubernetes.io/component=runner-scale-set-listener \
    --tail=500 --prefix >"$dir/listeners.log" 2>&1
  $KC get autoscalingrunnerset,ephemeralrunnerset,autoscalinglistener -A -o yaml >"$dir/crs.yaml" 2>&1
  $KC get pods -A -o wide >"$dir/pods.txt" 2>&1
  $KC get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1
  log "captured evidence to $dir"
  # Keep the last 20 incidents; this lives on the build disk.
  ls -1dt "$STATE"/incident-* 2>/dev/null | tail -n +21 | xargs -r rm -rf
}

heal_one() {
  local ns="$1" name="$2"
  local key="${ns}_${name}" strikes listener ers_ref pod_ok=0 ref_ok=1

  # An unreadable API is not an absent listener. When the node is starved the
  # apiserver times out, and answering that by restarting the controller is the
  # worst possible move: a fresh controller re-LISTs every pod, secret and
  # EphemeralRunner from the datastore that is already the bottleneck. Read the
  # exit status, not just the output.
  local listeners_json
  if ! listeners_json=$($KC get autoscalinglistener -n arc-systems -o json 2>&1); then
    log "$ns/$name: cannot read AutoscalingListeners, API unavailable — no strike: ${listeners_json##*$'\n'}"
    return 0
  fi

  # Outdated is not a wedge, and no restart cures it. GitHub retires old runner
  # versions; the runner then exits 7, ARC marks the EphemeralRunner "Runner is
  # deprecated", sets the AutoscalingRunnerSet phase to Outdated and deletes the
  # listener and runner set on purpose. Only a spec change (a newer runner
  # image) brings the pool back. On 2026-09-24 this looked exactly like "no live
  # listener", and the watchdog restarted the controller every six minutes to
  # no effect. Say what it is, once every 6 hours, and do not touch the controller.
  local ars_phase outdated_file="$STATE/${key}.outdated"
  ars_phase=$($KC get autoscalingrunnerset "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$ars_phase" = "Outdated" ]; then
    rm -f "$STATE/$key"
    log "$ns/$name: phase=Outdated — runner image too old, not restarting the controller"
    if [ -z "$(find "$outdated_file" -mmin -360 2>/dev/null)" ]; then
      capture "$ns" "$name"
      notify "🔴 ARC: <b>$ns/$name</b> is <b>Outdated</b> — GitHub retired the runner version in its image, and ARC removed the listener on purpose. Jobs will queue until the pool gets a newer runner image: rebuild <code>runner-image/</code> (workflow Build runner-image) and redeploy with its sha. Restarting the controller does not help."
      touch "$outdated_file"
    fi
    return 0
  fi
  rm -f "$outdated_file"

  listener=$(printf '%s' "$listeners_json" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for i in d.get('items', []):
    s = i.get('spec', {})
    if s.get('autoscalingRunnerSetNamespace') == '$ns' and s.get('autoscalingRunnerSetName') == '$name':
        print(i['metadata']['name'], s.get('ephemeralRunnerSetName', ''))
        break
")
  local lpod
  lpod=$(awk '{print $1}' <<<"$listener")
  ers_ref=$(awk '{print $2}' <<<"$listener")

  if [ -n "$lpod" ]; then
    local phase ready
    phase=$($KC get pod "$lpod" -n arc-systems -o jsonpath='{.status.phase}' 2>/dev/null)
    ready=$($KC get pod "$lpod" -n arc-systems -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    [ "$phase" = "Running" ] && [ "$ready" = "true" ] && pod_ok=1
    if [ -n "$ers_ref" ] && ! $KC get ephemeralrunnerset "$ers_ref" -n "$ns" >/dev/null 2>&1; then
      ref_ok=0
    fi
  fi

  # A Running, Ready listener can still be deaf. Its long-poll to
  # broker.actions.githubusercontent.com returns within ~50 s, empty or not, and every
  # return logs "Calculated target runner count" (30 lines in 30 idle minutes, measured
  # 2026-10-08). After bld1 lost its uplink 19:55–20:06 UTC that day, all ten listeners
  # kept answering "Client.Timeout exceeded while awaiting headers" and never logged
  # another one until their pods were recreated at 20:10. A fresh pod opens a new session.
  local polling=1
  if [ "$pod_ok" = 1 ] && [ "$ref_ok" = 1 ]; then
    local started recent
    started=$($KC get pod "$lpod" -n arc-systems -o jsonpath='{.status.startTime}' 2>/dev/null)
    # Read the log whole: `grep -q` on a pipe exits at the first match, kubectl dies
    # of SIGPIPE, and under pipefail a polling listener would read as a deaf one.
    if [ -n "$started" ] && [ $(( $(date +%s) - $(date -d "$started" +%s) )) -gt 600 ] &&
      recent=$($KC logs "$lpod" -n arc-systems --since=10m 2>/dev/null) &&
      [[ "$recent" != *'Calculated target runner count'* ]]; then
      polling=0
    fi
  fi

  if [ "$pod_ok" = 1 ] && [ "$ref_ok" = 1 ] && [ "$polling" = 1 ]; then
    rm -f "$STATE/$key"
    return 0
  fi

  strikes=$(( $(cat "$STATE/$key" 2>/dev/null || echo 0) + 1 ))
  echo "$strikes" > "$STATE/$key"
  log "$ns/$name unhealthy (pod_ok=$pod_ok ref_ok=$ref_ok polling=$polling listener=${lpod:-none} ers_ref=${ers_ref:-none}) strike=$strikes"
  [ "$strikes" -ge "$STRIKES_TO_HEAL" ] || return 0

  capture "$ns" "$name"

  if [ "$polling" = 0 ]; then
    log "healing: deleting listener pod $lpod (no broker poll returned in 10 min)"
    $KC delete pod "$lpod" -n arc-systems --timeout=60s
    notify "🛠 ARC self-heal: <b>$ns/$name</b> listener was Running but got no answer from the GitHub broker for 10 min; pod recreated."
  elif [ "$ref_ok" = 0 ] && [ -n "$lpod" ]; then
    log "healing: deleting stale AutoscalingListener $lpod (dangling ERS $ers_ref)"
    $KC delete autoscalinglistener "$lpod" -n arc-systems --timeout=60s
    notify "🛠 ARC self-heal: <b>$ns/$name</b> listener pointed at a deleted EphemeralRunnerSet (<code>$ers_ref</code>); listener CR recreated. Runners should come back within ~1 min."
  else
    log "healing: rollout restart of arc-gha-rs-controller"
    $KC -n arc-systems rollout restart deploy/arc-gha-rs-controller
    $KC -n arc-systems rollout status deploy/arc-gha-rs-controller --timeout=120s
    notify "🛠 ARC self-heal: <b>$ns/$name</b> has no live listener; restarted arc-gha-rs-controller. Evidence in <code>$STATE/</code> on the build host — the restart does not always cure this, and repeats mean it did not."
  fi
  rm -f "$STATE/$key"
}

mapfile -t ARS < <($KC get autoscalingrunnerset -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null)
if [ "${#ARS[@]}" -eq 0 ]; then
  log "no AutoscalingRunnerSets found (cluster unreachable?)"
  exit 0
fi
for row in "${ARS[@]}"; do
  [ -n "$row" ] || continue
  # shellcheck disable=SC2086 # row is "<namespace> <name>" — split on purpose
  heal_one $row
done
