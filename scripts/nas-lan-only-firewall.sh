#!/bin/sh
set -eu

LOG_FILE="${LOG_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/nas-lan-only-firewall.log}"
CHAIN="${CHAIN:-CODEX_LAN_ONLY}"
PARENT_CHAIN="${PARENT_CHAIN:-QUFIREWALL}"
GATEWAY_IP="${GATEWAY_IP:-10.1.1.1}"
IPTABLES="${IPTABLES:-iptables -w}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

$IPTABLES -N "$CHAIN" 2>/dev/null || true
$IPTABLES -F "$CHAIN"

# Allow relay/session continuity without opening new unsolicited inbound sessions.
$IPTABLES -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

# Plex remote streaming is intentionally public via router port-forward.
$IPTABLES -A "$CHAIN" -p tcp --dport 32400 -j RETURN

# Some routers can SNAT port-forwarded WAN traffic so the NAS sees it as the
# gateway address. Do not trust gateway-sourced sessions to sensitive services.
$IPTABLES -A "$CHAIN" -s "$GATEWAY_IP" -p tcp -m multiport --dports 22,139,443,445,2376,4431,7878,8080,8081,8181,8191,8765,8787,8989,9091 -j LOG --log-prefix "CODEX_DROP_GW_TCP " --log-level 4
$IPTABLES -A "$CHAIN" -s "$GATEWAY_IP" -p tcp -m multiport --dports 9696,9812,51413 -j LOG --log-prefix "CODEX_DROP_GW_TCP " --log-level 4
$IPTABLES -A "$CHAIN" -s "$GATEWAY_IP" -p tcp -m multiport --dports 22,139,443,445,2376,4431,7878,8080,8081,8181,8191,8765,8787,8989,9091 -j DROP
$IPTABLES -A "$CHAIN" -s "$GATEWAY_IP" -p tcp -m multiport --dports 9696,9812,51413 -j DROP
$IPTABLES -A "$CHAIN" -s "$GATEWAY_IP" -p udp -m multiport --dports 500,4500,51413,32410,32411,32412,32413,32414 -j LOG --log-prefix "CODEX_DROP_GW_UDP " --log-level 4
$IPTABLES -A "$CHAIN" -s "$GATEWAY_IP" -p udp -m multiport --dports 500,4500,51413,32410,32411,32412,32413,32414 -j DROP

# Keep local management, QVPN clients, Docker/container bridges, and RFC1918 LANs working.
$IPTABLES -A "$CHAIN" -i lo -j RETURN
$IPTABLES -A "$CHAIN" -s 10.1.1.0/24 -j RETURN
$IPTABLES -A "$CHAIN" -s 10.6.0.0/24 -j RETURN
$IPTABLES -A "$CHAIN" -s 10.0.0.0/8 -j RETURN
$IPTABLES -A "$CHAIN" -s 172.16.0.0/12 -j RETURN
$IPTABLES -A "$CHAIN" -s 192.168.0.0/16 -j RETURN

# Anything else trying to open a new inbound session to the NAS is not trusted.
$IPTABLES -A "$CHAIN" -j LOG --log-prefix "CODEX_DROP_IN " --log-level 4
$IPTABLES -A "$CHAIN" -j DROP

$IPTABLES -N "$PARENT_CHAIN" 2>/dev/null || true
if ! $IPTABLES -C "$PARENT_CHAIN" -j "$CHAIN" 2>/dev/null; then
  $IPTABLES -I "$PARENT_CHAIN" 1 -j "$CHAIN"
  log "installed $CHAIN jump in $PARENT_CHAIN"
else
  log "refreshed $CHAIN rules"
fi
