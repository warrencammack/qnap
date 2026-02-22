# Project Overview

## Vision
QNAP NAS media management system using Docker Compose services with automated container updates, rollback protection, and Slack notifications.

## Goals
- [ ] Keep all media services (Sonarr, Radarr, Readarr, Prowlarr, SABnzbd, Transmission, Heimdall, FileBot) updated and running
- [ ] Automate weekly container updates with safe rollback
- [ ] Maintain Slack notification reporting on update status
- [ ] Keep Docker image storage optimized via cleanup automation

## Non-Goals
- Running on non-QNAP hardware (QNAP-specific paths and Container Station assumed)
- Cloud-based deployment

## Success Metrics
- All services stay updated with latest images
- Zero unrecovered failed updates (rollback kicks in when needed)
- Slack notifications reliably delivered each update cycle
- Docker image disk usage stays manageable
