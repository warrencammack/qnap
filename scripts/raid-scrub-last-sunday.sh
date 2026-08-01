#!/bin/sh
set -eu

# Runs every Sunday via cron; only triggers RAID data scrubbing on the
# last Sunday of the month. QNAP's native scheduler (storage_util
# --set_data_scrubbing_schedule) only supports daily/weekly/fixed-day-of-
# month, not "last weekday of month", hence this wrapper.

LOG_FILE="${LOG_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/raid-scrub-last-sunday.log}"
STORAGE_UTIL="${STORAGE_UTIL:-/sbin/storage_util}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

this_month=$(date +%m)
next_week_month=$(date -d '+7 days' +%m)

if [ "$this_month" != "$next_week_month" ]; then
  log "last Sunday of month - starting RAID data scrubbing"
  "$STORAGE_UTIL" --data_scrubbing raid_id=-1 >/dev/null 2>&1
  log "data scrubbing triggered"
else
  log "not last Sunday of month - skipping"
fi
