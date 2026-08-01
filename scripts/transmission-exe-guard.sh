#!/bin/sh
set -eu

SECRET_FILE="${SECRET_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/secrets/transmission-rpc.env}"
LOG_FILE="${LOG_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/transmission-exe-guard.log}"
DOCKER="${DOCKER:-/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker}"
CONTAINER="${CONTAINER:-transmission}"
BLOCKED_EXT="${BLOCKED_EXT:-.exe,.scr,.bat,.cmd,.msi,.vbs,.vbe,.jse,.js,.ps1,.jar,.com,.pif,.lnk,.wsf}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

if [ ! -r "$SECRET_FILE" ]; then
  log "missing secret file: $SECRET_FILE"
  exit 1
fi

# shellcheck disable=SC1090
. "$SECRET_FILE"

if [ -z "${TR_RPC_USER:-}" ] || [ -z "${TR_RPC_PASS:-}" ]; then
  log "missing TR_RPC_USER or TR_RPC_PASS"
  exit 1
fi

"$DOCKER" exec -i \
  -e BLOCKED_EXT="$BLOCKED_EXT" \
  -e TR_RPC_USER="$TR_RPC_USER" \
  -e TR_RPC_PASS="$TR_RPC_PASS" \
  "$CONTAINER" python3 - <<'PY' | while IFS= read -r line; do log "$line"; done
import json
import os
import urllib.error
import urllib.request

BLOCKED_EXT = tuple(e.strip().lower() for e in os.environ["BLOCKED_EXT"].split(",") if e.strip())
USER = os.environ["TR_RPC_USER"]
RPC_PASS = os.environ["TR_RPC_PASS"]
URL = "http://127.0.0.1:9091/transmission/rpc"

manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
manager.add_password(None, URL, USER, RPC_PASS)
opener = urllib.request.build_opener(urllib.request.HTTPBasicAuthHandler(manager))
session_id = None


def rpc(method, args=None):
    global session_id
    payload = json.dumps({"method": method, "arguments": args or {}}).encode()
    headers = {"Content-Type": "application/json"}
    if session_id:
        headers["X-Transmission-Session-Id"] = session_id
    request = urllib.request.Request(URL, data=payload, headers=headers)
    try:
        return json.loads(opener.open(request, timeout=15).read().decode())
    except urllib.error.HTTPError as exc:
        new_session = exc.headers.get("X-Transmission-Session-Id")
        if exc.code == 409 and new_session:
            session_id = new_session
            return rpc(method, args)
        raise


fields = ["id", "name", "files"]
response = rpc("torrent-get", {"fields": fields})
torrents = response.get("arguments", {}).get("torrents", [])

offenders = []
for torrent in torrents:
    hits = [f["name"] for f in torrent.get("files", []) if f["name"].lower().endswith(BLOCKED_EXT)]
    if hits:
        offenders.append((torrent, hits))

if not offenders:
    print(f"ok blocked_ext={','.join(BLOCKED_EXT)} checked={len(torrents)}")
    raise SystemExit(0)

ids = [torrent["id"] for torrent, _ in offenders]
rpc("torrent-stop", {"ids": ids})
rpc("torrent-remove", {"ids": ids, "delete-local-data": True})

for torrent, hits in offenders:
    print(
        "removed_exe_payload "
        f"id={torrent['id']} name={torrent['name']} matched_files={';'.join(hits)}"
    )

print(f"removed_count={len(offenders)} blocked_ext={','.join(BLOCKED_EXT)} checked={len(torrents)}")
PY
