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
- **Phase**: blocked
- **Progress**: M5 LAN, Tailscale, public Plex, Qfinder, and WOL checks completed
- **Blocking Issues**: NAS is unreachable at `10.1.1.5`; physical power/network state likely needs checking.

## Context Summary
QNAP NAS media management project. On 2026-09-09, M5 had LAN IP `10.1.1.127` and gateway `10.1.1.1`, but `10.1.1.5` had no ARP response, ping failed, SSH timed out, and Plex `32400` timed out. Tailscale showed `NAS5E8063` offline, last seen 2026-09-03. Qfinder WOL metadata confirmed `NAS5E8063` at `10.1.1.5` with MAC `24-5E-BE-5E-80-63`; WOL packets were sent to known QNAP MACs, but the NAS did not wake.

## Files Being Modified
| File | Status | Notes |
|------|--------|-------|
| _project_specs/session/current-state.md | Done | Session checkpoint |
| memory/projects/qnap.md | Done | Durable NAS access note |
| memory/home-tech.md | Done | QNAP guardrail note |
| Use cases for local models.MD | Done | Physical access blocker record |

## Next Steps
1. [ ] Check NAS physical power, Ethernet, switch/eero port, and front-panel link/activity lights
2. [ ] Once reachable, verify `http://10.1.1.5:32400/identity`
3. [ ] Verify `CODEX_LAN_ONLY` still allows TCP 32400

## Key Context to Preserve
- QNAP IP: 10.1.1.5, SSH via `ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5`
- QNAP current WOL record: `NAS5E8063`, model `TS-453D`, MAC `24-5E-BE-5E-80-63`
- Docker path on QNAP: `/share/CACHEDEV1_DATA/.qpkg/container-station/bin`
- All services use isolated compose projects: `docker compose -p <name> -f <name>.yaml`
- Volume standard: `/share/Public/Complete:/downloads/complete` for all download-aware services
- Plex remote access must stay allowed on TCP 32400 unless there is an imminent cyber threat
- Relay continuity uses conntrack ESTABLISHED,RELATED
- SSH is always left enabled on this NAS — do not disable after maintenance

## Resume Instructions
To continue this work:
1. Read `_project_specs/session/current-state.md`
2. Confirm NAS is physically powered and cabled
3. Retry ping, SSH, Plex identity, and Tailscale status
