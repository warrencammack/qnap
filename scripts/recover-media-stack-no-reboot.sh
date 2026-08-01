#!/bin/sh
set -eu

if [ ! -x /sbin/getcfg ]; then
  echo "This script must run on the QNAP NAS as admin." >&2
  exit 1
fi

QPKG_DIR=$(/sbin/getcfg container-station Install_Path -f /etc/config/qpkg.conf)
if [ -z "$QPKG_DIR" ] || [ ! -d "$QPKG_DIR" ]; then
  echo "Container Station install path was not found. Run this on the QNAP NAS as admin." >&2
  exit 1
fi
SUPERVISOR_CONF="$QPKG_DIR/etc/supervisord.conf"
SUPERVISORCTL="$QPKG_DIR/bin/supervisorctl"

export PATH="$QPKG_DIR/usr/bin:$QPKG_DIR/bin:$PATH"

echo "== RAID status =="
cat /proc/mdstat | sed -n '1,12p'

echo
echo "== Container Station supervisor =="
"$SUPERVISORCTL" -c "$SUPERVISOR_CONF" status || true

echo
echo "== Starting normal app Docker if needed =="
if [ ! -S /var/run/docker.sock ]; then
  "$SUPERVISORCTL" -c "$SUPERVISOR_CONF" start docker || true
else
  if ! docker version >/dev/null 2>&1; then
    "$SUPERVISORCTL" -c "$SUPERVISOR_CONF" start docker || true
  else
    echo "Docker socket is already responding."
  fi
fi

sleep 10

echo
echo "== Docker supervisor status =="
"$SUPERVISORCTL" -c "$SUPERVISOR_CONF" status docker || true

echo
echo "== Running media containers =="
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' || true

echo
echo "== Listening media ports =="
netstat -lntp 2>/dev/null | egrep ':(7878|8989|9696|8181|8081|9091)' || true

echo
echo "== Done =="
echo "No reboot was performed."
