#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSER_DIR="$PROJECT_ROOT/Composer"
LOG_FILE="$SCRIPT_DIR/auto-update.log"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

SLACK_WEBHOOK_URL=""
SLACK_CHANNEL=""
SLACK_USERNAME="Docker Auto-Update"

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
    
    local payload="{
        \"username\": \"$SLACK_USERNAME\",
        \"attachments\": [
            {
                \"color\": \"$color\",
                \"title\": \"QNAP Docker Auto-Update\",
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
    
    cd "$COMPOSER_DIR"
    
    if [ -n "$backup_image" ]; then
        sed -i.bak "s|image: .*|image: $backup_image|" "$compose_file"
        
        if docker-compose -f "$compose_file" up -d --force-recreate; then
            log "Successfully rolled back $service_name"
            return 0
        else
            log_error "Failed to rollback $service_name"
            mv "$compose_file.bak" "$compose_file"
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

update_service() {
    local compose_file="$1"
    local service_name=$(basename "$compose_file" .yaml)
    
    log "Starting update for $service_name..."
    
    cd "$COMPOSER_DIR"
    
    local backup_image=$(backup_current_image "$service_name")
    log "Backed up current image: ${backup_image:-none}"
    
    log "Pulling latest image for $service_name..."
    if docker-compose -f "$compose_file" pull; then
        log "Successfully pulled latest image for $service_name"
        
        log "Recreating container for $service_name..."
        if docker-compose -f "$compose_file" up -d --force-recreate; then
            
            if health_check_service "$service_name"; then
                log "Successfully updated $service_name"
                
                log "Cleaning up old images..."
                docker image prune -f >/dev/null 2>&1 || true
                
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
            log_error "Failed to recreate container for $service_name, attempting rollback..."
            if rollback_service "$compose_file" "$service_name" "$backup_image"; then
                return 2
            else
                return 1
            fi
        fi
    else
        log_error "Failed to pull latest image for $service_name"
        return 1
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
            result=$(update_service "$compose_file"; echo $?)
            
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