#!/bin/bash

set -euo pipefail

# QNAP Docker Auto-Update System
# This script maintains each YAML file as a separate application on QNAP Container Station
# Each service runs in isolation with its own networks and containers

# Set Docker path for QNAP Container Station
export PATH="/share/CACHEDEV1_DATA/.qpkg/container-station/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSER_DIR="$PROJECT_ROOT/Composer"
LOG_FILE="$SCRIPT_DIR/auto-update.log"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

SLACK_WEBHOOK_URL=""
SLACK_CHANNEL=""
SLACK_USERNAME="Docker Auto-Update"

json_escape() {
    local string="$1"
    string="${string//\\/\\\\}"    # \ → \\  (must be first)
    string="${string//\"/\\\"}"    # " → \"
    string="${string//$'\n'/\\n}"  # newline → \n
    string="${string//$'\t'/\\t}"  # tab → \t
    printf '%s' "$string"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        SLACK_WEBHOOK_URL=$(grep -A 5 "^slack:" "$CONFIG_FILE" | grep "webhook_url:" | sed 's/.*webhook_url: *"\(.*\)".*/\1/')
        SLACK_CHANNEL=$(grep -A 5 "^slack:" "$CONFIG_FILE" | grep "channel:" | sed 's/.*channel: *"\(.*\)".*/\1/' || echo "")
        SLACK_USERNAME=$(grep -A 5 "^slack:" "$CONFIG_FILE" | grep "username:" | sed 's/.*username: *"\(.*\)".*/\1/' || echo "Docker Auto-Update")
    fi
}

check_maintenance_window() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi
    
    local enforce=$(grep -A 10 "maintenance_window:" "$CONFIG_FILE" | grep "enforce:" | sed 's/.*enforce: *\(.*\)/\1/' | tr -d ' ')
    
    if [ "$enforce" != "true" ]; then
        return 0
    fi
    
    local start_hour=$(grep -A 10 "maintenance_window:" "$CONFIG_FILE" | grep "start_hour:" | sed 's/.*start_hour: *\([0-9]*\).*/\1/')
    local end_hour=$(grep -A 10 "maintenance_window:" "$CONFIG_FILE" | grep "end_hour:" | sed 's/.*end_hour: *\([0-9]*\).*/\1/')
    local current_hour=$(date +%H | sed 's/^0*//')
    
    if [ -z "$start_hour" ] || [ -z "$end_hour" ]; then
        return 0
    fi
    
    if [ "$current_hour" -ge "$start_hour" ] && [ "$current_hour" -lt "$end_hour" ]; then
        return 0
    else
        log "Current time (${current_hour}:xx) is outside maintenance window (${start_hour}:00 - ${end_hour}:00)"
        send_slack_notification "❌ Auto-update skipped: Outside maintenance window (${start_hour}:00 - ${end_hour}:00). Current time: ${current_hour}:$(date +%M)" "warning"
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
    
    local escaped_message escaped_username escaped_channel
    escaped_message=$(json_escape "$message")
    escaped_username=$(json_escape "$SLACK_USERNAME")
    escaped_channel=$(json_escape "$SLACK_CHANNEL")

    local payload="{
        \"username\": \"$escaped_username\",
        \"attachments\": [
            {
                \"color\": \"$color\",
                \"title\": \"QNAP Docker Auto-Update\",
                \"text\": \"$escaped_message\",
                \"ts\": $(date +%s)
            }
        ]"

    if [ -n "$SLACK_CHANNEL" ]; then
        payload="$payload, \"channel\": \"$escaped_channel\""
    fi
    
    payload="$payload}"
    
    if curl -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
        log "Slack notification sent successfully"
    else
        log_error "Failed to send Slack notification"
    fi
}

backup_current_image() {
    local service_name="$1"
    local current_image=$(docker inspect "$service_name" --format='{{.Config.Image}}' 2>/dev/null || echo "")
    
    if [ -n "$current_image" ]; then
        docker tag "$current_image" "${current_image%:*}:backup-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
        echo "$current_image"
    fi
}

rollback_service() {
    local compose_file="$1"
    local service_name="$2"
    local backup_image="$3"
    
    log "Rolling back $service_name to previous image: $backup_image"
    
    if [ -n "$backup_image" ]; then
        cd "$COMPOSER_DIR"
        
        # Stop and remove current container and networks
        docker compose -p "$service_name" -f "$(basename "$compose_file")" down --remove-orphans >/dev/null 2>&1 || true
        
        # Tag backup image as latest
        docker tag "$backup_image" "${backup_image%:*}:latest" 2>/dev/null || true
        
        # Recreate container with backup image as separate application
        if docker compose -p "$service_name" -f "$(basename "$compose_file")" up -d --force-recreate; then
            log "Successfully rolled back $service_name as separate application"
            return 0
        else
            log_error "Failed to rollback $service_name"
            return 1
        fi
    else
        log_error "No backup image available for rollback of $service_name"
        return 1
    fi
}

health_check_service() {
    local service_name="$1"
    local max_attempts=12
    local attempt=1
    
    log "Performing health check for $service_name..."
    
    while [ $attempt -le $max_attempts ]; do
        if docker ps | grep -q "$service_name.*Up"; then
            log "Health check passed for $service_name (attempt $attempt/$max_attempts)"
            return 0
        fi
        
        log "Health check attempt $attempt/$max_attempts failed for $service_name, waiting 5 seconds..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    log_error "Health check failed for $service_name after $max_attempts attempts"
    return 1
}

resolve_latest_ghcr_tag() {
    # Resolves the latest tag for images with pinned version tags (no rolling :latest)
    # Usage: resolve_latest_ghcr_tag "linuxserver/readarr" "nightly"
    # Returns the full tag e.g. "nightly-0.4.19.2811-ls400"
    local repo="$1"
    local prefix="$2"

    local token
    token=$(curl -s "https://ghcr.io/token?scope=repository:${repo}:pull" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    if [ -z "$token" ]; then
        log_error "Failed to get registry token for $repo"
        return 1
    fi

    local all_tags=""
    local last=""
    local i=0
    while [ $i -lt 10 ]; do
        local url="https://ghcr.io/v2/${repo}/tags/list?n=1000"
        if [ -n "$last" ]; then
            url="${url}&last=${last}"
        fi
        local tags
        tags=$(curl -s -H "Authorization: Bearer $token" "$url" \
            | grep -o "\"${prefix}-[0-9][^\"]*\"" \
            | tr -d '"' \
            | grep -E "^${prefix}-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-ls[0-9]+$")
        if [ -z "$tags" ]; then break; fi
        all_tags="${all_tags}
${tags}"
        last=$(echo "$tags" | tail -1)
        i=$((i + 1))
    done

    local latest
    latest=$(echo "$all_tags" | awk -F'[-.]' '{printf "%04d%04d%04d%06d %s\n", $2, $3, $4, $5, $0}' | sort -n | tail -1 | awk '{print $2}')

    if [ -z "$latest" ]; then
        log_error "No tags found for $repo with prefix $prefix"
        return 1
    fi

    echo "$latest"
}

update_pinned_image_tag() {
    # For services with pinned version tags, resolve and update the compose file
    # Returns 0 if tag was updated, 1 if already latest or error
    local compose_file="$1"
    local current_image="$2"

    # Map of pinned images to their registry repo and tag prefix
    # Add entries here for any image that uses pinned version tags
    local repo="" prefix=""
    case "$current_image" in
        lscr.io/linuxserver/readarr:nightly-*)
            repo="linuxserver/readarr"
            prefix="nightly"
            ;;
        *)
            return 1  # Not a pinned image, skip
            ;;
    esac

    local registry="lscr.io"
    local image_base="${current_image%%:*}"
    local current_tag="${current_image##*:}"

    log "Resolving latest $prefix tag for $image_base..."
    local latest_tag
    latest_tag=$(resolve_latest_ghcr_tag "$repo" "$prefix")
    if [ $? -ne 0 ] || [ -z "$latest_tag" ]; then
        log_error "Failed to resolve latest tag for $image_base"
        return 1
    fi

    if [ "$current_tag" = "$latest_tag" ]; then
        log "$image_base is already at latest: $latest_tag"
        return 1
    fi

    log "Updating $image_base from $current_tag to $latest_tag"
    sed -i "s|${image_base}:${current_tag}|${image_base}:${latest_tag}|g" "$compose_file"
    return 0
}

update_service() {
    local compose_file="$1"
    local service_name=$(basename "$compose_file" .yaml)

    log "Starting update for $service_name as separate application..."

    # Work directly from Composer directory
    cd "$COMPOSER_DIR"

    local backup_image=$(backup_current_image "$service_name")
    log "Backed up current image: ${backup_image:-none}"

    # Extract image name from compose file
    local new_image=$(grep "image:" "$compose_file" | sed 's/.*image: *\(.*\)/\1/' | tr -d ' ')

    # For pinned-version images, resolve the latest tag and update compose file
    if update_pinned_image_tag "$compose_file" "$new_image"; then
        new_image=$(grep "image:" "$compose_file" | sed 's/.*image: *\(.*\)/\1/' | tr -d ' ')
        log "Updated compose file to new image: $new_image"
    fi

    # Try to pull latest image, but continue with local image if it fails
    log "Attempting to pull latest image for $service_name..."
    local use_local_image=false
    if ! docker pull "$new_image" 2>/dev/null; then
        log "Failed to pull latest image for $service_name, checking for local image..."
        if docker image inspect "$new_image" >/dev/null 2>&1; then
            log "Using existing local image for $service_name: $new_image"
            use_local_image=true
        elif [ -n "$backup_image" ] && docker image inspect "$backup_image" >/dev/null 2>&1; then
            log "Using backup image for $service_name: $backup_image"
            new_image="$backup_image"
            use_local_image=true
        else
            log_error "No local image available for $service_name"
            return 1
        fi
    else
        log "Successfully pulled latest image for $service_name"
    fi
    
    # Stop and remove any existing containers and networks for this service
    log "Stopping and cleaning up existing $service_name application..."
    docker compose -p "$service_name" -f "$(basename "$compose_file")" down --remove-orphans >/dev/null 2>&1 || true
    
    # Start the service as a separate application with project name
    log "Creating new application for $service_name..."
    if docker compose -p "$service_name" -f "$(basename "$compose_file")" up -d --force-recreate; then
        
        if health_check_service "$service_name"; then
            log "Successfully updated $service_name as separate application"
            
            # Only cleanup old images if we pulled a new one
            if [ "$use_local_image" = false ]; then
                log "Cleaning up old images..."
                docker image prune -f >/dev/null 2>&1 || true
            fi
            
            return 0
        else
            log_error "Health check failed for $service_name, attempting rollback..."
            if rollback_service "$compose_file" "$service_name" "$backup_image"; then
                return 2
            else
                return 1
            fi
        fi
    else
        log_error "Failed to create new application for $service_name, attempting rollback..."
        if rollback_service "$compose_file" "$service_name" "$backup_image"; then
            return 2
        else
            return 1
        fi
    fi
}

main() {
    log "Starting auto-update process..."
    
    load_config
    
    if ! check_maintenance_window; then
        exit 0
    fi
    
    if [ ! -d "$COMPOSER_DIR" ]; then
        log_error "Composer directory not found: $COMPOSER_DIR"
        send_slack_notification "❌ Auto-update failed: Composer directory not found" "danger"
        exit 1
    fi
    
    local failed_services=()
    local updated_services=()
    local rolled_back_services=()
    
    for compose_file in "$COMPOSER_DIR"/*.yaml; do
        if [ -f "$compose_file" ]; then
            service_name=$(basename "$compose_file" .yaml)
            update_service "$compose_file"
            result=$?
            
            case $result in
                0)
                    updated_services+=("$service_name")
                    ;;
                2)
                    rolled_back_services+=("$service_name")
                    ;;
                *)
                    failed_services+=("$service_name")
                    ;;
            esac
        fi
    done
    
    log "Update process completed."
    log "Successfully updated: ${updated_services[*]:-none}"
    log "Rolled back: ${rolled_back_services[*]:-none}"
    
    local notification_message=""
    local notification_color="good"
    
    if [ ${#updated_services[@]} -gt 0 ]; then
        notification_message="✅ Successfully updated: ${updated_services[*]}"
    fi
    
    if [ ${#rolled_back_services[@]} -gt 0 ]; then
        if [ -n "$notification_message" ]; then
            notification_message="$notification_message\n"
        fi
        notification_message="${notification_message}⚠️ Rolled back (health check failed): ${rolled_back_services[*]}"
        notification_color="warning"
    fi
    
    if [ ${#failed_services[@]} -gt 0 ]; then
        if [ -n "$notification_message" ]; then
            notification_message="$notification_message\n"
        fi
        notification_message="${notification_message}❌ Failed to update: ${failed_services[*]}"
        notification_color="danger"
        log_error "Failed to update: ${failed_services[*]}"
    fi
    
    if [ -z "$notification_message" ]; then
        notification_message="ℹ️ No services were updated"
        notification_color="warning"
    fi
    
    send_slack_notification "$notification_message" "$notification_color"
    
    if [ ${#failed_services[@]} -gt 0 ]; then
        exit 1
    else
        log "Update process completed successfully!"
    fi
}

main "$@"