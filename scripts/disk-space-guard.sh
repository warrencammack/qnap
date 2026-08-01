#!/bin/sh
set -eu

# Pauses download clients before the main QNAP data volume can fill.
# This script never deletes media or resumes downloads automatically.

VOLUME_PATH="${VOLUME_PATH:-/share/CACHEDEV1_DATA}"
LOG_FILE="${LOG_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/disk-space-guard.log}"
STATE_FILE="${STATE_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/disk-space-guard.state}"
LOCK_DIR="${LOCK_DIR:-/tmp/codex-disk-space-guard.lock}"

WARN_FREE_PCT="${WARN_FREE_PCT:-20}"
STOP_FREE_PCT="${STOP_FREE_PCT:-12}"
EMERGENCY_FREE_PCT="${EMERGENCY_FREE_PCT:-8}"

WARN_FREE_KB="${WARN_FREE_KB:-2147483648}"       # 2 TiB
STOP_FREE_KB="${STOP_FREE_KB:-1288490189}"       # 1.2 TiB
EMERGENCY_FREE_KB="${EMERGENCY_FREE_KB:-838860800}" # 800 GiB

DOCKER_BIN="${DOCKER_BIN:-/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker}"
TRANSMISSION_URL="${TRANSMISSION_URL:-http://127.0.0.1:9091/transmission/rpc}"
SABNZBD_URL="${SABNZBD_URL:-http://127.0.0.1:8181/api}"
SABNZBD_INI="${SABNZBD_INI:-/share/Container/containerapp/sabnzbd/config/sabnzbd.ini}"
DRY_RUN="${DRY_RUN:-0}"

now() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(now)" "$*" >> "$LOG_FILE"
}

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap cleanup EXIT INT TERM

if [ ! -d "$VOLUME_PATH" ]; then
  log "ERROR volume path missing: $VOLUME_PATH"
  exit 1
fi

df_line=$(df -Pk "$VOLUME_PATH" | awk 'NR==2 {print $2 " " $3 " " $4 " " $5}')
total_kb=$(printf '%s\n' "$df_line" | awk '{print $1}')
used_kb=$(printf '%s\n' "$df_line" | awk '{print $2}')
avail_kb=$(printf '%s\n' "$df_line" | awk '{print $3}')
used_pct=$(printf '%s\n' "$df_line" | awk '{gsub(/%/,"",$4); print $4}')
free_pct=$((100 - used_pct))

state="OK"
if [ "$free_pct" -le "$EMERGENCY_FREE_PCT" ] || [ "$avail_kb" -le "$EMERGENCY_FREE_KB" ]; then
  state="EMERGENCY"
elif [ "$free_pct" -le "$STOP_FREE_PCT" ] || [ "$avail_kb" -le "$STOP_FREE_KB" ]; then
  state="STOP"
elif [ "$free_pct" -le "$WARN_FREE_PCT" ] || [ "$avail_kb" -le "$WARN_FREE_KB" ]; then
  state="WARN"
fi

previous_state=""
[ -f "$STATE_FILE" ] && previous_state=$(cat "$STATE_FILE" 2>/dev/null || true)

if [ "$state" != "$previous_state" ]; then
  log "STATE $previous_state -> $state volume=$VOLUME_PATH total_kb=$total_kb used_kb=$used_kb avail_kb=$avail_kb used_pct=${used_pct} free_pct=${free_pct}"
  printf '%s\n' "$state" > "$STATE_FILE"
fi

get_transmission_credentials() {
  [ -x "$DOCKER_BIN" ] || return 1
  user=$("$DOCKER_BIN" inspect transmission --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^USER=//p' | head -n 1)
  pass=$("$DOCKER_BIN" inspect transmission --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^PASS=//p' | head -n 1)
  [ -n "$user" ] && [ -n "$pass" ] || return 1
  printf '%s:%s\n' "$user" "$pass"
}

pause_transmission() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would pause Transmission torrents"
    return 0
  fi

  creds=$(get_transmission_credentials) || {
    log "WARN could not pause Transmission: credentials unavailable from container env"
    return 1
  }

  header_file="/tmp/dsg_tx_headers.$$"
  body_file="/tmp/dsg_tx_body.$$"
  rm -f "$header_file" "$body_file"

  curl -sS -u "$creds" -D "$header_file" -o "$body_file" "$TRANSMISSION_URL" >/dev/null 2>&1 || true
  session_id=$(sed -n 's/^[Xx]-[Tt]ransmission-[Ss]ession-[Ii]d:[[:space:]]*//p' "$header_file" | tr -d '\r' | tail -n 1)

  if [ -z "$session_id" ]; then
    rm -f "$header_file" "$body_file"
    log "WARN could not pause Transmission: session id unavailable"
    return 1
  fi

  if curl -sS -u "$creds" -H "X-Transmission-Session-Id: $session_id" \
    -H 'Content-Type: application/json' \
    --data '{"method":"torrent-stop"}' "$TRANSMISSION_URL" >/dev/null 2>&1; then
    log "ACTION paused Transmission torrents"
    rm -f "$header_file" "$body_file"
    return 0
  fi

  rm -f "$header_file" "$body_file"
  log "WARN could not pause Transmission: RPC call failed"
  return 1
}

get_sabnzbd_api_key() {
  [ -f "$SABNZBD_INI" ] || return 1
  key=$(sed -n 's/^[[:space:]]*api_key[[:space:]]*=[[:space:]]*//p' "$SABNZBD_INI" | head -n 1)
  [ -n "$key" ] || return 1
  printf '%s\n' "$key"
}

pause_sabnzbd() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN would pause SABnzbd queue"
    return 0
  fi

  key=$(get_sabnzbd_api_key) || {
    log "WARN could not pause SABnzbd: API key unavailable"
    return 1
  }

  if curl -fsS --get "$SABNZBD_URL" \
    --data-urlencode "mode=pause" \
    --data-urlencode "apikey=$key" \
    --data-urlencode "output=json" >/dev/null 2>&1; then
    log "ACTION paused SABnzbd queue"
    return 0
  fi

  log "WARN could not pause SABnzbd: API call failed"
  return 1
}

case "$state" in
  OK)
    exit 0
    ;;
  WARN)
    exit 0
    ;;
  STOP|EMERGENCY)
    pause_transmission || true
    pause_sabnzbd || true
    exit 0
    ;;
esac
