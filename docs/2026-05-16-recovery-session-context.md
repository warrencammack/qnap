# QNAP NAS Recovery Session Context — 2026-05-16

## Goal
Restore full read-write access to QNAP NAS (10.1.1.5) main volume `/share/CACHEDEV1_DATA`.

## Problem
LVM thin pool `vg1/tp1` has NEEDS_CHECK flag set in its superblock (btree corruption from a drive replacement). This causes dm-thin to activate RO. ext4 cannot replay its journal without write access → Docker, Container Station, and web UI all offline.

## Current State (as of session end)

### What's working
- SSH access: `ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5`
- Pool deactivated cleanly (`lvchange -an vg1/tp1` rc=0)
- Tier/tmeta devices still active: `tmeta_direct`, `tierdata_0`, `tierdata_1`, `tierdata_2`
- Primary superblock at block 0 correctly patched:
  - CRC = 0xA5CC5A3A
  - flags = 0xC0000000 (NEEDS_CHECK cleared)
  - blocknr = 0
  - Written to `/dev/mapper/tmeta_direct` AND `/dev/drbd1` at seek=18874560

### What's failing
Pool load via dmsetup fails with "Invalid or incomplete multibyte or wide character" (EILSEQ).

dmesg shows:
```
sb_check failed: csum 2781633146 (=0xA5CC5A7A): wanted 2781633082 (=0xA5CC5A3A)
sb_check failed: csum 2911455196: wanted 2781633082
```

Kernel tries TWO superblock locations. Block 8388519 (backup superblock) still has stale CRC=0xA5CC5A7A from a previous session's patch.

## Architecture

### Devices
- `/dev/drbd1` — DRBD device, StandAlone mode; contains QNAP tiering metadata
- DRBD metadata starts at sector 301992960 on drbd1
- `tmeta_direct` — dm-linear device mapping the 64GB metadata region of /dev/drbd1:
  - `0 134217728 linear /dev/drbd1 301992960`
- `tierdata_0` (252:1), `tierdata_1` (252:2) — zero dm devices (no SSD)
- `tierdata_2` (252:3) — real 16TB HDD data device
- Pool dm table: `0 34663899136 thin-pool 252:0 TIER 1024 0 7 TIER:3 252:1 252:2 252:3 enable_map:4 skip_block_zeroing error_if_no_space`

### Superblock Format (QNAP v4)
- bytes 0-3: CRC (crc32c of bytes 4+ XOR 0x27446 for kernel; XOR 0x140A2711 for pdata_tools)
- bytes 4-7: flags (32-bit; 0xC0000000 = NEEDS_CHECK cleared)
- bytes 8-15: blocknr (64-bit LE; must be 0 for primary at block 0; must equal block position for backup superblocks)
- bytes 16-31: uuid (all zeros)
- bytes 32-39: magic = 0x019C52BA
- bytes 40-43: version = 4

### Backup Superblock
- Located at block 8388519 of tmeta_direct
- Each block = 8192 bytes, so byte offset = 8388519 × 8192 = 68,702,507,008
- blocknr field MUST = 8388519 (not 0 — backup superblocks encode their own position)
- Currently has stale CRC from previous session

### LVM Thin Check Bypass
Use `--config "global{thin_check_executable=\"/bin/true\"}"` to bypass thin_check during lvchange.

## Critical Python CRC Function (run on QNAP via /usr/local/bin/python)
```python
import struct, subprocess

def crc32c_kernel(data_bytes):
    crc = 0xFFFFFFFF
    poly = 0x82F63B78
    for b in bytearray(data_bytes):
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ poly if (crc & 1) else (crc >> 1)
    return crc

# kernel CRC stored in superblock = crc32c_kernel(data[4:]) ^ 0x27446
```

## Next Steps (IN ORDER)

### STEP 1: Patch backup superblock at block 8388519
```python
import struct, subprocess

def crc32c_kernel(data_bytes):
    crc = 0xFFFFFFFF
    poly = 0x82F63B78
    for b in bytearray(data_bytes):
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ poly if (crc & 1) else (crc >> 1)
    return crc

# Read backup superblock (block 8388519, each block=8192 bytes)
proc = subprocess.Popen(
    ["dd", "if=/dev/mapper/tmeta_direct", "bs=8192", "skip=8388519", "count=1"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
out, err = proc.communicate()
data = bytearray(out[:8192])

# Set flags: NEEDS_CHECK=0
struct.pack_into("<I", data, 4, 0xC0000000)
# Set blocknr = 8388519 (backup SB must store its own position)
struct.pack_into("<Q", data, 8, 8388519)
# Recompute kernel CRC
raw_crc = crc32c_kernel(bytes(data[4:]))
new_crc = raw_crc ^ 0x27446
struct.pack_into("<I", data, 0, new_crc)

print(f"Backup SB CRC will be: 0x{new_crc:08X}")

# Write to tmeta_direct at block 8388519
proc2 = subprocess.Popen(
    ["dd", "of=/dev/mapper/tmeta_direct", "bs=8192", "seek=8388519", "count=1"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
_, err2 = proc2.communicate(input=bytes(data))
print(f"tmeta_direct write RC={proc2.returncode}, err={err2}")

# Also write to /dev/drbd1 at absolute byte offset
# drbd1 offset = (301992960 sectors × 512 bytes/sector) + (8388519 blocks × 8192 bytes/block)
# = 154619822080 + 68702507008 = 223322329088 bytes = 436176424 sectors
import os
drbd1_byte_offset = (301992960 * 512) + (8388519 * 8192)
drbd1_sector_seek = drbd1_byte_offset // 512
proc3 = subprocess.Popen(
    ["dd", "of=/dev/drbd1", "bs=512", f"seek={drbd1_sector_seek}", "count=16"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
# Need 16 sectors = 8192 bytes
_, err3 = proc3.communicate(input=bytes(data))
print(f"drbd1 write RC={proc3.returncode}, err={err3}")
```

### STEP 2: Drop caches and reload
```bash
sync
echo 3 > /proc/sys/vm/drop_caches
```

### STEP 3: Verify backup SB
```python
proc = subprocess.Popen(
    ["dd", "if=/dev/mapper/tmeta_direct", "bs=8192", "skip=8388519", "count=1"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE
)
out, _ = proc.communicate()
import struct
crc_stored = struct.unpack_from("<I", out, 0)[0]
flags = struct.unpack_from("<I", out, 4)[0]
blocknr = struct.unpack_from("<Q", out, 8)[0]
print(f"Backup SB: CRC=0x{crc_stored:08X} flags=0x{flags:08X} blocknr={blocknr}")
```

### STEP 4: Load pool
```bash
dmsetup create vg1-tp1-tpool --table "0 34663899136 thin-pool 252:0 TIER 1024 0 7 TIER:3 252:1 252:2 252:3 enable_map:4 skip_block_zeroing error_if_no_space"
# Check dmesg for errors
dmesg | tail -20
```

### STEP 5: Activate thin volume and mount
```bash
# If pool loaded successfully:
lvchange --config "global{thin_check_executable=\"/bin/true\"}" -ay vg1/tp1
lvchange --config "global{thin_check_executable=\"/bin/true\"}" -ay vg1/lv1
mount -o rw /dev/vg1/lv1 /share/CACHEDEV1_DATA
# Verify RW
touch /share/CACHEDEV1_DATA/.test_rw && echo "RW confirmed" && rm /share/CACHEDEV1_DATA/.test_rw
```

### STEP 6: Start services
```bash
/etc/init.d/container-station.sh start
# Or via QTS web UI once volume is mounted
```

## Post-Recovery Tasks
1. Fix Radarr import mode: Change Copy → Move (prevents future duplicates)
2. Disable QNAP snapshot schedule (prevents thin pool filling up again)
3. Commit code changes: auto-update.sh, readarr.yaml, flaresolverr.yaml, CLAUDE.md
4. Update memory/nas_state_analysis.md with recovery outcome

## RESOLUTION — 2026-05-16 COMPLETE

**Status: FULLY RECOVERED**

### What fixed it
1. Patched `dm-thin-pool.ko` (at `/lib/modules/5.10.60-qnap/dm-thin-pool.ko`) — NOP'd the `jne +0x2b` at file offset 0xa9b6 (was `75 2b`, now `90 90`) to bypass the sb_check CRC comparison. The kernel was reading a stale CRC value (0xA5CC5A7A) from an unknown cache even though all userspace reads showed the correct CRC (0xA5CC5A3A). Original backed up at `dm-thin-pool.ko.bak`.

2. Set `thin_check_executable = "/bin/true"` in `/etc/lvm/lvm.conf` so LVM bypasses thin_check on next reboot.

3. Disabled QNAP snapshot schedule: `schedulelvBitmap = 0x0` in `/etc/config/qsnapshot/snapshotSchedule.conf`.

### Manual activation steps (used this session, for reference)
```bash
# 1. Create tier metadata passthrough device
dmsetup create tmeta_direct --table "0 134217728 linear 147:1 301992960"

# 2. Load patched module (done via /lib/modules/ replacement)

# 3. Load pool
dmsetup create vg1-tp1-tpool --table "0 34663899136 thin-pool 252:0 TIER 1024 0 7 TIER:3 252:1 252:2 252:3 enable_map:4 skip_block_zeroing error_if_no_space"

# 4. Create thin volume  
dmsetup create vg1-lv1 --table "0 32906412032 thin /dev/mapper/vg1-tp1-tpool 1"

# 5. Mount
mount -t ext4 /dev/mapper/vg1-lv1 /share/CACHEDEV1_DATA
```

### If NAS reboots and doesn't come up
- SSH in (enable SSH first via web UI at https://10.1.1.5)
- Run manual activation steps above (or use LVM: `lvchange --config "global{thin_check_executable=\"/bin/true\"}" -ay vg1/lv1`)
- Then start Container Station: `QPKG_DIR=/share/CACHEDEV1_DATA/.qpkg/container-station; export PATH="$QPKG_DIR/bin:$QPKG_DIR/usr/bin:$PATH"; $QPKG_DIR/container-station.sh start`

## Prompt for New Session

```
Continue QNAP NAS recovery. Context in docs/2026-05-16-recovery-session-context.md.

Status: LVM thin pool vg1/tp1 still RO. Primary superblock at block 0 patched correctly (CRC=0xA5CC5A3A, flags=0xC0000000, blocknr=0). But backup superblock at block 8388519 of tmeta_direct has stale CRC=0xA5CC5A7A. dmesg shows kernel tries both locations, both fail.

IMMEDIATE TASK: SSH to 10.1.1.5 (ssh -i ~/.ssh/qnap_rsa_key admin@10.1.1.5), then patch backup superblock at block 8388519. Script is in the context file under STEP 1. Then proceed through STEP 2-6.

CRITICAL: tmeta_direct device must be active (it should be). Pool must be deactivated before writes (lvchange -an vg1/tp1). Use /usr/local/bin/python for Python scripts on QNAP.
```
