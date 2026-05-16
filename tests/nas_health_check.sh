#!/bin/bash
# NAS Health Check — run from Mac to verify NAS is fully operational.
# Usage: ./tests/nas_health_check.sh

set -euo pipefail

QNAP_IP="10.1.1.5"
SSH_KEY="$HOME/.ssh/qnap_rsa_key"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no admin@$QNAP_IP"
PASS=0
FAIL=0

green() { printf "\033[32m[PASS]\033[0m %s\n" "$1"; }
red()   { printf "\033[31m[FAIL]\033[0m %s\n" "$1"; }

check() {
    local name="$1"; local ok="$2"
    if [ "$ok" = "1" ]; then green "$name"; PASS=$((PASS+1))
    else                  red   "$name"; FAIL=$((FAIL+1))
    fi
}

echo "=== NAS Health Check — $QNAP_IP ==="
echo ""

# ── Test 1: SSH reachable ──────────────────────────────────────────────────
echo "[ Storage ]"
SSH_OK=$($SSH 'echo 1' 2>/dev/null || echo 0)
check "SSH accessible" "$SSH_OK"

# ── Test 2: Volume mounted read-write ─────────────────────────────────────
RW=$($SSH 'cat /proc/mounts | grep "cachedev1.*ext4.*rw" | wc -l' 2>/dev/null | tr -d ' ')
check "Volume /share/CACHEDEV1_DATA mounted read-write" "${RW:-0}"

# ── Test 3: File write and delete ─────────────────────────────────────────
WRITE=$($SSH 'touch /share/CACHEDEV1_DATA/.nas_health_test 2>/dev/null && rm /share/CACHEDEV1_DATA/.nas_health_test && echo 1 || echo 0' 2>/dev/null | tr -d ' \r\n')
check "Write and delete file on /share/CACHEDEV1_DATA" "${WRITE:-0}"

# ── Test 4: Thin pool in write mode (not read-only) ───────────────────────
POOL_RO=$($SSH 'dmsetup status vg1-tp1-tpool 2>/dev/null | grep " ro " | wc -l' 2>/dev/null | tr -d ' \r\n')
check "Thin pool NOT in read-only mode" "$([ "${POOL_RO:-1}" = "0" ] && echo 1 || echo 0)"

echo ""
echo "[ Containers ]"

# ── Test 5: All 9 containers running ──────────────────────────────────────
COUNT=$($SSH 'export PATH="/share/CACHEDEV1_DATA/.qpkg/container-station/bin:/share/CACHEDEV1_DATA/.qpkg/container-station/usr/bin:$PATH"; docker ps -q 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r\n')
check "All 9 containers running (found: ${COUNT:-0})" "$([ "${COUNT:-0}" = "9" ] && echo 1 || echo 0)"

# ── Test 6: Heimdall accessible via HTTP ──────────────────────────────────
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$QNAP_IP:8081/" 2>/dev/null) || HTTP_CODE="000"
check "Heimdall accessible at http://$QNAP_IP:8081/ (HTTP $HTTP_CODE)" \
    "$(echo "$HTTP_CODE" | grep -qE '^(200|301|302)$' && echo 1 || echo 0)"

echo ""
echo "[ Updates ]"

# ── Test 7: Auto-update script exists and is executable ───────────────────
SCRIPT_OK=$($SSH '{ test -x "/share/homes/admin/qnap/Auto Update/auto-update.sh" || test -x "/share/CACHEDEV1_DATA/homes/admin/qnap/Auto Update/auto-update.sh"; } && echo 1 || echo 0' 2>/dev/null | tr -d ' \r\n')
check "Auto-update script exists and is executable" "${SCRIPT_OK:-0}"

# ── Test 8: Docker can reach registry (update prerequisite) ───────────────
REGISTRY=$($SSH 'export PATH="/share/CACHEDEV1_DATA/.qpkg/container-station/bin:/share/CACHEDEV1_DATA/.qpkg/container-station/usr/bin:$PATH"; docker pull hello-world 2>&1 | grep "Pull\|Status\|up to date" | wc -l' 2>/dev/null | tr -d ' \r\n')
check "Docker registry reachable (can pull images)" "$([ "${REGISTRY:-0}" != "0" ] && echo 1 || echo 0)"

echo ""
echo "══════════════════════════════════════"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "══════════════════════════════════════"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
