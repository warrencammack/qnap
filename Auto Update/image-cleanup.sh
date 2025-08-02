#!/bin/bash

set -euo pipefail

# QNAP Docker Image Cleanup System
# Removes outdated Docker images while keeping N-1 versions (current + previous)
# Runs during the same maintenance window as auto-updates

# Set Docker path for QNAP Container Station
export PATH="/share/CACHEDEV1_DATA/.qpkg/container-station/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/image-cleanup.log"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

SLACK_WEBHOOK_URL=""
SLACK_CHANNEL=""
SLACK_USERNAME="Docker Image Cleanup"

# Default retention: keep current + 1 previous version
DEFAULT_RETENTION=2

get_config_value() {
    local key="$1"
    local default_value="$2"
    
    if [ -f "$CONFIG_FILE" ]; then
        local value=$(grep -A 10 "^image_cleanup:" "$CONFIG_FILE" | grep "$key:" | sed "s/.*$key: *\(.*\)/\1/" | tr -d ' ' || echo "")
        echo "${value:-$default_value}"
    else
        echo "$default_value"
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        SLACK_WEBHOOK_URL=$(grep -A 5 "^slack:" "$CONFIG_FILE" | grep "webhook_url:" | sed 's/.*webhook_url: *"\(.*\)".*/\1/' || echo "")
        SLACK_CHANNEL=$(grep -A 5 "^slack:" "$CONFIG_FILE" | grep "channel:" | sed 's/.*channel: *"\(.*\)".*/\1/' || echo "")
        SLACK_USERNAME=$(grep -A 5 "^slack:" "$CONFIG_FILE" | grep "username:" | sed 's/.*username: *"\(.*\)".*/\1/' || echo "Docker Image Cleanup")
    fi
}

check_maintenance_window() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi
    
    local enforce=$(grep -A 10 "maintenance_window:" "$CONFIG_FILE" | grep "enforce:" | sed 's/.*enforce: *\(.*\)/\1/' | tr -d ' ' || echo "false")
    
    if [ "$enforce" != "true" ]; then
        return 0
    fi
    
    local start_hour=$(grep -A 10 "maintenance_window:" "$CONFIG_FILE" | grep "start_hour:" | sed 's/.*start_hour: *\([0-9]*\).*/\1/' || echo "")
    local end_hour=$(grep -A 10 "maintenance_window:" "$CONFIG_FILE" | grep "end_hour:" | sed 's/.*end_hour: *\([0-9]*\).*/\1/' || echo "")
    local current_hour=$(date +%H | sed 's/^0*//')
    
    if [ -z "$start_hour" ] || [ -z "$end_hour" ]; then
        return 0
    fi
    
    if [ "$current_hour" -ge "$start_hour" ] && [ "$current_hour" -lt "$end_hour" ]; then
        return 0
    else
        log "Current time (${current_hour}:xx) is outside maintenance window (${start_hour}:00 - ${end_hour}:00)"
        send_slack_notification "❌ Image cleanup skipped: Outside maintenance window (${start_hour}:00 - ${end_hour}:00). Current time: ${current_hour}:$(date +%M)" "warning"
        return 1
    fi
}

send_slack_notification() {
    local message="$1"
    local color="${2:-good}"
    
    if [ -z "$SLACK_WEBHOOK_URL" ] || [ "$SLACK_WEBHOOK_URL" = "YOUR_SLACK_WEBHOOK_URL_HERE" ]; then
        log "Slack webhook not configured, skipping notification"
        return 0
    fi
    
    local payload="{
        \"username\": \"$SLACK_USERNAME\",
        \"attachments\": [
            {
                \"color\": \"$color\",
                \"title\": \"QNAP Docker Image Cleanup\",
                \"text\": \"$message\",
                \"ts\": $(date +%s)
            }
        ]"
    
    if [ -n "$SLACK_CHANNEL" ]; then
        payload="$payload, \"channel\": \"$SLACK_CHANNEL\""
    fi
    
    payload="$payload}"
    
    if curl -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
        log "Slack notification sent successfully"
    else
        log_error "Failed to send Slack notification"
    fi
}

get_image_repositories() {
    # Get unique repositories from all images (excluding <none> images)
    docker images --format "{{.Repository}}" | grep -v "^<none>$" | sort -u
}

cleanup_repository_images() {
    local repository="$1"
    local retention="${2:-$DEFAULT_RETENTION}"
    
    log "Cleaning up repository: $repository (keeping $retention versions)"
    
    # Get images for this repository, sorted by creation date (newest first)
    local images=$(docker images "$repository" --format "{{.ID}} {{.Tag}} {{.CreatedAt}}" | sort -k3 -r)
    
    if [ -z "$images" ]; then
        log "No images found for repository: $repository"
        return 0
    fi
    
    local count=0
    local removed_count=0
    local kept_images=""
    local removed_images=""
    
    while IFS= read -r line; do
        if [ -z "$line" ]; then continue; fi
        
        local image_id=$(echo "$line" | awk '{print $1}')
        local tag=$(echo "$line" | awk '{print $2}')
        local created=$(echo "$line" | awk '{$1=""; $2=""; print $0}' | sed 's/^ *//')
        
        count=$((count + 1))
        
        if [ $count -le $retention ]; then
            log "Keeping: $repository:$tag ($image_id) - $created"
            kept_images="$kept_images$repository:$tag "
        else
            log "Removing: $repository:$tag ($image_id) - $created"
            
            # Check if image is in use by any container
            local in_use=$(docker ps -a --format "{{.Image}}" | grep -c "^$repository:$tag$" || echo "0")
            
            if [ "$in_use" -gt 0 ]; then
                log "WARNING: Image $repository:$tag is in use by $in_use container(s), skipping removal"
                kept_images="$kept_images$repository:$tag "
            else
                if docker rmi "$repository:$tag" >/dev/null 2>&1; then
                    log "Successfully removed: $repository:$tag"
                    removed_images="$removed_images$repository:$tag "
                    removed_count=$((removed_count + 1))
                else
                    log_error "Failed to remove: $repository:$tag"
                fi
            fi
        fi
    done <<< "$images"
    
    return $removed_count
}

get_disk_usage() {
    local usage=$(docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}" | grep "Images" | awk '{print $4}')
    echo "${usage:-0B}"
}

main() {
    log "Starting Docker image cleanup process..."
    
    load_config
    
    if ! check_maintenance_window; then
        exit 0
    fi
    
    # Get configuration values
    local retention=$(get_config_value "retention_versions" "$DEFAULT_RETENTION")
    local prune_enabled=$(get_config_value "prune_system" "true")
    
    log "Configuration: retention_versions=$retention, prune_system=$prune_enabled"
    
    local initial_usage=$(get_disk_usage)
    log "Initial reclaimable space: $initial_usage"
    
    local repositories=$(get_image_repositories)
    local total_removed=0
    local cleaned_repos=""
    
    if [ -z "$repositories" ]; then
        log "No Docker images found to clean up"
        send_slack_notification "ℹ️ No Docker images found to clean up" "warning"
        exit 0
    fi
    
    log "Found repositories to clean: $(echo "$repositories" | wc -l)"
    
    while IFS= read -r repo; do
        if [ -n "$repo" ]; then
            cleanup_repository_images "$repo" "$retention"
            local repo_removed=$?
            if [ $repo_removed -gt 0 ]; then
                total_removed=$((total_removed + repo_removed))
                cleaned_repos="$cleaned_repos$repo($repo_removed) "
            fi
        fi
    done <<< "$repositories"
    
    # Run docker system prune if enabled
    if [ "$prune_enabled" = "true" ]; then
        log "Running docker system prune to clean up dangling resources..."
        local prune_output=$(docker system prune -f 2>&1)
        log "Prune output: $prune_output"
    else
        log "System prune disabled in configuration"
    fi
    
    local final_usage=$(get_disk_usage)
    log "Final reclaimable space: $final_usage"
    log "Image cleanup completed. Total images removed: $total_removed"
    
    # Send summary notification
    local notification_message=""
    local notification_color="good"
    
    if [ $total_removed -gt 0 ]; then
        notification_message="🧹 Image cleanup completed successfully\\n"
        notification_message="${notification_message}• Images removed: $total_removed\\n"
        notification_message="${notification_message}• Repositories cleaned: $cleaned_repos\\n"
        notification_message="${notification_message}• Initial reclaimable space: $initial_usage\\n"
        notification_message="${notification_message}• Final reclaimable space: $final_usage"
    else
        notification_message="ℹ️ No old images found to remove (all repositories already clean)"
        notification_color="warning"
    fi
    
    send_slack_notification "$notification_message" "$notification_color"
    
    log "Docker image cleanup process completed successfully!"
}

main "$@"