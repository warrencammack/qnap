# QNAP Media Server Docker Compose Files

This repository contains Docker Compose configuration files for running various media management and automation services on a QNAP NAS system.

## Services Included

- **FileBot**: Automated file organization and renaming tool
- **Heimdall**: Application dashboard and launcher
- **Prowlarr**: Indexer manager/proxy for Sonarr, Radarr, etc.
- **Radarr**: Movie collection manager
- **Readarr**: Book collection manager
- **SABnzbd**: Usenet downloader
- **Sonarr**: TV series collection manager
- **Transmission**: BitTorrent client

## Usage

Each service has its own YAML file that can be deployed using Docker Compose:

```bash
docker-compose -f <service-name>.yaml up -d
```

For example, to start Sonarr:

```bash
docker-compose -f sonarr.yaml up -d
```

## Configuration

All services are configured with:
- PUID/PGID settings for proper file permissions
- Australia/Sydney timezone
- Persistent storage volumes mapped to QNAP shared folders
- Network configuration for inter-container communication
- Appropriate port mappings for web interfaces

## Directory Structure

The services use the following directory structure on the QNAP NAS:

- `/share/Container/containerapp/<service-name>`: Configuration files
- `/share/Multimedia/movies`: Movie library
- `/share/Multimedia/tv`: TV series library
- `/share/Public/Complete`: Completed downloads

## Network Configuration

Services are configured with two networks:
- A default bridge network
- A shared network named `app_network` for inter-service communication

## Notes

- Media services should not run in privileged mode unless explicitly documented and approved
- UMASK is set per service; download clients use group-writable settings for shared imports
- SKIP_CHOWN is enabled where needed to avoid ownership change operations

## Requirements

- QNAP NAS with Container Station installed
- Docker and Docker Compose
- Sufficient storage space for media libraries
