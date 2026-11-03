#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${ROUTE64_FAILOVER_CONFIG:-/etc/default/route64-failover}"
[[ -r "$CONFIG_FILE" ]] || { echo "Missing config: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

PRIMARY_IFACE="${PRIMARY_IFACE:-wg0}"
BACKUP_IFACE="${BACKUP_IFACE:-wg2}"
PROBE_TARGET="${PROBE_TARGET:-2606:4700:4700::1111}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
RECOVER_THRESHOLD="${RECOVER_THRESHOLD:-5}"
PING_COUNT="${PING_COUNT:-2}"
PING_TIMEOUT="${PING_TIMEOUT:-3}"
STATE_FILE="${STATE_FILE:-/run/route64-failover.active}"

for value in "$CHECK_INTERVAL" "$FAIL_THRESHOLD" "$RECOVER_THRESHOLD" "$PING_COUNT" "$PING_TIMEOUT"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "Numeric failover setting expected, got: $value" >&2; exit 1; }
done
(( CHECK_INTERVAL >= 1 && FAIL_THRESHOLD >= 1 && RECOVER_THRESHOLD >= 1 && PING_COUNT >= 1 && PING_TIMEOUT >= 1 )) || {
  echo "Failover thresholds and intervals must be positive." >&2; exit 1;
}
[[ "$PRIMARY_IFACE" != "$BACKUP_IFACE" ]] || { echo "Primary and backup interfaces must differ." >&2; exit 1; }

log() { logger -t route64-failover -- "$*"; echo "$(date -Is) $*"; }
is_healthy() {
  local iface="$1"
  ip link show dev "$iface" >/dev/null 2>&1 || return 1
  wg show "$iface" >/dev/null 2>&1 || return 1
  ping -6 -n -I "$iface" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PROBE_TARGET" >/dev/null 2>&1
}
apply_route() {
  local iface="$1"
  # The two Route64 interfaces must use Table=off in their wg-quick configs.
  # This controller owns the two IPv6 split-default routes in the main table.
  ip -6 route del ::/1 dev "$PRIMARY_IFACE" 2>/dev/null || true
  ip -6 route del 8000::/1 dev "$PRIMARY_IFACE" 2>/dev/null || true
  ip -6 route del ::/1 dev "$BACKUP_IFACE" 2>/dev/null || true
  ip -6 route del 8000::/1 dev "$BACKUP_IFACE" 2>/dev/null || true
  ip -6 route replace ::/1 dev "$iface" metric 10
  ip -6 route replace 8000::/1 dev "$iface" metric 10
  printf '%s\n' "$iface" > "$STATE_FILE"
  log "Active Route64 uplink changed to $iface"
}

active="$(cat "$STATE_FILE" 2>/dev/null || true)"
[[ "$active" == "$PRIMARY_IFACE" || "$active" == "$BACKUP_IFACE" ]] || active=""

primary_fail=0
primary_good=0
backup_fail=0
backup_good=0

log "Started: primary=$PRIMARY_IFACE backup=$BACKUP_IFACE probe=$PROBE_TARGET interval=${CHECK_INTERVAL}s"
while true; do
  primary_ok=0
  backup_ok=0
  is_healthy "$PRIMARY_IFACE" && primary_ok=1 || true
  is_healthy "$BACKUP_IFACE" && backup_ok=1 || true

  if (( primary_ok )); then primary_fail=0; ((primary_good+=1)); else primary_good=0; ((primary_fail+=1)); fi
  if (( backup_ok )); then backup_fail=0; ((backup_good+=1)); else backup_good=0; ((backup_fail+=1)); fi

  if [[ -z "$active" ]]; then
    if (( primary_ok )); then apply_route "$PRIMARY_IFACE"; active="$PRIMARY_IFACE"
    elif (( backup_ok )); then apply_route "$BACKUP_IFACE"; active="$BACKUP_IFACE"
    else log "Both uplinks are unhealthy; waiting for recovery"
    fi
  elif [[ "$active" == "$PRIMARY_IFACE" ]]; then
    if (( primary_fail >= FAIL_THRESHOLD && backup_ok )); then
      apply_route "$BACKUP_IFACE"; active="$BACKUP_IFACE"
    elif (( primary_fail >= FAIL_THRESHOLD && ! backup_ok )); then
      log "Primary failed but backup is also unhealthy; retaining last route"
    fi
  else
    if (( primary_good >= RECOVER_THRESHOLD )); then
      apply_route "$PRIMARY_IFACE"; active="$PRIMARY_IFACE"
    elif (( backup_fail >= FAIL_THRESHOLD && primary_ok )); then
      apply_route "$PRIMARY_IFACE"; active="$PRIMARY_IFACE"
    elif (( backup_fail >= FAIL_THRESHOLD && ! primary_ok )); then
      log "Backup failed and primary is unhealthy; retaining last route"
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
