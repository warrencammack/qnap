# QNAP Docker Auto-Update System

Automatically pulls the latest Docker images and updates your QNAP Container Station applications on a weekly schedule.

## Features

- ✅ **Automatic Updates**: Pulls latest images and recreates containers
- 🔄 **Rollback Support**: Automatically rolls back if health checks fail
- ⏰ **Maintenance Window**: Only updates during specified time windows
- 💬 **Slack Notifications**: Sends detailed update reports to Slack
- 📝 **Comprehensive Logging**: Detailed logs of all update operations
- 🛡️ **Health Checks**: Verifies containers are running properly after updates

## Quick Setup

1. **Configure Slack webhook** (optional):
   ```bash
   nano config.yaml
   # Update webhook_url with your Slack webhook URL
   ```

2. **Test the update script**:
   ```bash
   ./auto-update.sh
   ```

3. **Install weekly cron job**:
   ```bash
   ./setup-cron.sh
   ```

## Configuration

Edit `config.yaml` to customize:

### Slack Notifications
```yaml
slack:
  enabled: true
  webhook_url: "YOUR_SLACK_WEBHOOK_URL_HERE"
  channel: "#infrastructure"
  username: "Docker Auto-Update"
```

### Maintenance Window
```yaml
update:
  maintenance_window:
    start_hour: 2    # 2:00 AM
    end_hour: 6      # 6:00 AM
    enforce: true    # Set to false to disable
```

### Other Settings
- `exclude_services`: List of services to skip
- `cleanup_images`: Remove unused images after update
- `startup_timeout`: Maximum wait time for container startup

## Manual Usage

```bash
# Run update immediately (ignores maintenance window)
./auto-update.sh

# View logs
tail -f auto-update.log

# Check cron status
crontab -l
```

## How It Works

1. **Backup**: Creates tagged backup of current images
2. **Pull**: Downloads latest images from repositories
3. **Update**: Recreates containers with new images
4. **Health Check**: Verifies containers are running properly
5. **Rollback**: Restores previous version if health check fails
6. **Notify**: Sends Slack notification with results
7. **Cleanup**: Removes unused Docker images

## Supported Services

Currently configured for:
- Sonarr
- Radarr  
- Readarr
- Prowlarr
- SABnzbd
- Transmission
- Heimdall

## Troubleshooting

### Update Failures
- Check `auto-update.log` for detailed error messages
- Verify Docker and docker-compose are installed
- Ensure QNAP user has Docker permissions

### Slack Notifications Not Working
- Verify webhook URL is correct in `config.yaml`
- Test webhook manually with curl
- Check firewall/network restrictions

### Maintenance Window Issues
- Verify time zone settings match your QNAP
- Check `enforce: false` to disable window temporarily
- Review cron schedule vs. maintenance window

## File Structure

```
Auto Update/
├── auto-update.sh      # Main update script
├── config.yaml         # Configuration file
├── setup-cron.sh       # Cron installation script
├── auto-update.log     # Update logs
├── cron.log           # Cron execution logs
└── README.md          # This file
```