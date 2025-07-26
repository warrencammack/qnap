#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_UPDATE_SCRIPT="$SCRIPT_DIR/auto-update.sh"

echo "Setting up weekly cron job for Docker auto-updates..."

if [ ! -f "$AUTO_UPDATE_SCRIPT" ]; then
    echo "Error: auto-update.sh not found at $AUTO_UPDATE_SCRIPT"
    exit 1
fi

CRON_JOB="0 2 * * 0 $AUTO_UPDATE_SCRIPT >> $SCRIPT_DIR/cron.log 2>&1"

(crontab -l 2>/dev/null | grep -v "$AUTO_UPDATE_SCRIPT"; echo "$CRON_JOB") | crontab -

echo "Cron job added successfully!"
echo "Schedule: Every Sunday at 2:00 AM"
echo "Logs will be written to: $SCRIPT_DIR/cron.log"
echo ""
echo "To view current cron jobs: crontab -l"
echo "To remove this cron job, run: crontab -e"