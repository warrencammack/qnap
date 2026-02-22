<!--
LOG DECISIONS WHEN:
- Choosing between architectural approaches
- Selecting libraries or tools
- Making security-related choices
- Deviating from standard patterns

This is append-only. Never delete entries.
-->

# Decision Log

Track key architectural and implementation decisions.

## Format
```
## [YYYY-MM-DD] Decision Title

**Decision**: What was decided
**Context**: Why this decision was needed
**Options Considered**: What alternatives existed
**Choice**: Which option was chosen
**Reasoning**: Why this choice was made
**Trade-offs**: What we gave up
**References**: Related code/docs
```

---

## [2026-02-22] Application Isolation Strategy

**Decision**: Each service runs as a separate Docker Compose application
**Context**: QNAP Container Station groups containers by compose project name
**Options Considered**: Single compose file with all services vs individual files per service
**Choice**: Individual YAML files, each deployed with `-p <service-name>`
**Reasoning**: Cleaner Container Station UI, independent restarts, isolated networks
**Trade-offs**: More files to manage; update script must loop over each service
**References**: Composer/*.yaml, Auto Update/auto-update.sh

## [2026-02-22] Volume Mount Standard

**Decision**: All download-aware services mount `/share/Public/Complete:/downloads/complete`
**Context**: Sonarr/Radarr/Readarr need to see the same paths as Transmission/SABnzbd
**Options Considered**: Service-specific mount paths vs unified standard path
**Choice**: Unified `/downloads/complete` inside all containers
**Reasoning**: Path consistency required for cross-service file handoff; Linux paths are case-sensitive
**Trade-offs**: All services see all download subdirectories (not just their own)
**References**: CLAUDE.md Download System Architecture section
