#!/bin/sh
set -eu

MAX_BYTES="${MAX_BYTES:-10737418240}"
SECRET_FILE="${SECRET_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/secrets/transmission-rpc.env}"
LOG_FILE="${LOG_FILE:-/share/CACHEDEV1_DATA/homes/admin/qnap/logs/transmission-size-guard.log}"
DOCKER="${DOCKER:-/share/CACHEDEV1_DATA/.qpkg/container-station/bin/docker}"
CONTAINER="${CONTAINER:-transmission}"

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
  -e MAX_BYTES="$MAX_BYTES" \
  -e TR_RPC_USER="$TR_RPC_USER" \
  -e TR_RPC_PASS="$TR_RPC_PASS" \
  "$CONTAINER" python3 - <<'PY' | while IFS= read -r line; do log "$line"; done
import json
import os
import urllib.error
import urllib.request

MAX_BYTES = int(os.environ["MAX_BYTES"])
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


fields = [
    "id",
    "name",
    "totalSize",
    "leftUntilDone",
    "percentDone",
    "isFinished",
    "status",
]
response = rpc("torrent-get", {"fields": fields})
torrents = response.get("arguments", {}).get("torrents", [])
offenders = [torrent for torrent in torrents if int(torrent.get("totalSize") or 0) > MAX_BYTES]

if not offenders:
    print(f"ok max_bytes={MAX_BYTES} checked={len(torrents)}")
    raise SystemExit(0)

ids = [torrent["id"] for torrent in offenders]
rpc("torrent-stop", {"ids": ids})
rpc("torrent-remove", {"ids": ids, "delete-local-data": True})

for torrent in offenders:
    size_gb = int(torrent.get("totalSize") or 0) / 1024**3
    left_gb = int(torrent.get("leftUntilDone") or 0) / 1024**3
    percent = float(torrent.get("percentDone") or 0) * 100
    state = "finished" if torrent.get("isFinished") else "incomplete"
    print(
        "removed_oversize "
        f"id={torrent['id']} size_gb={size_gb:.2f} left_gb={left_gb:.2f} "
        f"percent={percent:.1f} state={state} name={torrent['name']}"
    )

print(f"removed_count={len(offenders)} max_bytes={MAX_BYTES} checked={len(torrents)}")
PY
