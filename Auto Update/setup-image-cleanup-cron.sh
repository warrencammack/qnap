#!/bin/bash

# Setup script for Docker image cleanup cron job
# Schedules image cleanup to run weekly during maintenance window

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="$SCRIPT_DIR/image-cleanup.sh"
CRON_LOG="$SCRIPT_DIR/image-cleanup-cron.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# Check if cleanup script exists
if [ ! -f "$CLEANUP_SCRIPT" ]; then
    log_error "Image cleanup script not found: $CLEANUP_SCRIPT"
    exit 1
fi

# Make the cleanup script executable
chmod +x "$CLEANUP_SCRIPT"
log "Made image cleanup script executable"

# Create cron job entry
# Schedule: Every Sunday at 3:00 AM (1 hour after auto-update at 2:00 AM)
# This ensures cleanup runs after updates have completed
CRON_ENTRY="0 3 * * 0 cd '$SCRIPT_DIR' && '$CLEANUP_SCRIPT' >> '$CRON_LOG' 2>&1"

# Check if cron job already exists
if crontab -l 2>/dev/null | grep -q "image-cleanup.sh"; then
    log "Image cleanup cron job already exists"
    
    # Show existing cron jobs related to image cleanup
    echo "Existing image cleanup cron jobs:"
    crontab -l 2>/dev/null | grep "image-cleanup.sh" || echo "None found"
    
    read -p "Do you want to replace the existing cron job? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Keeping existing cron job"
        exit 0
    fi
    
    # Remove existing image cleanup cron jobs
    crontab -l 2>/dev/null | grep -v "image-cleanup.sh" | crontab -
    log "Removed existing image cleanup cron jobs"
fi

# Add new cron job
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

if [ $? -eq 0 ]; then
    log "Successfully added image cleanup cron job"
    log "Schedule: Every Sunday at 3:00 AM"
    log "Log file: $CRON_LOG"
    
    echo
    echo "=== Current crontab ==="
    crontab -l
    echo "======================="
    echo
    
    log "Setup completed successfully!"
else
    log_error "Failed to add cron job"
    exit 1
fi

# Create initial log file
touch "$CRON_LOG"
log "Created log file: $CRON_LOG"

echo
echo "Image cleanup is now scheduled to run:"
echo "• Every Sunday at 3:00 AM"
echo "• During the same maintenance window as auto-updates"
echo "• Logs will be written to: $CRON_LOG"
echo
echo "To test the cleanup manually:"
echo "  cd '$SCRIPT_DIR' && ./image-cleanup.sh"
echo
echo "To view cleanup logs:"
echo "  tail -f '$CRON_LOG'"