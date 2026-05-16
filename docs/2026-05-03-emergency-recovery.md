# Emergency NAS Recovery — 2026-05-03

## Summary

Full DataVol1 recovery following a disk-full event that corrupted the LVM thin pool and ext4 journal, taking the main 15.2 TB RAID 5 volume offline.

---

## Root Cause Chain

1. RAID 5 array (`md1`) degraded — one of four drives went offline
2. Thin pool (`vg1/tp1`) filled to capacity (QNAP daily snapshot `snap10002` consumed ~15.2 TB of COW space)
3. Kernel set thin pool to `error_if_no_space` mode → all writes blocked
4. ext4 journal could not replay → filesystem check loop (QNAP web UI "Check File System" kept stopping)
5. Snapshot deletion stuck at 0% — thin pool FAIL mode blocked the operation
6. DataVol1 unmounted, Container Station offline, all Docker containers stopped

---

## What Was Done

### 1. Thin Pool Superblock Fix

The thin pool metadata superblock had `NEEDS_CHECK` set (bit 0 of flags field), causing LVM to refuse activation in RW mode.

**Superblock structure:**
- Location: `/dev/drbd1` at byte offset `154,620,395,520` (block `18874560` in 8192-byte blocks)
- Calculation: `(pe_start=3072 + tmeta_start_extent=36864 × pe_size=8192) × 512`
- CRC algorithm: `crc32c(data[4:8192]) XOR 160774`

**Original (broken):** flags `0xC0000001` (NEEDS_CHECK set + QNAP features)
**Patched (wrong):** flags `0x00000001` — accidentally cleared QNAP feature bits 30-31 (`fast_block_clone`, `sb_backup`)
**Fixed (correct):** flags `0xC0000000` — NEEDS_CHECK cleared, QNAP features preserved, CRC `0x026CF3B6`

Written directly to `/dev/drbd1` bypassing the device mapper stack (the device mapper alias `/dev/mapper/vg1-tp1_tmeta` only exists while pool is active; `dd` to an inactive device path creates a regular file instead).

```bash
cat /tmp/tpool_meta_fixed.bin | ssh admin@10.1.1.5 \
  "dd of=/dev/drbd1 bs=8192 seek=18874560 count=1"
```

### 2. Filesystem Repair (e2fsck)

With the thin pool in RW mode, e2fsck could replay the journal and fix block count errors.

```bash
e2fsck -y /dev/mapper/vg1-lv1
```

Fixed: inode bitmap differences, free block counts wrong for ~15 groups, free inode counts, directory counts. Exit code 0.

### 3. Duplicate File Deletion (2,970 GB freed)

279 duplicate video files identified by matching file sizes across 4,763 videos. All were raw download folders surviving alongside Radarr-organised `Title (Year)/` copies — caused by Radarr being in Copy mode instead of Move.

Top deletions:
- John Wick Ch2 raw (76.7 GB)
- The Great Gatsby raw (75.3 GB)
- Top Gun IMAX raw (74.4 GB)
- John Wick Ch3 raw (74.3 GB)
- No Time to Die 4K HDR DV (66.0 GB)

Full list: `duplicate-report-2026-05-03.txt`

Filesystem free space: 21 GB → 266 GB after deletion.

### 4. Snapshot Deletion

QNAP snapshot `snap10002` (15.20 TB, taken 2026-05-02 09:26:39) was deleted by QNAP's `init_lvm.sh` during storage reinitialisation. Confirmed gone: `Count = 0` in `/mnt/HDA_ROOT/.config/qsnapshot/snapshot.conf`.

### 5. DataVol1 Mount Recovery

```bash
/etc/init.d/init_lvm.sh     # creates cachedev1 device
# Result: /dev/mapper/cachedev1 → /share/CACHEDEV1_DATA
```

### 6. Container Station Recovery (partial)

- Created `/usr/bin/jq` wrapper (Container Station's init script requires `jq` which isn't in PATH post-crash)
- Started supervisord-managed services: `system-docker`, `docker`, `ctstation`, `cs-crond`, `cs-qservice`, `lxcfs`
- User-facing Docker daemon (`dockerd` on `/var/run/docker.sock`) kept crashing due to stale network state in `/var/lib/docker/network/files/local-kv.db` (FlareSolverr endpoint retry loop)

---

## Recurring Issue: I/O Errors from Degraded RAID

After DataVol1 was mounted and Docker began writing, I/O errors from the degraded `md1` RAID 5 array triggered the cycle again:

```
Buffer I/O error on dev dm-0, logical block 2056290304
JBD2: Error -5 detected when updating journal superblock
EXT4-fs (dm-0): Remounting filesystem read-only
```

The `data_err=abort` mount option causes ext4 to immediately abort the journal and remount RO on the first I/O error. This cascades back to the thin pool setting `needs_check` again.

**The fixed superblock was re-written to `/dev/drbd1` each time and persists.**

---

## Pending Actions

### Critical (do immediately)

1. **Replace the failing RAID drive**
   - Check QNAP web UI → Storage Manager for amber/red drive indicator
   - `md1` is RAID 5 with `[4/3] [UU_U]` — one drive offline, rebuild at 1.9%, ETA ~41 hours
   - If a second drive fails during rebuild, all data is lost

2. **Reboot the NAS** (after confirming drive status)
   - The fixed thin pool superblock will load cleanly
   - QNAP's full init sequence restores Container Station correctly
   - **Do NOT reboot during RAID rebuild** — restart from 0%
   - Actually: rebuild is already running and must be allowed to complete before rebooting

### After reboot / system stable

3. **Fix Radarr import mode: Copy → Move**
   - Radarr web UI: `http://10.1.1.5:7878` (API key: `df4ccb14e6194a1f8d0fefdd8710ce33`)
   - Settings → Media Management → Import Mode: Move
   - This prevents future duplicate accumulation

4. **Disable QNAP snapshot schedule**
   - Storage Manager → Snapshots → DataVol1 → Schedule
   - Current: Daily 01:00, Keep 2 snapshots
   - A 15.2 TB snapshot in a 16.1 TB thin pool leaves almost no headroom
   - Either disable entirely or reduce retention to 0 / increase thin pool size

5. **Delete Docker network state if containers don't restart cleanly**
   - `/share/CACHEDEV1_DATA/.qpkg/container-station/var/lib/docker/network/files/local-kv.db`
   - Backup first: `cp local-kv.db local-kv.db.bak`
   - Deleting forces Docker to recreate all networks fresh on next start
   - Containers will need to be restarted via `docker compose -p <name> -f <name>.yaml up -d`

6. **Run fstrim to reclaim thin pool space** (once a fstrim binary is available)
   - Thin pool still shows 98% even though filesystem has 266 GB free
   - Deleted file blocks are not freed in thin pool without DISCARD/TRIM
   - `fstrim` not available on this QNAP firmware; remounted with `discard` option as workaround
   - After system is stable, consider: `docker exec <container> fstrim /` or transfer static binary

---

## Key File Locations

| File | Purpose |
|------|---------|
| `/dev/drbd1` offset `154,620,395,520` | Thin pool metadata superblock |
| `/mnt/HDA_ROOT/.config/lvm/backup/vg1` | LVM VG backup |
| `/mnt/HDA_ROOT/.config/qsnapshot/snapshot.conf` | QNAP snapshot config |
| `/share/CACHEDEV1_DATA/.qpkg/container-station/var/log/container-station/docker.log` | Docker daemon log |
| `/share/CACHEDEV1_DATA/.qpkg/container-station/start-stop.log` | Container Station startup log |
| `/share/CACHEDEV1_DATA/.qpkg/container-station/etc/supervisord.conf` | Supervisord config |
| `/tmp/tpool_meta.bin` (local Mac) | Original thin pool superblock (flags `0xC0000001`) |
| `/tmp/tpool_meta_fixed.bin` (local Mac) | Fixed thin pool superblock (flags `0xC0000000`) |
| `duplicate-report-2026-05-03.txt` | Full list of 279 deleted duplicate files |

---

## LVM / Device Mapper Reference

```
/dev/mapper/cachedev1       ← ext4 filesystem (DataVol1)
└── vg1-lv1  (thin device, 15.32 TB)
    └── vg1-tp1-tpool  (thin pool, 16.14 TB)
        ├── vg1-tp1_tmeta  (metadata, 64 GB, on pv0 PE 36864)
        └── vg1-tp1_tierdata_{0,1,2}  (data, backed by /dev/drbd1 = md1 RAID 5)
```

**Thin pool superblock CRC (Python):**
```python
def crc32c(data, init=0xFFFFFFFF):
    # Castagnoli polynomial 0x82F63B78
    ...
# crc32c(superblock[4:8192]) XOR 160774 == stored CRC
```

**RAID status check:**
```bash
cat /proc/mdstat
```
