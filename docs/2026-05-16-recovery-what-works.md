# QNAP NAS Recovery — What Works, What Doesn't

## Current State (2026-05-16 post-reboot)

- Pool `/dev/mapper/vg1-tp1-tpool` activates in **READ-ONLY** mode with `needs_check`
- Filesystem mounts read-only at `/share/CACHEDEV1_DATA`
- Docker/Container Station cannot start (need RW filesystem)

---

## Root Cause Layers

### Layer 1: CRC check — FIXED (persists across reboots)
- **Problem**: Kernel module `dm-thin-pool.ko` rejected the superblock because CRC mismatched
- **Fix**: Patched module at file offset `0xa9b6`: `75 2b` → `90 90` (NOP'd `jne +0x2b` in `sb_check`)
- **Status**: Working. Pool now loads instead of failing at CRC stage.
- **Location**: `/lib/modules/5.10.60-qnap/dm-thin-pool.ko` (backup at `.ko.bak`)

### Layer 2: LVM thin_check — FIXED (persists across reboots)
- **Problem**: LVM runs `thin_check` before activation which would fail on corrupted metadata
- **Fix**: `/etc/lvm/lvm.conf` → `thin_check_executable = "/bin/true"`
- **Status**: Working.

### Layer 3: NEEDS_CHECK flag — NOT FIXED (root cause of current RO problem)
- **Problem**: After the CRC patch allows the pool to load, the pool still enters READ_ONLY mode because the `needs_check` flag is set
- **Current behaviour**: `dmsetup status vg1-tp1-tpool` shows `ro ... needs_check`
- **Superblock state**: Both primary (block 0) and backup (block 8388519) superblocks have `flags=0xC0000000`. Bit 0 = 0 → NEEDS_CHECK should be cleared per standard dm-thin format.
- **Mystery**: Despite both superblocks showing NEEDS_CHECK cleared (bit 0 = 0), the pool still enters RO mode. Either:
  - QNAP uses a different bit position for NEEDS_CHECK (e.g., bit 30 = 0x40000000)
  - OR the thin pool driver has a separate code path for NEEDS_CHECK that reads from a different location
- **What we haven't tried**: Setting flags = `0x00000000` (all bits clear) to eliminate ambiguity

---

## What Was Tried and Results

| Action | Result |
|--------|--------|
| Patch `dm-thin-pool.ko` to bypass CRC check | ✅ Pool now starts (no longer fails at CRC) |
| Patch superblock flags to `0xC0000000` (primary + backup) | ⚠️ Pool still enters RO mode |
| `dmsetup message vg1-tp1-tpool 0 thaw` | ❌ Not supported |
| `lvchange -an` to deactivate pool | ❌ Devices busy after boot |
| `dmsetup rename vg1-lv1 cachedev1` | ✅ Required for QNAP web UI to recognise volume |
| `/sbin/storage_util --volume_scan` after rename | ✅ Volume shows as configured in web UI |
| Stop Container Station → unmount → remount as cachedev1 → restart | ✅ Fixed "Unmounted" status in web UI |

---

## What Works After Manual Intervention

After SSH + manual steps, the NAS runs fully:
- Pool activated RW, filesystem mounted RW
- All 9 containers running
- QNAP web UI shows volume as healthy

**Manual recovery script** (run via SSH after each reboot if boot fails):
```bash
# 1. Deactivate pool (may already be partially active in RO)
lvchange --config 'global{thin_check_executable="/bin/true"}' -an vg1/lv1 2>/dev/null
lvchange --config 'global{thin_check_executable="/bin/true"}' -an vg1/tp1 2>/dev/null

# 2. Create raw metadata passthrough device
dmsetup create tmeta_direct --table "0 134217728 linear 147:1 301992960" 2>/dev/null || true

# 3. Patch primary superblock to clear ALL flags (try 0x00000000 instead of 0xC0000000)
/usr/local/bin/python << 'PYEOF'
import struct, subprocess

def crc32c_kernel(data_bytes):
    crc = 0xFFFFFFFF
    poly = 0x82F63B78
    for b in bytearray(data_bytes):
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ poly if (crc & 1) else (crc >> 1)
    return crc

for (blocknr, drbd1_sector) in [(0, 301992960), (8388519, 301992960 + 8388519*16)]:
    proc = subprocess.Popen(
        ["dd", "if=/dev/drbd1", "bs=512", "skip=%d" % drbd1_sector, "count=16"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    out, _ = proc.communicate()
    data = bytearray(out[:8192])
    struct.pack_into("<I", data, 4, 0x00000000)  # ALL flags cleared
    struct.pack_into("<Q", data, 8, blocknr)
    new_crc = crc32c_kernel(bytes(data[4:])) ^ 0x27446
    struct.pack_into("<I", data, 0, new_crc)
    proc2 = subprocess.Popen(
        ["dd", "of=/dev/drbd1", "bs=512", "seek=%d" % drbd1_sector, "count=16"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    _, err2 = proc2.communicate(input=bytes(data))
    print("Block %d: CRC=0x%08X flags=0x00000000 RC=%d" % (blocknr, new_crc, proc2.returncode))
PYEOF

# 4. Activate pool and volume
lvchange --config 'global{thin_check_executable="/bin/true"}' -ay vg1/lv1

# 5. Rename dm device so QNAP web UI recognises it
dmsetup rename vg1-lv1 cachedev1 2>/dev/null || true

# 6. Mount filesystem
mount -t ext4 /dev/mapper/cachedev1 /share/CACHEDEV1_DATA

# 7. Volume scan (registers with QNAP management layer)
/sbin/storage_util --volume_scan do_scan_raid=0 force=1

# 8. Start Container Station
QPKG_DIR=/share/CACHEDEV1_DATA/.qpkg/container-station
export PATH="$QPKG_DIR/bin:$QPKG_DIR/usr/bin:$PATH"
$QPKG_DIR/container-station.sh start
```

---

## Permanent Fix — Still Needed

The goal is for the NAS to boot fully without manual intervention. Options:

### Option A: Patch module to bypass NEEDS_CHECK check (best long-term fix)
Find and NOP the `check_needs_check_flag` function in `dm-thin-pool.ko` so the pool always starts in write mode. This requires binary analysis of the module to find the right offset.

### Option B: Pre-boot hook in `init_lvm.sh`
Modify `/etc/init.d/init_lvm.sh` to patch the superblock (with flags=0x00000000) BEFORE `storage_util --sys_startup_p2` runs. This means every boot automatically clears NEEDS_CHECK before LVM activates.

### Option C: Post-activation fix
After LVM activates the pool (in RO mode), deactivate it, patch the superblock, and reactivate. Requires all qstorman etc. to not be holding devices open — might be possible with the right ordering.

**Recommended next step**: Try Option B (modify init_lvm.sh) — lowest risk, doesn't require further binary analysis.

---

## Architecture Reference

- QNAP IP: `10.1.1.5`
- SSH: `ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5`
- Kernel module: `/lib/modules/5.10.60-qnap/dm-thin-pool.ko` (patched; backup at `.ko.bak`)
- Pool member device: `/dev/drbd1` (147:1) → DRBD over `/dev/md1` (RAID5)
- Metadata region on drbd1: starts at sector `301992960`
- Pool table: `0 34663899136 thin-pool 252:0 TIER 1024 0 7 TIER:3 252:1 252:2 252:3 enable_map:4 skip_block_zeroing error_if_no_space`
- Primary SB: block 0 of metadata
- Backup SB: block 8388519 of metadata
- CRC formula: `crc32c(data[4:]) XOR 0x27446`
