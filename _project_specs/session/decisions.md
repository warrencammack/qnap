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

## [2026-08-01] RAID Scrub Rescheduled to Last Sunday of Month

**Decision**: Disable QNAP's native monthly data-scrubbing schedule (fixed day-of-month) and replace it with `scripts/raid-scrub-last-sunday.sh`, cron'd every Sunday at 2:15am, which only triggers `storage_util --data_scrubbing` when the current Sunday is the last one in the month.
**Context**: Native scrub was fixed to the 1st of the month (`storage_util --set_data_scrubbing_schedule ... type=3,month_day=1`). Requested change to "last Sunday of the month" — `storage_util` only supports type 1 (daily), 2 (weekly, fixed weekday), or 3 (monthly, fixed day-of-month); no "Nth/last weekday of month" option exists natively.
**Options Considered**: Approximate with a fixed month_day near month-end (e.g. 28th); wrapper script gating the real trigger.
**Choice**: Wrapper script, scheduled every Sunday, checks whether `date +%m` differs from `date -d '+7 days' +%m` (i.e. no more Sundays left this month) before calling `storage_util --data_scrubbing raid_id=-1`.
**Reasoning**: Exact date-string match to "last Sunday" requested; a fixed day-of-month approximation would drift relative to the actual weekday. Disabling via `storage_util --set_data_scrubbing_schedule enable=0,...` (rather than hand-editing crontab) let QNAP's own daemon comment out its crontab line correctly, avoiding a stale duplicate schedule.
**Trade-offs**: Scrub timing now depends on cron firing every Sunday (52 no-op runs/year, cheap) rather than a single native monthly entry.
**References**: scripts/raid-scrub-last-sunday.sh

## [2026-08-01] Transmission exe-payload Guard

**Decision**: Add `scripts/transmission-exe-guard.sh`, cron'd every 5 min, to auto-remove torrents whose file manifest contains executable/script payloads (.exe, .scr, .bat, .cmd, .msi, .vbs, .vbe, .jse, .js, .ps1, .jar, .com, .pif, .lnk, .wsf).
**Context**: Prior session was interrupted mid-fix for rogue .exe files being pulled in via torrents; no trace of that work survived (no script, commit, or memory note). Live audit found no .exe on disk or in the 136 active torrents' file lists, and Transmission's iblocklist was intact — so this is a proactive complement, not a reactive cleanup.
**Options Considered**: Rely on existing iblocklist IP blocklist only; extend `transmission-size-guard.sh` size checks; add a dedicated extension-based file-manifest guard.
**Choice**: Dedicated guard modeled on `transmission-size-guard.sh`, checking the RPC `files` field per torrent (not just the torrent name, since payloads are often bundled inside otherwise legitimate-looking video torrents).
**Reasoning**: IP blocklists don't inspect payload contents; size guard only catches oversized torrents. A file-extension check on the manifest catches disguised/bundled executables regardless of torrent name or size.
**Trade-offs**: Removes the whole torrent (not just the offending file) if any blocked extension is found — acceptable since a bundled executable indicates the source is untrustworthy.
**References**: scripts/transmission-exe-guard.sh, scripts/transmission-size-guard.sh

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

## [2026-06-21] myQNAPcloud Relay — ESTABLISHED,RELATED Return Rule

**Decision**: Add `conntrack --ctstate ESTABLISHED,RELATED -j RETURN` as first rule in `CODEX_LAN_ONLY`
**Context**: myQNAPcloud relay traffic was being caught by the catch-all DROP because the chain had no rule allowing reply packets for already-permitted sessions.
**Options Considered**: Open specific relay ports by IP range, disable catch-all drop, or add a conntrack state return.
**Choice**: Conntrack state return at top of chain, before all other rules.
**Reasoning**: Stateful conntrack tracks sessions permitted by earlier rules (LAN, Plex); only reply/related packets are returned — no new unsolicited inbound sessions are opened. Gateway drops and catch-all drop remain unchanged.
**Trade-offs**: None material. Conntrack is already used by the kernel for all tracked sessions.
**References**: scripts/nas-lan-only-firewall.sh, Asana GID 1215871620590795

## [2026-06-14] Plex Remote Access Exception

**Decision**: Allow inbound TCP 32400 through the NAS LAN-only firewall
**Context**: Plex remote streaming needs TCP 32400 reachable while travelling, but `CODEX_LAN_ONLY` previously dropped that port.
**Options Considered**: Disable the LAN-only firewall, allow all Plex-related ports, or add a single TCP 32400 exception.
**Choice**: Add a TCP 32400 `RETURN` rule before LAN-only drops and remove 32400 from gateway drop lists.
**Reasoning**: Keeps management and download service ports blocked while restoring Plex remote access.
**Trade-offs**: Plex is now exposed through the router port-forward and must rely on Plex authentication and patching.
**References**: scripts/nas-lan-only-firewall.sh
