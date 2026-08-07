#!/usr/bin/env bash
# ARC self-heal — keeps every runner scale-set's listener alive.
#
# Fixes two failure modes, both observed live on 2026-08-06/07 in the wake of a
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
#      listener exists at all. Cure: rollout restart the controller.
#
# Both leave zero red checks anywhere — jobs just queue silently — so the repair
# is announced to Telegram when configured.
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

heal_one() {
  local ns="$1" name="$2"
  local key="${ns}_${name}" strikes listener ers_ref pod_ok=0 ref_ok=1

  listener=$($KC get autoscalinglistener -n arc-systems -o json 2>/dev/null | python3 -c "
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

  if [ "$pod_ok" = 1 ] && [ "$ref_ok" = 1 ]; then
    rm -f "$STATE/$key"
    return 0
  fi

  strikes=$(( $(cat "$STATE/$key" 2>/dev/null || echo 0) + 1 ))
  echo "$strikes" > "$STATE/$key"
  log "$ns/$name unhealthy (pod_ok=$pod_ok ref_ok=$ref_ok listener=${lpod:-none} ers_ref=${ers_ref:-none}) strike=$strikes"
  [ "$strikes" -ge "$STRIKES_TO_HEAL" ] || return 0

  if [ "$ref_ok" = 0 ] && [ -n "$lpod" ]; then
    log "healing: deleting stale AutoscalingListener $lpod (dangling ERS $ers_ref)"
    $KC delete autoscalinglistener "$lpod" -n arc-systems --timeout=60s
    notify "🛠 ARC self-heal: <b>$ns/$name</b> listener pointed at a deleted EphemeralRunnerSet (<code>$ers_ref</code>); listener CR recreated. Runners should come back within ~1 min."
  else
    log "healing: rollout restart of arc-gha-rs-controller"
    $KC -n arc-systems rollout restart deploy/arc-gha-rs-controller
    $KC -n arc-systems rollout status deploy/arc-gha-rs-controller --timeout=120s
    notify "🛠 ARC self-heal: <b>$ns/$name</b> has no live listener; restarted arc-gha-rs-controller."
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
