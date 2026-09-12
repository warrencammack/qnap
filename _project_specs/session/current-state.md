<!--
CHECKPOINT RULES (from session-management.md):
- Quick update: After any todo completion
- Full checkpoint: After ~20 tool calls or decisions
- Archive: End of session or major feature complete

After each task, ask: Decision made? >10 tool calls? Feature done?
-->

# Current Session State

*Last updated: 2026-09-12 AEST*

## Active Task
None — resolved NAS DNS outage caused by stale Tailscale resolv.conf.

## Current Status
- **Phase**: completed
- **Progress**: scripts/transmission-exe-guard.sh deployed to NAS, cron'd every 5 min, verified clean run against 136 live torrents
- **Blocking Issues**: None

## Context Summary
QNAP NAS media management project. Prior session's fix for rogue .exe torrents was interrupted (Transmission container had restarted ~20h before this session, no trace of that work survived in git/memory). Live audit on 2026-08-01 found no .exe on disk (Complete/Incomplete) or in any active torrent's file manifest, and the iblocklist was intact. Added a dedicated file-manifest guard as a proactive complement to the existing size guard and IP blocklist.

## Files Being Modified
| File | Status | Notes |
|------|--------|-------|
| scripts/transmission-exe-guard.sh | Done | New — scans torrent file manifests for blocked extensions, removes matches, cron'd */5 |
| _project_specs/session/current-state.md | Done | Session checkpoint |
| _project_specs/session/decisions.md | Done | Decision logged |

## Next Steps
1. [ ] Test myQNAPcloud relay access remotely to confirm fix holds
2. [ ] Keep all management ports blocked for new unsolicited inbound sessions

## Key Context to Preserve
- QNAP IP: 10.1.1.5, SSH via `ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5`
- Docker path on QNAP: `/share/CACHEDEV1_DATA/.qpkg/container-station/bin`
- All services use isolated compose projects: `docker compose -p <name> -f <name>.yaml`
- Volume standard: `/share/Public/Complete:/downloads/complete` for all download-aware services
- Plex remote access allowed on TCP 32400; relay continuity via conntrack ESTABLISHED,RELATED
- SSH is always left enabled on this NAS — do not disable after maintenance

## Resume Instructions
To continue this work:
1. Read `_project_specs/session/current-state.md`
2. Check `scripts/nas-lan-only-firewall.sh`
3. Verify live NAS rule with `iptables -S CODEX_LAN_ONLY`
