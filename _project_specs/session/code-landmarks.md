<!--
UPDATE WHEN:
- Adding new entry points or key files
- Introducing new patterns
- Discovering non-obvious behavior

Helps quickly navigate the codebase when resuming work.
-->

# Code Landmarks

Quick reference to important parts of the codebase.

## Entry Points
| Location | Purpose |
|----------|---------|
| Auto Update/auto-update.sh | Main update orchestration script |
| Auto Update/setup-cron.sh | Installs weekly cron job (Sunday 2AM) |
| Auto Update/image-cleanup.sh | Docker image cleanup (N-1 retention) |
| Auto Update/setup-image-cleanup-cron.sh | Installs image cleanup cron (Sunday 3AM) |

## Service Definitions
| Location | Purpose |
|----------|---------|
| Composer/sonarr.yaml | Sonarr TV show management |
| Composer/radarr.yaml | Radarr movie management |
| Composer/readarr.yaml | Readarr book management |
| Composer/prowlarr.yaml | Prowlarr indexer management |
| Composer/transmission.yaml | Transmission torrent downloader |
| Composer/sabnzbd.yaml | SABnzbd usenet downloader |
| Composer/heimdall.yaml | Heimdall dashboard |
| Composer/filebot.yaml | FileBot media renamer (~1.3GB image) |

## Configuration
| Location | Purpose |
|----------|---------|
| Auto Update/config.yaml | Slack webhook, maintenance windows, exclusions |
| CLAUDE.md | Project guidance and QNAP-specific notes |

## Key Patterns
| Pattern | Example Location | Notes |
|---------|------------------|-------|
| Isolated compose apps | Composer/*.yaml | Each service: `docker compose -p <name> -f <name>.yaml` |
| Standard volume mount | Any Composer/*.yaml | `/share/Public/Complete:/downloads/complete` |
| Download subdirs | CLAUDE.md | radarr/, tv-sonarr/, readarr/ inside /share/Public/Complete/ |

## Gotchas & Non-Obvious Behavior
| Location | Issue | Notes |
|----------|-------|-------|
| Composer/filebot.yaml | Large image | ~1.3GB vs ~200MB for others; may timeout auto-update |
| Auto Update/auto-update.sh | PATH requirement | Must set QNAP docker PATH before running |
| Any container | Volume changes | Requires `--force-recreate` to apply new mounts |
| QNAP Container Station | "Created" status | Use `docker start <name>` if container is stuck |
