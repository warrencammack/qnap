#!/bin/sh
set -eu

# Fail-closed VPN guard for download clients.
# Transmission and SABnzbd may talk to LAN/private services directly, but public
# internet egress must leave through the QVPN client interface.

LOG_FILE="${LOG_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/download-clients-vpn-guard.log}"
CHAIN="${CHAIN:-CODEX_DOWNLOAD_VPN_ONLY}"
PARENT_CHAIN="${PARENT_CHAIN:-DOCKER-USER}"
VPN_IF="${VPN_IF:-tun2001}"
DOCKER_BIN="${DOCKER_BIN:-/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker}"
CLIENTS="${CLIENTS:-transmission sabnzbd}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

iptables -N "$CHAIN" 2>/dev/null || true
iptables -F "$CHAIN"

vpn_up=0
if ip link show "$VPN_IF" >/dev/null 2>&1; then
  vpn_up=1
fi

client_ips=""
for client in $CLIENTS; do
  ips=$("$DOCKER_BIN" inspect "$client" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null || true)
  if [ -z "$ips" ]; then
    log "WARN no container IPs found for $client"
    continue
  fi
  for ip in $ips; do
    case "$ip" in
      ''|'<no'*) continue ;;
    esac
    client_ips="$client_ips $ip"
  done
done

for ip in $client_ips; do
  # Keep LAN, VPN client network, Docker bridges, and other RFC1918/container
  # traffic working so the Arr apps and web UIs can still control the clients.
  iptables -A "$CHAIN" -s "$ip/32" -d 10.0.0.0/8 -j RETURN
  iptables -A "$CHAIN" -s "$ip/32" -d 172.16.0.0/12 -j RETURN
  iptables -A "$CHAIN" -s "$ip/32" -d 192.168.0.0/16 -j RETURN
  iptables -A "$CHAIN" -s "$ip/32" -d 224.0.0.0/4 -j RETURN

  if [ "$vpn_up" = "1" ]; then
    iptables -A "$CHAIN" -s "$ip/32" -o "$VPN_IF" -j RETURN
  fi

  iptables -A "$CHAIN" -s "$ip/32" -j LOG --log-prefix "CODEX_VPN_BLOCK " --log-level 4
  iptables -A "$CHAIN" -s "$ip/32" -j REJECT
done

iptables -N "$PARENT_CHAIN" 2>/dev/null || true
if ! iptables -C "$PARENT_CHAIN" -j "$CHAIN" 2>/dev/null; then
  iptables -I "$PARENT_CHAIN" 1 -j "$CHAIN"
  log "installed $CHAIN jump in $PARENT_CHAIN vpn_if=$VPN_IF vpn_up=$vpn_up ips=$client_ips"
else
  log "refreshed $CHAIN vpn_if=$VPN_IF vpn_up=$vpn_up ips=$client_ips"
fi
