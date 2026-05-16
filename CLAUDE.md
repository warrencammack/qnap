# RESPONSE RULES
- 3-6 word sentences max
- No preamble, no pleasantries
- Drop articles (a, an, the)
- Tool first, result, stop. No narration.
- Skip confirmations. Just do.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Skills
Read and follow these skills before writing any code:
- .claude/skills/base/SKILL.md
- .claude/skills/security/SKILL.md
- .claude/skills/project-tooling/SKILL.md
- .claude/skills/session-management/SKILL.md

## Repository Overview

This is a QNAP NAS media management system with two main components:

1. **Docker Compose Services** (`/Composer/`): Individual YAML files for media management applications
2. **Auto-Update System** (`/Auto Update/`): Automated container update system with rollback and notifications

## Architecture

### Media Services (`/Composer/`)
- **Services**: Sonarr, Radarr, Readarr, Prowlarr, SABnzbd, Transmission, Heimdall, FileBot, FlareSolverr
- **Network**: Uses shared `app_network` for inter-service communication plus default bridge
- **Storage**: Persistent volumes mapped to QNAP shared folders (`/share/Container/containerapp/`, `/share/Multimedia/`, `/share/Public/Complete/`)
- **Configuration**: All services use PUID=1000, PGID=100, TZ=Australia/Sydney
- **Image Sizes**: Most services ~170-210MB, **FileBot is ~1.3GB** (significantly larger download time)

### Auto-Update System (`/Auto Update/`)
- **Main Script**: `auto-update.sh` - orchestrates updates with backup/rollback capability
- **Configuration**: `config.yaml` - Slack notifications, maintenance windows, exclusions
- **Cron Setup**: `setup-cron.sh` - installs weekly update schedule (Sunday 2AM)
- **Logging**: Comprehensive logging to `auto-update.log` and `cron.log`
- **Isolation**: Each YAML file runs as a separate application with isolated containers and networks

## Common Commands

### Deploy Individual Services
```bash
# Deploy a specific service as separate application (CORRECT METHOD)
cd /share/CACHEDEV1_DATA/homes/admin/qnap/Composer
docker compose -p <service-name> -f <service-name>.yaml up -d --force-recreate

# Examples: 
docker compose -p sonarr -f sonarr.yaml up -d --force-recreate
docker compose -p heimdall -f heimdall.yaml up -d --force-recreate

# FileBot (large image - expect longer download time)
docker compose -p filebot -f filebot.yaml up -d --force-recreate

# If container is stuck in "Created" status, manually start it:
docker start <service-name>
```

### Auto-Update System
```bash
# Connect to QNAP first
ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5

# Navigate to Auto Update directory
cd "/share/homes/admin/qnap/Auto Update"

# Make scripts executable (first time setup)
chmod +x auto-update.sh setup-cron.sh image-cleanup.sh setup-image-cleanup-cron.sh

# Test update manually (ignores maintenance window)
./auto-update.sh

# Install weekly cron job (Sunday 2AM)
./setup-cron.sh

# View update logs
tail -f auto-update.log

# View cron logs
tail -f cron.log

# Check cron status
crontab -l
```

### Image Cleanup System
```bash
# Test image cleanup manually (ignores maintenance window)
./image-cleanup.sh

# Install weekly image cleanup cron job (Sunday 3AM)
./setup-image-cleanup-cron.sh

# View image cleanup logs
tail -f image-cleanup.log

# View image cleanup cron logs
tail -f image-cleanup-cron.log
```

### Configuration
```bash
# Connect to QNAP first (uses SSH key authentication)
ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5

# Edit auto-update configuration
nano config.yaml

# Edit individual service configs
nano Composer/<service-name>.yaml
```

## QNAP-Specific Notes

- **QNAP IP Address**: 10.1.1.5
- **SSH Connection**: Always use SSH with key authentication: `ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5`
- **SSH Key**: Uses `~/.ssh/qnap_rsa_key` for authentication
- **Docker Path**: Auto-update script sets PATH to `/share/CACHEDEV1_DATA/.qpkg/container-station/bin`
- **File Paths**: Services expect QNAP shared folder structure (`/share/Container/`, `/share/Multimedia/`, `/share/Public/`)
- **Permissions**: Services run with PUID=1000, PGID=100 for proper NAS permissions
- **Network**: All services use `app_network` for inter-container communication

## Security Best Practices

### SSH Service Management
**⚠️ IMPORTANT: Always manage SSH service state for security**

```bash
# BEFORE starting work - Enable SSH service
# 1. Log into QNAP web interface (https://10.1.1.5)
# 2. Go to Control Panel > Network & File Services > Telnet / SSH
# 3. Enable "Allow SSH connection" 
# 4. Click "Apply"

# AFTER completing work - Disable SSH service
# 1. Return to Control Panel > Network & File Services > Telnet / SSH  
# 2. Disable "Allow SSH connection"
# 3. Click "Apply"
```

### Security Reminders
- **SSH Access**: Only enable SSH when actively needed for maintenance
- **Session Management**: Always disable SSH after completing administrative tasks
- **Key Authentication**: SSH is configured for key-based authentication only (more secure than passwords)
- **Network Exposure**: Keeping SSH disabled reduces attack surface when not performing maintenance
- **Regular Updates**: Use the automated update system to keep all services patched and secure

## Download System Architecture

- **Transmission**: Downloads files to `/share/Public/Complete` by default
- **Service-Specific Downloads**: Each service gets its own subdirectory:
  - Radarr (movies): `/share/Public/Complete/radarr/`
  - Sonarr (TV): `/share/Public/Complete/tv-sonarr/`
  - Readarr (books): `/share/Public/Complete/readarr/`
- **Standard Volume Mount Configuration**: ALL services must use identical volume mounts:
  ```yaml
  volumes:
    - /share/Public/Complete:/downloads/complete
  ```
- **Services Using This Standard**:
  - **Transmission**: `/share/Public/Complete:/downloads/complete`
  - **Radarr**: `/share/Public/Complete:/downloads/complete`
  - **Sonarr**: `/share/Public/Complete:/downloads/complete`
  - **Readarr**: `/share/Public/Complete:/downloads/complete`
  - **SABnzbd**: `/share/Public/Complete:/downloads/complete`
- **Path Consistency**: Critical requirement - ALL containers must see identical paths:
  - Sonarr sees: `/downloads/complete/tv-sonarr/show.mkv`
  - Radarr sees: `/downloads/complete/radarr/movie.mkv`
  - Readarr sees: `/downloads/complete/readarr/book.epub`
- **Case Sensitivity**: Linux paths are case-sensitive - use exact case: `Public/Complete` not `public/complete`
- **Container Restart Required**: Volume mount changes require `--force-recreate` to apply

## Key Features

- **Automated Updates**: Weekly container updates with health checks
- **Rollback Protection**: Automatic rollback if containers fail to start properly
- **Maintenance Windows**: Updates only run during configured time windows (2-6 AM by default)
- **Slack Notifications**: Detailed update reports sent to Slack webhook
- **Service Exclusions**: Ability to exclude specific services from auto-updates
- **Image Cleanup**: Removes unused Docker images after successful updates
- **Application Isolation**: Each service runs as a separate application on QNAP Container Station (not combined into single "composer" app)
- **Automated Image Management**: Weekly cleanup of outdated Docker images (N-1 retention policy)
- **Smart Retention**: Keeps current + previous version of each image, removes older versions
- **Space Optimization**: Automatically reclaims disk space from unused Docker images and build cache

## Important Container Management Notes

- **Configuration Changes Require Restart**: When modifying YAML files, containers must be restarted with `--force-recreate` to apply new volume mounts, environment variables, or other configuration changes
- **Volume Mounts Are Cached**: Docker caches volume mount configurations - simply updating YAML files without restarting containers will not apply new volume mappings
- **Force Recreate Command**: Use `docker compose -p <service> -f <file>.yaml down && docker compose -p <service> -f <file>.yaml up -d --force-recreate` to ensure changes are applied

## NAS Update Best Practices

### Manual Service Updates
```bash
# Always work from the Composer directory
cd /share/CACHEDEV1_DATA/homes/admin/qnap/Composer

# Set Docker path for QNAP Container Station
export PATH="/share/CACHEDEV1_DATA/.qpkg/container-station/bin:$PATH"

# Update all services manually (if auto-update fails)
for service in heimdall sonarr radarr readarr prowlarr transmission sabnzbd filebot; do
    docker compose -p $service -f $service.yaml up -d --force-recreate
done
```

### Troubleshooting Failed Updates
- **Auto-update script timing out**: Manual deployment usually works - use individual service commands above
- **Container stuck in "Created" status**: Use `docker start <container-name>` to manually start
- **Image conflicts during cleanup**: Keep `latest` + one backup image per service, remove duplicate tags safely
- **Missing images after cleanup**: Tag backup images as `latest` or re-pull during next update cycle

### Docker Image Management
```bash
# Check current image count and identify duplicates
docker images | wc -l
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'

# Safe cleanup - remove duplicate tags (not the underlying images)
docker rmi <repository>:<old-backup-tag>

# System cleanup (removes unused containers, networks, dangling images)
docker system prune -f

# Force cleanup all unused images (more aggressive)
docker system prune -a -f
```

### Performance Considerations
- **QNAP system slowdowns**: Docker operations can timeout during high I/O - retry manual commands if auto-update fails
- **Container startup delays**: Some services (SABnzbd, Readarr) take longer to initialize - check status with `docker ps -a`
- **Network timeouts**: Image pulls may fail - use existing local images or retry during low-usage periods
- **FileBot image size**: At ~1.3GB (vs ~200MB for other services), FileBot takes significantly longer to download
  - Initial deployment or updates may timeout standard 2-minute windows
  - Plan for 5-10 minute download time depending on internet speed
  - Consider manual deployment during off-peak hours for better reliability

## Installation Locations (QNAP)

```
/share/homes/admin/qnap/
├── Auto Update/          # Update system
│   ├── auto-update.sh   # Main update script
│   ├── config.yaml      # Configuration
│   ├── setup-cron.sh    # Cron installer
│   └── *.log           # Log files
└── Composer/            # Service definitions
    ├── sonarr.yaml     # Individual service configs
    ├── radarr.yaml
    └── ...
```