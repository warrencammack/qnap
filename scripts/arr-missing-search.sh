#!/bin/sh
# Triggers daily missing-content searches in Radarr, Sonarr, and Readarr.
# Runs at 4am daily via cron. Required because missing search is not a
# built-in recurring scheduled task in these app versions.

LOG="/share/CACHEDEV1_DATA/homes/admin/qnap/logs/arr-missing-search.log"
SECRET_FILE="${SECRET_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/secrets/arr-api-keys.env}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

if [ ! -r "$SECRET_FILE" ]; then
  log "missing secret file: $SECRET_FILE"
  exit 1
fi

# shellcheck disable=SC1090
. "$SECRET_FILE"

if [ -z "${RADARR_KEY:-}" ] || [ -z "${SONARR_KEY:-}" ] || [ -z "${READARR_KEY:-}" ]; then
  log "missing RADARR_KEY, SONARR_KEY, or READARR_KEY in $SECRET_FILE"
  exit 1
fi

trigger() {
  name="$1"; url="$2"; payload="$3"
  result=$(wget -qO- --header="Content-Type: application/json" --post-data="$payload" "$url" 2>&1)
  if echo "$result" | grep -q '"status"'; then
    log "$name: search queued OK"
  else
    log "$name: ERROR - $result"
  fi
}

log "--- starting missing search ---"
trigger "Radarr"  "http://localhost:7878/api/v3/command?apikey=$RADARR_KEY"  '{"name":"MissingMoviesSearch"}'
trigger "Sonarr"  "http://localhost:8989/api/v3/command?apikey=$SONARR_KEY"  '{"name":"MissingEpisodeSearch"}'
trigger "Readarr" "http://localhost:8787/api/v1/command?apikey=$READARR_KEY" '{"name":"MissingBookSearch"}'
log "--- done ---"
