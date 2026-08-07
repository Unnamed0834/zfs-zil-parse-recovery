# Recovering a 140 TB ZFS pool from a dead SLOG

### A three-day technical breakdown of two on-disk defects, four wrong diagnoses, and the custom module that repaired the pool on disk

Incident window: 2026-07-18 (SLOG failure) to 2026-07-22 (verified clean import
on stock ZFS)
Active debugging: 2026-07-19 20:41 to 2026-07-22 21:40 (~3 days)
Outcome: Full recovery with `errors: No known data errors`. The pool imported
on unmodified stock TrueNAS ZFS on every attempt between 2026-07-22 and
2026-07-27, on two installs. That is the bounded claim; untested ZFS releases
are untested (§1). The failed SLOG could have contained synchronous writes not
yet committed to the main pool.

---

## Table of contents

1. [Executive summary](#1-executive-summary)
2. [The system](#2-the-system)
3. [Timeline](#3-timeline)
4. [Day 1: the wrong problem](#4-day-1-the-wrong-problem)
5. [Day 1: finding the SLOG](#5-day-1-finding-the-slog)
6. [Day 1 to 2: the recurrence and the key
   asymmetry](#6-day-1-to-2-the-recurrence-and-the-key-asymmetry)
7. [Day 2: four wrong root causes](#7-day-2-four-wrong-root-causes)
8. [Day 2: breakthrough, SysRq-W](#8-day-2-breakthrough-sysrq-w)
9. [Day 2: bug #1 in detail, ZIL chain into a hole vdev (mechanism incomplete,
   see the correction in that
   section)](#9-day-2-bug-1-in-detail-zil-chain-into-a-hole-vdev)
10. [Day 2: the binary NOP patch](#10-day-2-the-binary-nop-patch)
11. [Day 2 to 3: CachyOS and the source
    fix](#11-day-2-to-3-cachyos-and-the-source-fix)
12. [Day 3: bug #2 emerges, space-map
    corruption](#12-day-3-bug-2-emerges-space-map-corruption)
13. [Day 3: breakthrough, forced metaslab
    condense](#13-day-3-breakthrough-forced-metaslab-condense)
14. [Day 3: verification on stock ZFS](#14-day-3-verification-on-stock-zfs)
15. [The patch set as applied](#15-the-patch-set-as-applied)
16. [False conclusions ledger](#16-false-conclusions-ledger)
17. [Initial assumptions that were
    wrong](#17-initial-assumptions-that-were-wrong)
18. [Diagnostic methodology: what
    worked](#18-diagnostic-methodology-what-worked)
19. [Near-misses and self-inflicted
    damage](#19-near-misses-and-self-inflicted-damage)
20. [Final state and open items](#20-final-state-and-open-items)
21. [Appendix A: key stack traces](#appendix-a-key-stack-traces)
22. [Appendix B: flags and tunables tried](#appendix-b-flags-and-tunables-tried)

---

> Status of this document. This is the incident record, written immediately
> after the recovery and left substantially as written. Its account of what
> happened, what was tried, and what fixed it is observed fact and remains
> accurate.
>
> Forward-looking analysis is superseded by the reproduction work. The common
> blocking site is inside `zil_parse()` at `arc_read()` -> `zio_wait()`;
> `spa_vdev_remove_log()` can skip the ZIL reset when `vs_alloc == 0` (that it
> produced this pool's state stays INFERRED, `../CLAIMS.md` 4.1); the
> precondition was not reachable by ordinary means; `zil_parse()` has an error
> path that is never reached because the ZIO never completes; and the §9
> mechanism for Bug #1 is incomplete. Finding 16 synthesised a hole vdev plus a
> dangling non-zero `zh_log` DVA resolving into it and imported it writable on
> stock `zfs-2.4.3` without hanging: exit 0, pool ONLINE, twice from a pristine
> restore (`../CLAIMS.md` 2.7, `../reproducibility/FINDINGS.md` finding 16). The
> incident hang and its stack are OBSERVED (1.2), but hole plus dangling DVA is
> not sufficient, and at least one further ingredient is unidentified. §9 states
> that inline. Current position: [`../CONCLUSIONS.md`](../CONCLUSIONS.md) and
> [`../reproducibility/FINDINGS.md`](../reproducibility/FINDINGS.md). Where this
> document and those disagree, they are correct.
>
> A note on source line numbers. This document's `zil.c` citations are against
> the `zfs-2.4.3` tree the repair was built in, where they happen to coincide
> with `master`. Its `spa.c` citations are mixed: §9's subsection heading and
> §11 give the `zfs-2.4.3` number first with `master` in parentheses, while the
> call-site lists in §9 and §18 were recorded at the time against `master` and
> give the `zfs-2.4.3` equivalent in parentheses. Every such citation is
> annotated inline below with both numbers, and all of them were re-verified on
> 2026-07-31. The authoritative index, giving the `zfs-2.4.3` and `master` line
> for every citation in this repository, is [`../CLAIMS.md`](../CLAIMS.md) §7;
> where this document and that index disagree, the index wins.

## 1. Executive summary

Two mirrored SATA SSDs serving as a SLOG (ZFS Intent Log device) on my 12-disk,
2x raidz2, 186 TB raw / 140 TB allocated TrueNAS pool began intermittently
dropping off the bus. I wiped them and removed them. The pool would then import
read-only without complaint, but hang forever on any writable import, with the
`zpool` process stuck in uninterruptible D-state, unkillable, requiring a hard
reboot to clear.

Over three days I diagnosed and repaired two independent on-disk defects. The
missing hole-vdev coverage is relevant to upstream OpenZFS; the exact incident
precondition was not later reproducible, and the reason the blocked read never
completed was never established. Neither defect had a stock recovery tool for
this pool. The documented recovery advice for the space-map cases was to copy
data to a fresh pool with `zfs send`, which was impossible for me with 140 TB
allocated and no spare capacity.

Bug #1: ZIL header DVA pointing into a `hole` vdev. When a log vdev is removed,
ZFS does not delete it from the vdev tree. It converts it to a `hole`
(`guid: 0`, `is_hole: 1`) to preserve child indices. My per-dataset ZIL
headers, however, still contained non-zero DVAs whose vdev index resolved to
that hole. `zil_check_log_chain()` guards only against
`vdev_islog && vdev_is_dead(vd)`, and a hole has `vdev_islog = 0`. The guard
never fired, `zil_parse()` walked into the dangling chain, and the worker
thread then blocked in `zio_wait()` on a ZIO that never completed. Which device
that read was actually dispatched to is not established. It was not the hole's
own vdev ops: a read by DVA has `io_vd == NULL` and dispatches through
`vdev_mirror_ops`, where `vdev_mirror_child_select()` issues no child I/O at
all and `vdev_mirror_io_done()` sets `ENXIO`, a fail-fast path, not a blocking
one (`../CLAIMS.md` 4.9). (`zil_parse()` would have handled a returned error;
it never got one. Why the ZIO never completed remains unknown; see appendix B
on `failmode`, [`../CLAIMS.md`](../CLAIMS.md) 4.9, and the correction at the
top of §9.) Read-only import worked because ZFS runs log verify and claim only
for writable imports.

Bug #2: space-map corruption detected in two metaslabs. Inconsistent `SM_FREE`
space-map records caused accumulated free space to exceed the space map's
`sm_size` (2^34 = 16 GiB), tripping a hard `VERIFY3U` in
`space_map_load_callback()`. Being a `VERIFY` assertion rather than
`zfs_panic_recover()`, it was structurally immune to `zfs_recover=1`. This bug
was invisible until Bug #1 was fixed, because read-only imports never load a
metaslab for allocation.

My solution was a custom ZFS 2.4.3 module carrying four logical patches
touching four source files. The CachyOS `zfs-dkms 2.4.3-1` source already
contains amotin's upstream log-vdev-removal fix. That fix tests `BP_IS_HOLE`,
an all-zero DVA, and this pool held a valid non-zero DVA aimed at a hole, so it
does not cover this pool's state (§9). Three of the four custom changes were
needed: B, C and D. Patch A was built and loaded but is a no-op on the hole
path ([`../CLAIMS.md`](../CLAIMS.md) 1.12). The module did not merely bypass the
faults; it repaired them on disk:

- `zil_claim()` zeroes the dangling ZIL header and dirties the dataset, so the
  correction is committed.
- `metaslab_load_impl()` sets `ms_condense_wanted` when inconsistent `SM_FREE`
  entries are skipped, forcing `metaslab_condense()` to discard and re-emit the
  on-disk space map from the resulting in-memory allocatable tree.

Both detected metaslabs were rewritten in a single transaction group. The pool
then exported cleanly and imported repeatedly with plain
`zpool import -f storage` on unmodified stock TrueNAS ZFS, including on a fresh
install.

The strongest result in this record is the post-repair scrub. A full scrub of
the repaired pool ran from Jul 22 21:46:30 to Jul 27 06:29:18, which is 4 days
8 hours 42 minutes, and completed with `scan done errors=0`. The artifact
records the start and end and does not preserve the scanned-byte total; the 140
T figure comes from the final pool status, captured separately.

It is the best-evidenced claim here, and the artifact backs more than this one
claim:
[`evidence/2026-07-30-post-repair-history.txt`](evidence/2026-07-30-post-repair-history.txt)
also records the repeated stock imports (§14), the patched module string
`zfs-2.4.3-0-g83020cf-dirty-dist` that confirms the incident tree is tag
`83020cf`, the stock module string `zfs-2.3.3-107-gec5aa9bfd`, and the
scrub-cancel timestamp that reconciles the timezone note below.

A forced metaslab condense rewrites allocation metadata and a zeroed ZIL header
discards a dataset's intent log. A clean scrub afterwards is what makes the
case that neither repair lost data. Note the limit: a scrub verifies checksums
of blocks reachable in the block tree. It does not audit space-map correctness,
so it is strong evidence for Patch B and only partial evidence for Patch D. See
§20.

The result is bounded, not unbounded. What it supports is that the repairs
are on disk and the pool imports on stock modules without them: between the
repair on 2026-07-22 and the scrub's completion on 2026-07-27, no patched module
was needed. The artifact records five stock imports, four on Jul 22 and one on
Jul 23, on two TrueNAS installs, and one full scrub spanning the rest of the
window. It is not a claim about arbitrary future ZFS releases, which were not
tested.

---

## 2. The system

| Component | Detail |
|---|---|
| Motherboard | Supermicro H12SSL-I |
| CPU / RAM | 48 threads / 96 GB |
| HBAs | 2x LSI SAS2008, FW 20.00.07.00, behind one backplane |
| Pool | `storage`, GUID `211359596362856278`, hostname `tns-01`, hostid `a421e28` |
| Topology | 2x raidz2, six members each. `raidz2-0` guid `10979346336924854794` (metaslab_array 128); `raidz2-1` guid `5884354480802639419` (metaslab_array 1542) |
| Data disks | 12x WDC SAS: WUH722020ALE604 (18.2 T), WD140EDGZ (12.7 T), WD200EDGZ, WUH721414ALE6L4 |
| Capacity | 186 T raw / 140 T allocated / 45.2 T free / 62 % frag / 75 % cap |
| Dataset | `storage`, 99.3 T used, 30.0 T available |
| Dedup | `feature@fast_dedup active`, dedupratio 1.08x, DDT 217 G, 35,393,969 entries |
| SLOG (dead) | 2x Samsung MZ7LM480, mirrored, on the SAS backplane |
| Boot pool | 2x Samsung MZ7LM480, mirrored, SATA direct to motherboard |
| `metaslab_shift` | 34, giving `sm_size` = 17,179,869,184 |
| Last good uberblock | `txg = 16404458`, `timestamp = 1784563273` = Mon Jul 20 09:01:13 2026 |

Platforms I used, in order:

1. TrueNAS SCALE 25.10.4, kernel `6.12.91-production+truenas`, ZFS
   `zfs-2.3.3-107-gec5aa9bfd`. Note the distinction, because it matters: TrueNAS
   describes the release's ZFS as `2.3.4-1`, but the module actually running on
   the affected system identified itself as `zfs-2.3.3-107-gec5aa9bfd`, a
   snapshot 107 commits past the `zfs-2.3.3` tag, which is not the `zfs-2.3.4`
   release. Confirmed in §14 and in
   [`evidence/2026-07-30-post-repair-history.txt`](evidence/2026-07-30-post-repair-history.txt).
   Reproduction work built the `zfs-2.3.4` tag from source, so it did not test
   this build; see [`../CLAIMS.md`](../CLAIMS.md) 4.8.
2. TrueNAS installer rescue shell
3. A pre-existing CachyOS install on a spare disk, console over IPMI, for the
   day-2 cross-OS check (§7.5)
4. CachyOS, installed over TrueNAS to obtain source, DKMS and a toolchain; ZFS
   `2.4.3-1`, gcc 16.1.1. Booted first on kernel `7.1.3-2-cachyos`, then: for
   all of the actual repair work, on `6.18.38-2-cachyos-lts` (why the LTS
   kernel: §11)
5. TrueNAS SCALE 25.10.4, reinstalled, for final verification

A hazard worth recording up front: there were four Samsung 480 G SSDs in the
chassis, two boot and two SLOG, and Linux device names (`sdk` through `sdp`)
reshuffled between every boot and every OS. Device-name-based reasoning was
wrong at least twice and nearly destroyed my boot pool. See §19.

---

## 3. Timeline

| When | What |
|---|---|
| Sat Jul 18, 17:04 | Scrub starts. SLOG SSDs already misbehaving. |
| ~Jul 18 to 19 | SLOG SSDs flickering available and unavailable. I wipe them and remove them from the pool. First recovery performed via installer shell (`labelclear` plus `wipefs` plus `zpool import -f -m -N storage`). Appears to work. |
| Sat Jul 19, 20:41 | I begin investigating the wrong problem, docker and containers appearing to cause a 15-minute startup. |
| Jul 19 to 20 | Pool discovered to be hanging on import; 6 middleware jobs wedged; every `zpool` command hangs. SLOG identified as the third top-level vdev. |
| Mon Jul 20, 09:01 | Last uberblock written (`txg 16404458`). Reboot during scrub. |
| Mon Jul 20, 14:27 to 15:08 | Focused work on SLOG removal specifics. Establishes that `-m` alone will not work when the log devices are absent. |
| Jul 20 | Recurrence after OS reinstall plus config restore. Key discovery: read-only import succeeds, writable import hangs. |
| Jul 20 to 21 | Four successive wrong root causes: MMP/multihost, then dedup/DDT, then block cloning/BRT, then "txg_sync is idle so it worked". I try other operating systems (a second CachyOS install over IPMI, and the installer shell) and it hangs identically. That eliminates the TrueNAS-kernel and middleware class of hypotheses. It does not prove the fault is on-disk state, because all three environments run Linux and OpenZFS. |
| Jul 21 | SysRq-W breakthrough. Real blocker identified: `spa_ld_verify_logs`, `spa_check_logs`, `dmu_objset_find_dp`, `zil_check_log_chain`, `zil_parse`, `zil_read_log_block`, `arc_read`, `zio_wait`. |
| Jul 21, 18:14 | Binary NOP patch applied to `zfs.ko`. Writable import succeeds for the first time. Data verified intact. I correctly judge it a workaround rather than a fix. |
| Jul 21 | CachyOS installed over TrueNAS to obtain source, DKMS and a toolchain. ZFS 2.4.3 patched with `vdev_ishole` checks in `zil.c`. Only the `zil_claim()` check (Patch B) did anything; the `zil_check_log_chain()` check (Patch A) is a no-op on the hole path, `../CLAIMS.md` 1.12. |
| Jul 21 | Bug #2 surfaces. First writable import past the ZIL stage panics in the metaslab allocator. Why the import got past log verify, which runs before claim, is not established: `../CLAIMS.md` 1.13, UNKNOWN. |
| Jul 21, 22:15 | Scrub canceled. (Quoted outputs in this document show both `Jul 21 22:15:22` and `Jul 22 00:15:22` for this event; same event; TrueNAS and CachyOS were in different timezones.) |
| | Clock note for the rows below. This timeline uses the recovery session's local clock. The history artifact was rendered on a host two hours behind it. The artifact's `12:44:54` for txg 16404697 and `13:12:13` for the first stock import correspond to the `~15:00` and `15:12` rows below. Check the offset before reading any discrepancy as an inconsistency. |
| Jul 22, ~00:15 | `space_map.c` skip patch working. 9 corrupt entries logged, no panic, pool fully RW. Two clean exports. I reinstall TrueNAS on the false premise that stock ZFS would now import. GUI import crashes and reboots the box. |
| Jul 22 | Back on CachyOS, which survived, contrary to my assumption. Forced-condense patch written. |
| Jul 22, ~15:00 | `forcing condense=TRUE` on msp[2] and msp[2719], txg 16404697. On-disk space maps rewritten. |
| Jul 22, 15:12 | `sudo zpool import -f storage` on stock TrueNAS returns ONLINE, no known data errors. |
| Jul 22, 21:46 to Jul 27, 06:29 | Post-repair scrub runs for 4 days 8 hours 42 minutes and completes with `scan done errors=0`; see the history artifact. (These two timestamps are the artifact's own, not the recovery session clock used in the rows above.) |
| Jul 22 onward | Pool returned to normal service at `/mnt/storage`, read-write. A full scrub subsequently ran for 4 days 8 hours 42 minutes and completed clean. |

---

## 4. Day 1: the wrong problem

I opened the investigation on a misframed symptom. My complaint was a 15-minute
boot that I blamed on Docker and apps, which persisted across an OS reinstall
and config restore. The first hour went into dissecting `freenas-v1.db` (a
SQLite config DB) looking for app configuration to strip.

It was a dead end, and the DB itself proved it:

```
services_docker  ->  1|storage|1|0|...
app_registry     ->  (empty)
services_catalog ->  TRUENAS
```

Nothing to remove. TrueNAS issue NAS-133437 (apps pool on HDDs causes systemd
to wait 15 minutes for Docker) looked like a match. It was not the cause here.

The actual state of the machine became clear from `ps`:

```
root  6078  0.6  0.0  963984  6848 ?  D  12:09  0:07
  zpool import 211359596362856278 -R /mnt -m -N -f -o cachefile=/data/zfs/zpool.cache
```

A `zpool import` in D-state since boot, with only 7 seconds of CPU over 20
minutes, `txg_sync` also in D, five `middlewared` workers in `Dl`, and a load
average of 16.67 against 94 % idle CPU. `/proc/mounts` showed only
`boot-pool/ROOT/25.10.4`, so `storage` was never mounted.

The initial 15-minute startup delay, the six unfinished jobs, and the
unresponsive UI were related symptoms of a pool import that was not completing.
Docker and applications were initially suspected, but the underlying fault was
the wedged ZFS import holding `spa_namespace_lock`. After the later reinstall,
the recurring issue was specifically the six stuck jobs and the blocked pool
import, not a separate Docker startup delay.

The lesson is that the symptom I reported was several steps removed from the
fault. The config DB, Docker, and the systemd timeout were all consequences of a
blocked `spa_load`.

---

## 5. Day 1: finding the SLOG

Hardware was cleared quickly and thoroughly:

- `dmesg` showed no SCSI or I/O errors, only `Power-on or device reset occurred`
  at boot and a benign `ses: Failed to bind enclosure -19`.
- `iostat -xz` showed all 12 data disks at 15 to 24 % util, `r_await` 5 to 6
  ms. Nothing saturated, nothing timing out.
- `smartctl` on both SSDs returned `No Errors Logged` and 0 reallocated
  sectors.
- `sas2ircu 0/1 DISPLAY` showed every device `State : Ready (RDY)` on both
  controllers.
- `/proc/diskstats` field 12 (in-flight I/O) was 0 on every disk. Nothing was
  even dispatched.

Labels told the real story. I made an important error here first:
`zdb -l /dev/sda` returned `failed to unpack label 0` on nearly every disk,
which looks like catastrophic label loss. It is not.

> Generalizable finding: run `zdb -l` on partitions, not on whole devices. On a
> pool whose members are partitioned (which is the default on TrueNAS, and on
> anything that lets an installer carve the disk), the ZFS labels live at the
> ends of the partition, not of the block device. `zdb -l /dev/sda` therefore
> reports `failed to unpack label 0` on a perfectly healthy disk, and
> `zdb -l /dev/sda1` reads it fine. This one-character difference is the
> difference between "my labels are gone" and "my labels are fine", and it was
> the first wrong conclusion of this incident (ledger #4). It costs nothing to
> always use the partition, and `zdb -l <part> | grep name` is also the check
> that prevented a boot pool being wiped in §19.

Corrected:

```
$ for d in /dev/sd[a-p]1; do zdb -l $d | grep name; done
sda1 ... sdk1, sdp1 :  name: 'storage'
sdl1, sdm1        :  failed to unpack label 0
```

(The `sdp1` entry in that transcribed line does not survive scrutiny: `sdp` was
later identified as a boot-pool member, whose label reads `boot-pool`. The line
is preserved as transcribed and should be treated as unreliable in that one
respect. See the note below on device naming, and ledger #5 in §16.)

and from any good label:

```
pool_guid: 211359596362856278
hostname: 'tns-01'
vdev_children: 3
```

Twelve data disks across two raidz2 vdevs, plus a third top-level vdev whose
two members had no readable label. I confirmed it directly: those were my slog
disks.

> Read the device names in this section with care: they are from two different
> boots, and they do not agree. The survey above was taken under the running
> TrueNAS install, where the SLOG members enumerated as `sdl` and `sdm`. The
> wipe below was performed later, from the installer shell, where the same two
> SSDs enumerated as `sdk` and `sdl`, and where `sdo` and `sdp` were the
> boot-pool pair. The commands are correct for the shell they were run in. One
> further caveat: `name: 'storage'` appears on a SLOG member as well as on a
> data disk, because a log vdev belongs to the pool, so that string never
> distinguished the two; what ruled `sdo`/`sdp` out was their labels reading
> `boot-pool`. This is the concrete form of the hazard recorded in §19; the
> names are preserved as transcribed rather than silently reconciled.

> Three different observations that must not be conflated (ledger #5 in §16):
>
> 1. Apparent run-to-run flakiness of `zdb -l` on `sdk`/`sdp` within one boot.
> Not real. Formatting artifact; three identical repeat runs disproved it
> (ledger #5). 2. Device names disagreeing between boots and operating systems.
> Real, and the reason the transcripts in this section cannot be reconciled by
> renaming. This is the §19 hazard. 3. The SLOG SSDs flickering on the SAS
> backplane. Real as a hardware observation (§3 timeline, §20 open item 3,
> `../CLAIMS.md` 4.6), but it is not what produced the differing `zdb -l`
> results, and it should not be offered as the explanation for them.

The recovery, which I performed from the TrueNAS installer shell so that no
middleware was running to race for the pool:

```
zdb -l /dev/sdk | grep name        # both must read name: 'storage'
zdb -l /dev/sdl | grep name        # sdo/sdp read boot-pool: leave alone
zpool labelclear -f /dev/sdk   /dev/sdk1
zpool labelclear -f /dev/sdl   /dev/sdl1
wipefs -a /dev/sdk /dev/sdl
zpool import -f -m -N storage
```

It worked. `-N` (do not mount) was the deliberate detail: import the pool,
clean up the vdev, export, and only then let anything try to mount.

Why `-m` alone was never enough. `zpool import -m` allows import with a
missing log device, meaning a log vdev present in config as OFFLINE or
UNAVAIL. It does nothing for a vdev that has already been converted to a hole.
And while my failing SSDs were still physically attached and flickering, ZFS
would open them and block on their dying I/O regardless of `-m`. That is
precisely why the wipe had to precede the import.

---

## 6. Day 1 to 2: the recurrence and the key asymmetry

A day later the same slowness returned, a reboot re-wedged the import, and my
fix did not hold. An OS reinstall plus config restore changed nothing, for a
structural reason: the log vdev lives in the ZFS labels on the data disks, not
in the TrueNAS config database. `storage_volume` holds only
`vol_name, vol_guid`. No topology. Restoring config was irrelevant by
construction.

Then came the single most important observation of the entire incident:

```
$ sudo zpool import -f -F -m -X -N -o readonly=on storage
cannot mount '/storage': failed to create mountpoint: Read-only file system
Import was successful, but unable to mount some datasets     <- SUCCEEDS

$ sudo zpool import -f -F -m -X -N storage
INFO: task zpool:2888 blocked for more than 120 seconds       <- HANGS FOREVER
```

And under the read-only import, the pool looked perfect:

```
  pool: storage
 state: ONLINE
  scan: scrub in progress since Sat Jul 18 17:04:06 2026
        20.0T / 139T scanned, 14.40% done
        raidz2-0  ONLINE  0 0 0   (6 members)
        raidz2-1  ONLINE  0 0 0   (6 members)
errors: No known data errors
```

No `logs` section. All 12 disks online. No errors. Nothing to remove, nothing
to repair, and yet writable import was impossible.

This asymmetry was the most important clue available for the next two days, and
it was repeatedly under-used. Read-only import skips both faulty code paths:

- Log verify and claim run only
  `if (type != SPA_IMPORT_ASSEMBLE && spa_writeable(spa))`.
- Metaslabs are never loaded for allocation, so the space map is never
  validated.

Every "the pool is clean, therefore this must be a software or tunable problem"
conclusion drawn from a read-only import was invalid for this reason.

Things ruled out in this phase, each with evidence:

| Hypothesis | Ruled out by |
|---|---|
| Missing or faulted data disk | Read-only status: 12 ONLINE, no errors |
| Data disk stalling on writes | `/proc/diskstats` in-flight = 0 on all disks |
| SAS HBA or expander wedged below per-disk accounting | Reads work perfectly. A wedged controller cannot explain a read-only import succeeding while a writable one fails. |
| A HDD gone write-protected | `dmesg`: `Write Protect is off` on every disk |
| Leftover D-state `zpool` holding the lock | Fresh OS install, no lingering process, hung identically |
| Re-inserting the wiped SSDs | ZFS matches log members by GUID, so wiped is equivalent to absent |
| `zpool set readonly=off` after RO import | `property 'readonly' can only be set at import time` |
| Export from RO import will rewrite labels | Export returned silently; next import showed the unchanged `Last accessed ... Jul 20 09:01:13` and hung |
| `-F` or `-X` rollback is what's writing to the dead SLOG | Plain `-f -m` with no rollback flags hung for 25 minutes too |

---

## 7. Day 2: four wrong root causes

Four consecutive wrong root causes, each with circumstantial support and none
with a stack trace behind it.

### 7.1 MMP and multihost

Sourced from OpenZFS #10828, which reports exactly "readonly works, writable
hangs" resolved by `zfs_multihost_fail_intervals=0`. I set it, verified it read
back `0`, and the import still froze. My pool's own uberblock had
`mmp_valid = 0`. Ruled out.

### 7.2 Dedup and fast_dedup DDT

Circumstantially very strong. My pool has `feature@fast_dedup active`, a 217 G
DDT, 35 M entries, and:

```
DDT-sha256: version=1 [FDT]; flags=0x03 [FLAT LOG]; rootobj=20832
DDT-sha256-zap-duplicate: dspace=25910020096; mspace=17222533120; entries=35393969
```

`zpool history` even showed prior `zpool prefetch -t ddt storage` calls. And
the `txg_sync` stack appeared to implicate it directly:

```
zio_wait -> dbuf_read -> zap_get_leaf_byblk -> fzap_length -> zap_length_uint64
  -> ddt_zap_lookup -> ddt_lookup -> ddt_addref
  -> brt_pending_apply_vdev -> brt_pending_apply -> spa_sync -> txg_sync_thread
```

Hours went into `zfs_dedup_prefetch=0`, `zfs_dedup_log_cap`,
`zfs_dedup_log_hard_cap`, `zfs_dedup_log_flush_txgs`, `..._entries_max/min`,
and `zfs_max_async_dedup_frees=0`. Every combination hung. A compounding error:
`zfs_dedup_log_cap=0` was read as "disabled" when `0` actually means unlimited
or default.

It was ruled out by re-running the diagnostic with every dedup tunable back at
its default. With the tunables removed, zero DDT functions appeared in any
blocked stack. The dedup stack had been an artifact of a different stage that
was only reached once the tunables perturbed timing.

### 7.3 Block cloning and BRT

`brt_pending_apply_vdev` sat in every trace. `zfs_bclone_enabled` was `1`. I
set it to `0` and it still hung. The tunable only blocks new clones
and cannot drain pending entries, so it was never going to help. Then
decisively:

```
$ zdb -e -p /dev/disk/by-id -T storage
BRT: empty
$ zpool get all storage | grep bclone
bcloneused 0 / bclonesaved 0 / bcloneratio 1.00x
```

It was ruled out. `brt_pending_apply` remained in the traces as an unexplained
frame, which kept re-seeding the wrong theory.

### 7.4 "txg_sync is idle, therefore the import succeeded"

The most expensive false positive. After tunable changes, the stack of the
process found by `pgrep -o 'zpool|zfs'` looked benign:

```
__cv_timedwait_common -> __cv_timedwait_idle -> txg_sync_thread
```

That looks like a completed import. It was not. `ps` eventually revealed two
`txg_sync` threads:

```
1242   S   <- boot-pool  (idle, and what pgrep was picking up)
10888  D   <- storage    (still wedged in ddt_lookup)
```

The kstat compounded it: `/proc/spl/kstat/zfs/storage/state` said `ONLINE`
while `zpool list`, `zpool status`, `zfs list`, `zfs mount` and `mount -t zfs`
all froze. `midclt call pool.query` returning IDs 105, 65 and 89 looks like
proof of an import. Those were middleware DB rows, and `pool.query` returned
`[]`.

Believing the import had completed cost a long chain of pointless work:
`kill -9` on D-state processes, manual `mount -t zfs`, `modprobe -r zfs` (which
returned `Module zfs is in use`), and a Python and libzfs `import_pool` detour
that produced nothing but API errors.

### 7.5 Other-OS testing

I tried a second OS: a pre-existing CachyOS install on a spare disk, worked
over IPMI, and the TrueNAS installer shell. Both hung identically, and on
CachyOS the entire desktop froze. The later repair environment was then
identified precisely as CachyOS `zfs-dkms 2.4.3-1` from `/usr/src/zfs-2.4.3`;
the cross-OS test itself still matters because it showed the fault was on-disk
pool state rather than a TrueNAS kernel or middleware bug, eliminating an
entire class of hypotheses.

---

## 8. Day 2: breakthrough, SysRq-W

Two corrections to the diagnostic method produced the answer.

Correction 1: SysRq-W, not SysRq-T. `echo t > /proc/sysrq-trigger` dumps
every task, producing pages of idle `taskq_thread` and `z_wr_int_0` noise.
`echo w` dumps only tasks in uninterruptible sleep, which is the entire set of
interest here.

Correction 2: remove the confounders. Run it with no dedup tunables set and no
`timeout` wrapper. `timeout 30 zpool import ...` had been destroying the
evidence by killing the process before its stack could be sampled. It also never
worked as a safety net, because D-state ignores SIGKILL entirely.

The result, main `zpool` thread:

```
taskq_wait+0x92/0xd0                      [spl]
dmu_objset_find_dp+0x16e/0x240            [zfs]
spa_check_logs+0x3a/0x60                  [zfs]
spa_ld_verify_logs+0x37/0x90              [zfs]
spa_load_impl.constprop.0+0x2a5/0x5b0     [zfs]
spa_load / spa_load_best / spa_import / zfs_ioc_pool_import
```

and the worker threads it was waiting on:

```
zio_wait+0x11a/0x240                      [zfs]
arc_read+0xfc7/0x1770                     [zfs]
zil_read_log_block+0xd9/0x3a0             [zfs]   (also zil_read_log_data, zil_claim_write)
zil_parse+0x23e/0x5a0                     [zfs]
zil_check_log_chain+0x112/0x1d0           [zfs]
dmu_objset_find_dp_impl / dmu_objset_find_dp_cb / taskq_thread
```

Confirmed independently by the import-progress kstat:

```
pool_guid            load_state   pool_name   notes
211359596362856278   2            storage     Syncing ZIL claims
```

`load_state 2` is `SPA_LOAD_OPEN`. The load never finished.

There is not one dedup function and not one BRT function anywhere in it. It is
pure ZIL.

---

## 9. Day 2: bug #1 in detail, ZIL chain into a hole vdev

The mechanism in this section is incomplete. The precondition (a hole vdev plus
a dangling non-zero `zh_log` DVA verified at DVA level to resolve into it) was
synthesised and imported writable on stock `zfs-2.4.3` without hanging: exit 0,
pool ONLINE, no D-state, twice from pristine state (`../CLAIMS.md` 2.7,
`../reproducibility/FINDINGS.md` finding 16). Hole plus dangling DVA is not
sufficient. Three mechanisms absorb an unclaimed chain: `zil_read_log_block()`
adds `ZIO_FLAG_SPECULATIVE` when `zh_claim_txg == 0` (`zil.c:256-257`);
`zil_check_log_chain()` returns 0 for `ECKSUM` and `ENOENT` (`zil.c:1328`); and
earlier than either, `traverse_zil_block()` skips an unclaimed chain before
`spa_load_verify()` can examine it (`dmu_traverse.c:93-98`, `../CLAIMS.md`
3.30).

The claimed-chain variant does not hang either (finding 17). A claimed chain
drops the `SPECULATIVE` flag and defeats the traversal skip; tested three times,
the import fails fast with `I/O error`, exit 1, no D-state, because
`zfs_blkptr_verify()` rejects a blkptr naming a hole vdev at `spa_load_verify()`
(`../CLAIMS.md` 3.31). `zil_check_log_chain()` and `zil_parse()` were both
entered and both returned (ftrace). It also fails read-only, which this pool did
not, so it is not a model of this incident (`../CLAIMS.md` 2.9). Neither chain
state hangs on `zfs-2.4.3`, and no candidate is now favoured over any other.

The incident hang and its stack are OBSERVED (`../CLAIMS.md` 1.2), but at least
one further ingredient is unidentified. The rest of this section is the analysis
made at the time, with later facts noted inline; it is not a demonstrated causal
account.

With the blocker located, I constructed a mechanism by reading actual OpenZFS
source rather than trusting issue summaries. Constructed, not established: the
account above is incomplete.

### The pool state

`zdb -C storage` failed repeatedly: it returned
`can't open 'storage': No such file or directory` on every attempt, because the
pool could not be opened by name while it was imported read-only or while the
writable import hung. The pool state was instead read from the vdev labels and
the export-scan config:

```
$ zdb -l /dev/sda1 | grep -E 'vdev_children|hole_array|type: .hole.|is_hole'
vdev_children: 3
hole_array[0]: 2
children[2]:  type: 'hole',  guid: 0,  is_hole: 1
```

and equivalently from the export-scan path:

```
$ zdb -e -p /dev/disk/by-id storage
...
vdev_children: 3
hole_array[0]: 2
children[2]:  type: 'hole',  guid: 0,  is_hole: 1
```

My removed SLOG is not gone, it is a hole, retained to keep child indices
stable. This single fact invalidates every standard recovery flag.

### The defective guard, `module/zfs/zil.c:1297`

In `zil_check_log_chain()` (canonical `zfs-2.4.3`, line 1297):

```c
	spa_config_enter(os->os_spa, SCL_STATE, FTAG, RW_READER);
	vd = vdev_lookup_top(os->os_spa, DVA_GET_VDEV(&bp->blk_dva[0]));
	if (vd->vdev_islog && vdev_is_dead(vd))
		valid = vdev_log_state_valid(vd);
	spa_config_exit(os->os_spa, SCL_STATE, FTAG);
```

A hole vdev has:

```
vdev_ishole = 1      (struct offset 0x2cf4)
vdev_islog  = 0      (struct offset 0x2cd0)
```

So the guard never fires. Meanwhile `zil_parse()` loops on:

```c
for (blk = zh->zh_log; !BP_IS_HOLE(&blk); blk = next_blk)
```

The ZIL header's DVA is non-zero, so `BP_IS_HOLE` is false and the loop
proceeds into `arc_read()` and `zio_wait()`. On the affected pool the thread
then blocked there forever (§8, appendix A.4). What I concluded at the time,
that it blocks because the DVA names a vdev with no backing device, is now
known to be wrong as a general statement:

That state does not block on a current release. Finding 16 built exactly it,
verified the DVA resolves into the hole, and imported the pool writable on a
pristine stock `zfs-2.4.3` module: exit 0, pool ONLINE, no D-state, repeated from
a pristine restore (`../CLAIMS.md` 2.7). Nor is the read dispatched to the hole's
own vdev ops: a read by DVA has `io_vd == NULL` and goes through
`vdev_mirror_ops`, where `vdev_mirror_child_select()` returns -1 because
`vdev_readable(hole)` is false, no child I/O is issued, and
`vdev_mirror_io_done()` sets `ENXIO` (`../CLAIMS.md` 4.9). That is a fail-fast
path. The narrow statement: on this pool, on this build, the ZIO issued here
never completed and the thread waited in `zio_wait()` indefinitely. Why is
UNKNOWN.

### Why read-only works, `module/zfs/spa.c:5604` (`master`: `5661`)

```c
static int
spa_ld_verify_logs(spa_t *spa, spa_import_type_t type, ...)
{
        if (type != SPA_IMPORT_ASSEMBLE && spa_writeable(spa)) {
                if (spa_check_logs(spa)) { ... }
        }
```

Verify and claim are gated on `spa_writeable(spa)`. Read-only imports skip both
stages entirely. There are two call sites in `spa_load_impl`, and both had to
be dealt with (line numbers as recorded at the time, against `master`; the
`zfs-2.4.3` equivalents are in parentheses):

- `spa.c:6163` (`zfs-2.4.3`: `6106`), `spa_ld_verify_logs()`, note
  `"Verifying Log Devices"`
- `spa.c:6232` (`zfs-2.4.3`: `6175`), `spa_ld_claim_log_blocks()`, note
  `"Claiming ZIL blocks"`, followed by
  `txg_wait_synced(..., spa->spa_claim_max_txg)`, note `"Syncing ZIL claims"`

That last `txg_wait_synced` explains the original stack trace from Day 1
(`spa_load_impl` into `txg_wait_synced`). It was a *different stage of the same
bug*, reached only sometimes. The stack trace shifting between attempts is
exactly what made this so hard to pin down.

### A genuine finding

amotin's log-vdev-removal fix (commit `1e1d64d`, authored by
`alexander.motin@TrueNAS.com`, closing openzfs/zfs#18277) is already in ZFS
2.4.3. It adds two `BP_IS_HOLE` early returns:

In `zil_destroy()` (canonical `zfs-2.4.3`, line 1099):
```c
	if (BP_IS_HOLE(&zh->zh_log) && zh->zh_flags == 0)
		return (B_FALSE);
```

In `zil_claim()` (canonical `zfs-2.4.3`, line 1173):
```c
	/*
	 * If the log is empty, then there is nothing to do here.
	 */
	if (BP_IS_HOLE(&zh->zh_log)) {
		dmu_objset_disown(os, B_FALSE, FTAG);
		return (0);
	}
```

It does not cover this case, because both test `BP_IS_HOLE` (an all-zero DVA)
rather than `vdev_ishole` (a valid-looking DVA pointing at a hole). That
predicate gap is real and source-confirmed (`../CLAIMS.md` 3.1, 3.5), and it is
the state my pool was in.

Patch A in the form that ran on this hardware did not close that gap: it
delegates the hole case to `vdev_log_state_valid()`, which returns `B_TRUE` for
a hole, so `valid` stayed true and nothing changed (§15 under Patch A,
`../CLAIMS.md` 1.12). Closing the predicate gap has never been demonstrated to
prevent the hang, in the test environment or on hardware, and the state the
predicate describes has since been imported without hanging on stock `zfs-2.4.3`
(2.7). The narrow, source-backed statement: the predicate is incomplete. The
pool was repaired by Patch B.

Also confirmed by reading source: `-o zil_prune=yes`, proposed in
OpenZFS #11364, was never merged. It is a proposal, not an option.

Where the `failmode` question is dealt with. The obvious lever for "an I/O is
hanging during import" is the pool's `failmode` property, and it is reasonable
to ask why it does not appear anywhere in this section. It was attempted at
incident time and would not take, and the source reasoning for why it could not
be reached during the load (three independent mechanisms, plus a fourth guard,
ZFS's own automatic `failmode` override, that cannot fire here) is set out in
full in [appendix B](#appendix-b-flags-and-tunables-tried). Read that before
concluding a tunable was overlooked.

---

## 10. Day 2: the binary NOP patch

TrueNAS ships no ZFS source, no DKMS, and no compiler. `/usr/src/zfs-2.3.4`
does not exist, `dpkg -l | grep zfs` is empty, and there is no `gcc`, `make`,
`cmake`, `autoconf` or `libtool`. So I patched the compiled module directly.

Locate the call sites:

```
$ objdump -d -r zfs.ko
  162dd0:  e8 eb 59 ff ff    call 1587c0 <spa_ld_verify_logs>
  162eec:  e8 3f 60 ff ff    call 158f30 <spa_ld_claim_log_blocks>
```

Convert virtual to file offsets. `readelf -S` gives `.text` at file offset
`0xc0`, addr `0`:

```
0x162dd0 + 0xc0 = 0x162e90     (verify)
0x162eec + 0xc0 = 0x162fac     (claim)
```

This distinction is easy to get wrong and matters absolutely. My recollection
is that treating `0x162e90` as a virtual address lands inside the
`spa_vdev_err` error path instead of the call site. Unbacked: no disassembly of
that address was captured, and none is reproducible now that the module is
gone, so treat the specific landing site as recollection rather than as a
verified fact. The general point, that a virtual address and a file offset are
different numbers and confusing them writes to the wrong bytes, does not depend
on it.

Verify safety before writing. A Python scan of the module's RELA sections found
no relocation targeting those bytes. (Unbacked detail: the entry count is
recorded from memory as 76,866 and the throwaway script was not kept, so
neither the number nor the scan is independently checkable. What is checkable
is the consequence, below.) The calls were already resolved (`e8 eb 59 ff ff`),
so NOPing them could not be undone by the module loader.
`/sys/kernel/security/lockdown` showed `[none]` and `modinfo zfs | grep sig`
was empty, so there was no signature enforcement.

Apply. `/usr` is a read-only ZFS dataset (`boot-pool/ROOT/25.10.4/usr`), so it
had to be remounted rw and restored afterwards:

```
Pre:   e8eb59ffff   e83f60ffff
Post:  9090909090   9090909090
Site 1: 9090909090
Site 2: 9090909090
BOTH CALL SITES NOPED - VERIFIED
md5: c63951df2acd1dba93df2c2093a916a0  (both copies match)
boot-pool/ROOT/25.10.4/usr on /usr type zfs (ro,...)
```

initramfs was correctly determined to be irrelevant.
`modprobe --show-depends zfs` proved the module loads from disk, and extracting
the TrueNAS initrd showed it contains exactly one file,
`./kernel/x86/microcode/AuthenticAMD.bin`.

The result was the first successful writable import. I verified data live by
enumerating several datasets and spot-checking file sizes against expected
values, including a 1.6 GB media file and a 4.0 T machine-learning dataset tree.
The sampled items matched. That is a metadata plausibility check on a sample,
not a whole-pool integrity statement; the whole-pool statement is the scrub in
§20.

This is a workaround, not a fix. Three reasons:

1. NOPing the calls means the ZIL chain is never claimed or cleaned, so the
   dangling reference stays on disk. Every stock kernel this pool was offered
   to in the days that followed hung on it: TrueNAS SCALE 25.10.4's own module,
   a second CachyOS install, and the TrueNAS installer shell. That is not a
   universal claim: finding 16 built this exact state and imported it writable
   on stock `zfs-2.4.3` with no hang (`../CLAIMS.md` 2.7). The bypass was still
   the wrong answer: it leaves the bad state on disk instead of removing it.
2. It must be re-applied after every TrueNAS update.
3. Zeroing `spa_ld_verify_logs`'s return means the `-F` rollback branch
   (`spa_load_max_txg = spa_last_ubs_txg`) can never fire, silently disabling a
   recovery mechanism.

That judgement is what drove me to a real source fix.

---

## 11. Day 2 to 3: CachyOS and the source fix

I installed CachyOS over TrueNAS to get a source tree, DKMS and a toolchain.
The environment that actually performed the repair was `/usr/src/zfs-2.4.3`,
packaged as CachyOS `zfs-dkms 2.4.3-1`, running on its LTS kernel,
`6.18.38-2-cachyos-lts`. The private history identifies the loaded custom build
as `zfs-2.4.3-0-g83020cf-dirty-dist`. That is confirmed: the `zfs-2.4.3`
release tag is commit `83020cf`, checked against `github.com/openzfs/zfs` on
2026-07-31. The `-0-` means zero commits past the tag; `-dirty` is the local
edits below. That source already contains amotin's upstream log-vdev-removal
fix (§9), so every import from this point ran that upstream logic plus my
custom recovery changes on top. On the source reading, amotin's fix cannot
cover this state: it tests `BP_IS_HOLE`, an all-zero DVA, and this pool held a
valid non-zero DVA aimed at a hole (`../CLAIMS.md` 3.5, 3.2). Note that this is
a source argument, not a test result. A pristine `zfs-2.4.3` module was never
imported against this pool, so "amotin's fix alone was not enough" is a source
argument only, not a measured result.

The machine first booted CachyOS's default kernel, `7.1.3-2-cachyos`. The first
source-patched import was attempted there: it passed the ZIL stages for the
first time and immediately panicked in the metaslab allocator (Bug #2, §12). I
then rebooted into the LTS kernel: partly to rule out the too-new 7.1 line
entirely (which ZFS 2.4.3 does not support, see the version gate below), partly
because 6.18-LTS is a kernel line ZFS 2.4.3 does support, rebuilt the module
for it, and every remaining step ran on `6.18.38-2-cachyos-lts`: the
`vdev_ishole` patches, the space-map skip import, the forced condense, and the
final clean export.

Build friction, in order:

1. Kernel version gate.

```
configure: error: *** Cannot build against kernel version 7.1.3-2-cachyos.
           *** The maximum supported kernel version is 7.0.
```

`/usr/src/zfs-2.4.3/META`, fixed with
`sed -i "s/Linux-Maximum: 7.0/Linux-Maximum: 7.99/"`. Built clean.

2. Compile errors from my first patch attempt.

```
zil.c:1185:2: error: use of undeclared identifier 'vd'
zil.c:1186:6: error: no member named 'dva_word' in 'struct blkptr'
zil.c:1187:6: error: use of undeclared identifier 'vd'
zil.c:1187:20: error: use of undeclared identifier 'vd'
```

Three of the four errors are the same undeclared `vd` (lines 1185, 1187:6,
1187:20); the fourth is the wrong `DVA_GET_VDEV` argument. Root causes: a
missing `vdev_t *vd;` local in `zil_claim`, and `DVA_GET_VDEV(&zh->zh_log)`
instead of `DVA_GET_VDEV(&zh->zh_log.blk_dva[0])`.

With both corrected, the module built: first for 7.1.3, and after the reboot
described above, for the LTS kernel and loaded:

```
zfs/2.4.3, 6.18.38-2-cachyos-lts, x86_64: installed
ZFS: Unloaded module v2.4.3-1
ZFS: Loaded module v2.4.3-1
```

Lock safety was verified against source before trusting the patch.
`spa_ld_claim_log_blocks` (`spa.c:5646` in `zfs-2.4.3`; `master`: `5703`) only
does `dmu_tx_create_assigned` plus
`dmu_objset_find_dp(..., zil_claim, tx, DS_FIND_CHILDREN)` and does not hold
`SCL_STATE`, so taking `SCL_STATE` as a reader inside `zil_claim` is safe.

The result was that the ZIL stages passed, which immediately exposed the second
bug.

> Open question, added 2026-08-02: why verify passed is not established. Log
> verify runs before log claim (`spa.c:6106` before `spa.c:6175`). Patch B acts
> inside `zil_claim()`, so it cannot explain how `spa_ld_verify_logs()` got
> through, and Patch A is a no-op on the hole path (`../CLAIMS.md` 1.12). So
> the first half of "the ZIL stages passed" has no explanation in this
> document. This is recorded as [`../CLAIMS.md`](../CLAIMS.md) 1.13, UNKNOWN.
> One candidate, `spa_log_state` surviving as `SPA_LOG_CLEAR` from the earlier
> `import -m`, was checked and eliminated five ways; see
> [`patches/README.md`](patches/README.md) Patch B. One candidate remains
> unchecked: the header having drained during the earlier writable import under
> the NOP'd module.

---

## 12. Day 3: bug #2 emerges, space-map corruption

The first writable import to get past the ZIL panicked in the allocator.

First form seen, the range-tree overlap check:

```
PANIC: zfs: rt={spa=storage vdev_guid=5884354480802639419 ms_id=2719 ms_allocatable}:
  adding segment (offset=2a7c0182d000 size=10cb0000)
  overlapping with existing one (offset=2a7c00105000 size=123f6000)

zfs_panic_recover -> zfs_range_tree_add_impl -> zfs_range_tree_walk
  -> metaslab_load -> metaslab_preload
```

plus a second on `vdev_guid=10979346336924854794 ms_id=2`.

Setting `metaslab_preload_enabled=0` silenced the preload panics, and then the
same corruption was hit on demand from the allocation path during txg sync:

```
metaslab_load -> find_valid_metaslab -> metaslab_activate
  -> metaslab_alloc_dva_range -> metaslab_alloc_range -> zio_dva_allocate -> zio_execute
```

The panic that actually mattered turned out to be one layer earlier, a hard
assertion in the space-map loader, which runs before `zfs_range_tree_add()` is
ever reached:

```
VERIFY3U(zfs_range_tree_space(smla->smla_rt) + sme->sme_run, <=, smla->smla_sm->sm_size)
    failed (17293090816 <= 17179869184)
PANIC at space_map.c:407:space_map_load_callback()

CPU: 44  PID: 2611  Comm: z_wr_iss_0  Tainted: G OE 6.18.38-2-cachyos-lts

spl_panic -> space_map_load_callback -> space_map_iterate
  -> space_map_load_length -> metaslab_load -> find_valid_metaslab
  -> metaslab_activate -> metaslab_alloc_dva_range -> zio_dva_allocate
```

`sm_size` is 17,179,869,184 = 2^34, matching `metaslab_shift: 34`, and the
overshoot is roughly 108 MiB.

Why this mattered so much: `VERIFY3U` is a hard assertion. It is not
`zfs_panic_recover()`, so `zfs_recover=1` cannot demote it to a warning. Days
of reasoning premised on "set `zfs_recover=1` and it will continue" were
structurally void. This was the single most important correction in Bug #2's
diagnosis.

This was confirmed to be on-disk rather than kernel-specific, having reproduced
identically on kernel 7.1.3 and 6.18.38-LTS (`Comm: z_metaslab`). My
recollection from searching at the time is that the assertion is old, firing as
`space_map.c:405` on a ZFS 2.0.2 report and `:406` on a 2.3.5 one (unbacked
recollection: no URL, issue number or captured page was kept for either, and
neither should be cited as evidence). What is backed is that TrueNAS 25.10.4's
own stock module crashed and rebooted the machine when the GUI imported this
pool (§3 timeline, Jul 22). No crash trace was captured, so attributing that
crash to this specific `VERIFY3U` is presumed, not confirmed. See ledger row 25
in §16, which says the same thing. Upstream has no repair tool: OpenZFS #13995
("Metaslabs recovery tool"), #3111 ("allow scrub to recalculate space maps",
open since 2015), #5803, and #15915. Every documented recovery is read-only
import, then `zfs send`, then destroy and recreate.

Why stock TrueNAS still could not import after the ZIL fix: the ZIL repair is
on-disk and portable, but the inconsistent `SM_FREE` space-map records had
never been rewritten. TrueNAS 25.10.4 carries the same assertion, and the GUI
(read-write) import crashed and rebooted my machine.

---

## 13. Day 3: breakthrough, forced metaslab condense

With no upstream tool, I had to build the repair. It came in two halves.

### Half 1: make the in-memory range tree correct

Replace the panic with a skip-and-count in the `SM_FREE` loading path. The nine
entries were treated as inconsistent or redundant FREE records; dropping them
produced a usable allocatable tree for this affected pool rather than
double-counting free space and panicking. This was an incident-specific
recovery change, not a general unconditional safety rule.

```c
if (zfs_range_tree_space(smla->smla_rt) + sme->sme_run > smla->smla_sm->sm_size) {
        cmn_err(CE_WARN, "space_map: skipping entry "
            "[%llx, %llx) beyond sm_size %llu", ...);
        smla->smla_ncorrupt++;
        return (0);
}
```

Live proof, nine entries rejected by the `SM_FREE` loader, in two clusters
matching the two affected metaslabs:

```
WARNING: space_map: skipping entry [801719000, 808349000)       beyond sm_size 17179869184
WARNING: space_map: skipping entry [808367000, 815927000)       beyond sm_size 17179869184
WARNING: space_map: skipping entry [815939000, 815a17000)       beyond sm_size 17179869184
WARNING: space_map: skipping entry [815a1d000, 81619d000)       beyond sm_size 17179869184
WARNING: space_map: skipping entry [818840000, 823aab000)       beyond sm_size 17179869184
WARNING: space_map: skipping entry [2a7c0182d000, 2a7c124f5000) beyond sm_size 17179869184
WARNING: space_map: skipping entry [2a7c12507000, 2a7c127d7000) beyond sm_size 17179869184
WARNING: space_map: skipping entry [2a7c135f3000, 2a7c16197000) beyond sm_size 17179869184
WARNING: space_map: skipping entry [2a7c179b5000, 2a7c23c9d000) beyond sm_size 17179869184
```

This alone gave me a fully working read-write pool. It is still a bypass. The
bad records remain on disk, and the `VERIFY3U` is present in both stock trees
this pool was offered to, TrueNAS 25.10.4's module and CachyOS's
`zfs-2.4.3`. That much is source fact.

Neither stock panic is recorded as such here. The TrueNAS crash is a GUI import
that crashed and rebooted the box, with no trace captured (§12, ledger row 25 in
§16). No import of this pool by a pristine, unpatched CachyOS `zfs-2.4.3` module
is narrated; §7.5 records a pre-existing CachyOS install that hung, and its ZFS
version was never identified. Such an import is possible in principle after
Patch B committed the zeroed ZIL header, but it is not in the record.

### Half 2: rewrite the space map on disk

Propagate the corruption count out of the loader and use it to force a
condense. `metaslab_condense()` discards the entire on-disk space map and
re-emits it from the in-memory `ms_allocatable` range tree produced by the
recovery load. That is the repair.

```c
if (ncorrupt > 0) {
        msp->ms_condense_wanted = B_TRUE;
        vdev_dirty(msp->ms_group->mg_vd, VDD_METASLAB, msp,
            spa_first_txg(msp->ms_group->mg_vd->vdev_spa));
        zfs_dbgmsg("metaslab %llu: %llu corrupt entries, condense forced", ...);
}
```

`ms_condense_wanted` is an existing universal override rather than an
invention. Its behavior is why this worked as an incident recovery:

- `metaslab_should_condense()`:
  `if (numsegs == 0 || msp->ms_condense_wanted) return (B_TRUE);` bypasses the
  `zfs_condense_pct` and `zfs_metaslab_condense_block_threshold` heuristics
  entirely.
- `metaslab_sync()`: a metaslab with no allocs or frees returns early unless
  `ms_loaded && ms_condense_wanted && txg <= spa_final_dirty_txg(spa)`, and
  `spa_final_txg` is `UINT64_MAX` in normal operation, so the guard always
  passes.
- `metaslab_preload()`: *"If a metaslab is being forced to condense then we
  preload it too."*

Note this required a signature change threaded through three files,
`space_map_load_length(..., uint64_t *ncorruptp)`, with `space_map_load()`
passing `NULL`.

### The breakthrough output

```
spa_misc.c:2485: 'storage' Finished importing
spa_misc.c:432:spa_load_note(): spa_load(storage, config trusted): LOADED

metaslab.c:3945:metaslab_condense(): condensing: txg 16404697, msp[2]    ffff8e44df037000,
    vdev id 0, spa storage, smp size 50760, segments 987,  forcing condense=TRUE
metaslab.c:3945:metaslab_condense(): condensing: txg 16404697, msp[2719] ffff8e44e47f6000,
    vdev id 1, spa storage, smp size 48688, segments 1110, forcing condense=TRUE
```

Two metaslabs with detected corrupt entries, `ms_id 2` on vdev 0 and
`ms_id 2719` on vdev 1, were both rewritten in a single txg (16404697), one txg
after load. (The `metaslab.c:3945` in that dbgmsg is the line number in the
patched module that emitted it. In pristine `zfs-2.4.3` the `condensing:`
dbgmsg is `metaslab.c:3929`.)

Only those two metaslabs condensed. Every other metaslab in the same dbgmsg
window logged an ordinary `metaslab_load_impl` line with no condense, which is
consistent with the flag firing only where `ncorrupt > 0` rather than
pool-wide. Artifact gap, flagged because the claim rests on it: that log window
is not published (it is transcribed from private debugging session logs,
`../CLAIMS.md` §6b), and only the two `condensing:` lines above were kept. It
is therefore the sole evidence that Patch D was surgical rather than pool-wide,
and a reader cannot check it. The two positive lines are quoted; the much
larger negative, "and nothing else condensed", rests on first-hand report
alone. Downgraded from "confirming" to "consistent with" on 2026-07-31.

Resulting state:

```
  pool: storage      state: ONLINE
  scan: scrub canceled on Wed Jul 22 00:15:22 2026
        raidz2-0 (6 disks) / raidz2-1 (6 disks)   all ONLINE  0 0 0
errors: No known data errors

storage  186T  140T  45.2T  -  62%  75%  1.08x  ONLINE
storage  99.3T used  30.0T avail  /storage
```

---

## 14. Day 3: verification on stock ZFS

The objective was portability, so it had to be proven on an unpatched system.

```
$ timeout 300 zpool export storage
rc: 0

$ zdb -e -p /dev/disk/by-id -mmmmm storage 0 2 ... | sort | uniq -d
(no output)          <- no duplicate entries remain
```

I rebooted into stock TrueNAS SCALE 25.10.4, no patches. TrueNAS describes this
release's ZFS as `2.3.4-1`, but that is the release description, not the
module: the private history excerpt identifies the running stock module as
`zfs-2.3.3-107-gec5aa9bfd`, a snapshot 107 commits past the `zfs-2.3.3` tag and
not the `zfs-2.3.4` release tag. §2 records the same distinction, and
`../CLAIMS.md` 4.8 depends on it: the test environment built the `zfs-2.3.4`
tag, which is a different tree:

```
truenas_admin@truenas[~]$ sudo zpool import -f storage
cannot mount '/storage': failed to create mountpoint: Read-only file system
Import was successful, but unable to mount some datasets

truenas_admin@truenas[~]$ zpool status storage
  pool: storage
 state: ONLINE
  scan: scrub canceled on Tue Jul 21 22:15:22 2026
config:
        NAME                            STATE   READ WRITE CKSUM
        storage                         ONLINE     0     0     0
          raidz2-0                      ONLINE     0     0     0
            wwn-0xXXXXXXXXXXXXXXXX-part1  ONLINE   0     0     0
            ... (6 disks)
          raidz2-1                      ONLINE     0     0     0
            ... (6 disks)
errors: No known data errors
```

The mount error is incidental, since `/` was mounted read-only at that moment.
The import itself succeeded on stock ZFS. The private pool history records
repeated stock imports, including a later fresh-install environment. See
[`evidence/2026-07-30-post-repair-history.txt`](evidence/2026-07-30-post-repair-history.txt).

Both bugs are repaired on disk, which is the distinction between a workaround
and a fix. No patched module was required for any import after 2026-07-22, on
either of the two stock installs this pool has run on since (TrueNAS 25.10.4 as
reinstalled here, and the later fresh install), nor for the scrub. Both
installs report the same ZFS build string, `zfs-2.3.3-107-gec5aa9bfd`; the
kernels differ (`6.12.91-production+truenas` and `6.12.95-production+truenas`).
That is the bounded claim the evidence supports; untested ZFS releases are
untested.

---

## 15. The patch set as applied

Against the CachyOS `/usr/src/zfs-2.4.3` source. Four logical patches touching
four source files in total. This is the set that ran on the affected hardware;
it is not the repository's whole patch inventory. Candidate E is specified as
one complete diff hunk in
[`../reproducibility/patches/`](../reproducibility/patches/). Candidate F is not
a diff but illustrative fragments: two of its hunks use a bare `@@` with no
line numbers, it will not apply, and it does not compile as written. The
recommended form of C is not written as code anywhere; it exists only as one
paragraph of prose in [`patches/README.md`](patches/README.md). None of the
three has ever been built or run.

> Patch C / Patch D boundary: this section is NOT authoritative.
> [`patches/README.md`](patches/README.md) groups the counter plumbing (the
> `smla_ncorrupt` field, the `space_map_load_length()` signature change, the
> `space_map_load()` `NULL` call and the `space_map.h` declaration) under Patch
> D. This section groups all four under Patch C. The same code therefore
> carries two labels depending on which document you read. `patches/README.md`
> tabulates the disagreement and declares itself authoritative, and its
> grouping matches `../CLAIMS.md` §5. Use its grouping. Note also, from that
> file: C as documented does not compile without D's struct field, so the two
> are not independently applicable in either grouping. All of C and D were
> compiled and loaded together; the split is editorial, not historical.

Before copying anything out of this section: these are documented diffs with
surrounding context, not `git am`-able patches. Line numbers and context are
against `zfs-2.4.3` and will not apply cleanly to current `master`. Each must
be regenerated with `git format-patch` against the tree being patched. Two of
them additionally carry corrections or prohibitions recorded below, so read the
prose, not just the code blocks.

A note on line numbers: in the canonical pristine `zfs-2.4.3` source, the guard
sits at `zil.c:1297` (the `vdev_lookup_top()` on the line above is 1296), which
is how §9 refers to it. The recovery machine records the same logical guard at
`zil.c:1322` after the local Patch B edits above it.

> The arithmetic shows the documented Patch B is not byte-complete. Neither
> number is changed.
>
> 1322 - 1297 = 25 lines inserted above the guard. Patch B as documented below
> is an 18-line block (six lines of comment, twelve of code), plus a
> `vdev_t *vd;` declaration in the function prologue = 19. That leaves six
> unaccounted for.
>
> Those six can be located rather than merely noted. The applied Patch B
> condition was read back at `zil.c:1191`, and it is the 9th line of the
> documented block. Working backwards (25 total inserted, 18 in the block, so 7
> above it; block `if` at 1191 - 7 - 8) puts the insertion point at pristine
> `zil.c:1176/1177`, which is exactly the closing brace of the
> `if (BP_IS_HOLE(&zh->zh_log))` early return and the blank line after it. That
> is precisely where Patch B belongs. The block is in the right place and is
> the right size; the six unrecorded lines sit above it, between `zil.c:1176`
> and the start of the block.
>
> One of the seven is the `vd` declaration. The remaining six are not recorded
> anywhere in this repository. The most plausible reading is debug output (a
> `zfs_dbgmsg()` or `cmn_err()` reporting the header state) added during the
> live recovery and never transcribed, which is consistent with the module
> reporting itself as `zfs-2.4.3-0-g83020cf-dirty-dist`. That is an
> inference, not a record. The recovery machine no longer holds that tree, so
> the six lines are unrecoverable.
>
> What this does not affect. Patch A's no-op finding rests on the guard text
> read back at 1322, not on the offset. Patch B's logic and its effect rest on
> the text read back at 1191 and on the repair having worked (1.8, 1.9).
> Neither depends on this arithmetic.
>
> What it does affect. Anyone reconstructing Patch B from this document builds
> something about six lines smaller than what actually ran. Because the missing
> lines sit above a self-contained block, they are unlikely to change the
> outcome, but that is an inference, and the honest statement is that the
> documented Patch B is a faithful reconstruction of the logic, not a
> byte-exact copy of the tree that repaired the pool.

### Patch A: `zil_check_log_chain` in `module/zfs/zil.c`

The source on the recovery machine, read back verbatim, has no NULL check; and
the guard as applied cannot have changed the hole path, because it delegates to
`vdev_log_state_valid()`, which returns `B_TRUE` for a hole. See
[`../CLAIMS.md`](../CLAIMS.md) 1.12 and [`patches/README.md`](patches/README.md)
Patch A. The repair of this pool is attributable to Patch B.

What actually ran, read back from `/usr/src/zfs-2.4.3/module/zfs/zil.c:1322`:

```diff
  vd = vdev_lookup_top(os->os_spa, DVA_GET_VDEV(&bp->blk_dva[0]));
- if (vd->vdev_islog && vdev_is_dead(vd))
+ if ((vd->vdev_islog && vdev_is_dead(vd)) || vd->vdev_ishole)
          valid = vdev_log_state_valid(vd);
```

The guard is `zil.c:1297` and the `vdev_lookup_top()` above it is `zil.c:1296`,
in both `zfs-2.4.3` and current `master`. `vdev_ishole` is a struct field
(`include/sys/vdev_impl.h:284`; `master`: `:276`), not a macro.

Why this is a no-op for a hole comes down to how `valid` gets set. Only
`valid = B_FALSE` makes the function return 0 and skip the chain. A hole vdev
has `vdev_op_leaf = B_TRUE` (`vdev_missing.c:132`), opens successfully via
`vdev_missing_open()`, has `vdev_removed` cleared at `vdev.c:2228` and
`vdev_faulted` false, and so `vdev_log_state_valid()` returns `B_TRUE` (function
defined at `vdev.c:5726`, three-term return expression at `:5728-5730`).
Citation note: `../CLAIMS.md` §7 indexes this function by its definition line
only, so `5728-5730` does not resolve against §7 on its own; `../CLAIMS.md` 1.12
cites the body range directly. `valid` stays true, the early return at
`zil.c:1301-1302` never fires, and `zil_parse()` is reached exactly as before.
The corrected form, which sets `valid = B_FALSE` directly and folds in the NULL
case, is in [`patches/README.md`](patches/README.md) and has never been built or
run.

The latent NULL dereference on `vdev_lookup_top()` is real and independent
(`../CLAIMS.md` 3.6), but it was not fixed here and was not exercised by this
incident.

### Patch B: `zil_claim` in `module/zfs/zil.c`, the actual ZIL repair

This is the patch that repaired the pool. With Patch A shown to be inert on the
hole path, B is the only change in the set that acts on the dangling header.
Read back verbatim from the recovery machine at `zil.c:1191`.

Inserted after the existing `BP_IS_HOLE(&zh->zh_log)` early return
(`zil.c:1173`), before `first_txg = spa_min_claim_txg(...)`:

```c
/*
 * If the log starts on a hole vdev (e.g., a SLOG device was
 * removed and became a hole in the vdev tree), the ZIL chain
 * references blocks that no longer exist. Clear the ZIL
 * header to break the dangling reference.
 */
spa_config_enter(os->os_spa, SCL_STATE, FTAG, RW_READER);
vd = vdev_lookup_top(os->os_spa, DVA_GET_VDEV(&zh->zh_log.blk_dva[0]));
if (vd != NULL && vd->vdev_ishole) {
        spa_config_exit(os->os_spa, SCL_STATE, FTAG);
        memset(zh, 0, sizeof(zil_header_t));
        if (os->os_encrypted)
                os->os_next_write_raw[tx->tx_txg & TXG_MASK] = B_TRUE;
        dsl_dataset_dirty(dmu_objset_ds(os), tx);
        dmu_objset_disown(os, B_FALSE, FTAG);
        return (0);
}
spa_config_exit(os->os_spa, SCL_STATE, FTAG);
```

Plus `vdev_t *vd;` added to the function's locals. Omitting it is what produced
the `use of undeclared identifier 'vd'` compile errors recorded in §11.

Two deliberate design decisions:

- `memset` plus `dsl_dataset_dirty`, not just skip. This is what makes the fix
  persist to disk and the pool portable.
- `zio_free` deliberately omitted. You cannot free blocks residing on a vdev
  that no longer exists, and attempting it would be the actual dangerous move.

Precedent. The `memset` + `os_encrypted` + `dsl_dataset_dirty()` sequence is
not new. It is the existing `SPA_LOG_CLEAR` block at `zil.c:1217-1220`, a few
lines below in the same function. What Patch B adds is the `vdev_ishole`
condition that reaches it, and the decision to omit `zio_free`. Reusing an
established in-tree pattern is a point in the patch's favour. See
[`../CLAIMS.md`](../CLAIMS.md) 3.22 for the precise attribution of which lines
came from amotin's `1e1d64d` and which predate it.

### Patch C: `space_map_load_callback` in `module/zfs/space_map.c`

> WARNING: do not reuse this patch. It replaces a data-integrity assertion with
> an unconditional skip, for every pool, with no opt-in. It was correct for a
> one-off recovery on a pool with no backup and no alternative, and it is not
> acceptable as a default. The form appropriate for general use replaces the
> `VERIFY3U` with `zfs_panic_recover()`, so behaviour is unchanged at
> `zfs_recover=0` and the condition becomes survivable only when the pool's
> administrator has explicitly opted in. That form has not been written and has
> never been run; it exists only as prose in
> [`patches/README.md`](patches/README.md). Anyone proposing C upstream has to
> write it first. See also [`../CLAIMS.md`](../CLAIMS.md) 5, Patch C.

The replaced `VERIFY3U` statement spans `space_map.c:406-407` in pristine
`zfs-2.4.3` (`master`: `405-406`); the panic text above reports `:407`.

The replacement sits inside the `sme_type == smla_type` branch, so it affects
only the range-tree add path and leaves the `zfs_range_tree_remove()` path
untouched:

```c
space_map_load_callback(space_map_entry_t *sme, void *arg)
{
	space_map_load_arg_t *smla = arg;
	if (sme->sme_type == smla->smla_type) {
		/* was: VERIFY3U(zfs_range_tree_space(smla->smla_rt) +
		 *              sme->sme_run, <=, smla->smla_sm->sm_size); */
		if (zfs_range_tree_space(smla->smla_rt) + sme->sme_run >
		    smla->smla_sm->sm_size) {
			cmn_err(CE_WARN, "space_map: skipping entry "
			    "[%llx, %llx) beyond sm_size %llu",
			    (u_longlong_t)sme->sme_offset,
			    (u_longlong_t)(sme->sme_offset + sme->sme_run),
			    (u_longlong_t)smla->smla_sm->sm_size);
			smla->smla_ncorrupt++;
			return (0);
		}
		zfs_range_tree_add(smla->smla_rt, sme->sme_offset,
		    sme->sme_run);
	} else {
		zfs_range_tree_remove(smla->smla_rt, sme->sme_offset,
		    sme->sme_run);
	}

	return (0);
}
```

with `uint64_t smla_ncorrupt;` added to `space_map_load_arg_t`, and:

```c
space_map_load_length(space_map_t *sm, zfs_range_tree_t *rt, maptype_t maptype,
    uint64_t length, uint64_t *ncorruptp)          /* signature changed */
...
        smla.smla_ncorrupt = 0;
        int err = space_map_iterate(sm, length, space_map_load_callback, &smla);
        if (ncorruptp != NULL)
                *ncorruptp = smla.smla_ncorrupt;
```

`space_map_load()` passes `NULL`, preserving its existing signature and every
other caller:

```c
int
space_map_load(space_map_t *sm, zfs_range_tree_t *rt, maptype_t maptype)
{
	return (space_map_load_length(sm, rt, maptype,
	    space_map_length(sm), NULL));
}
```

and the declaration in `include/sys/space_map.h`:

```diff
  int space_map_load_length(space_map_t *sm, zfs_range_tree_t *rt,
-     maptype_t maptype, uint64_t length);
+     maptype_t maptype, uint64_t length,
+     uint64_t *ncorruptp);
```

### Patch D: `module/zfs/metaslab.c` (`metaslab_load_impl`), the space-map repair

```c
if (msp->ms_sm != NULL) {
        uint64_t ncorrupt = 0;
        error = space_map_load_length(msp->ms_sm, msp->ms_allocatable,
            SM_FREE, length, &ncorrupt);

        /* Now, populate the size-sorted tree. */
        metaslab_rt_create(msp->ms_allocatable, mrap);
        msp->ms_allocatable->rt_ops = &metaslab_rt_ops;
        msp->ms_allocatable->rt_arg = mrap;

        struct mssa_arg arg = {0};
        arg.rt = msp->ms_allocatable;
        arg.mra = mrap;
        zfs_range_tree_walk(msp->ms_allocatable,
            metaslab_size_sorted_add, &arg);

        if (ncorrupt > 0) {
                msp->ms_condense_wanted = B_TRUE;
                vdev_dirty(msp->ms_group->mg_vd, VDD_METASLAB, msp,
                    spa_first_txg(msp->ms_group->mg_vd->vdev_spa));
                zfs_dbgmsg("metaslab %llu: %llu corrupt entries, "
                    "condense forced", (u_longlong_t)msp->ms_id,
                    (u_longlong_t)ncorrupt);
        }
} else {
```

### Runtime tunables used during the repair import

```
zfs_recover=1
metaslab_preload_enabled=0
spa_load_verify_data=0
spa_load_verify_metadata=0
zil_replay_disable=0          <- left at default so replay runs after the repair
```

`zil_replay_disable` gates mount-time `zil_replay()` only. It never gated the
import-time verify and claim paths; which is why `=1` did nothing on Day 2, and
why it has no effect on the claim path that performs the repair. It was
deliberately left at `0` so replay would run normally once the pool was
repaired, and replay then completed cleanly.

### Explicitly considered and rejected

| Approach | Why rejected |
|---|---|
| `range_tree.c` overlap tolerance | Unnecessary. Those checks use `zfs_panic_recover` and honour `zfs_recover=1`, and the real hard assert was in `space_map.c`. Kept the change surface minimal. |
| `zdb -e -ww` or `zdb -R` raw writes | Copy-on-write and checksum problems. One wrong block loses the pool: 140 TB allocated, no backup. |
| `zpool initialize` | Only appends to the log space map, leaving the bad on-disk map untouched. Also weeks of runtime on 186 T. |
| `zpool trim` | No effect on ZFS space maps |
| `zhack metaslab leak` | Marks space allocated, the opposite of what was needed |
| `zpool clear -s` | No such subcommand in the `zpool` builds available to me during the incident (TrueNAS 25.10.4 and CachyOS `zfs-2.4.3`), and none in `zpool-clear(8)` for 2.4.3. I have not checked every ZFS release, so read this as "not available here", not as a universal negative. |
| `space_map_set_wants_condense()` | Does not exist in 2.4.3. `grep` across the source tree returns nothing. |
| Waiting for natural condense | Not viable on any timescale that mattered. A handful of extra entries is nowhere near the 200 % `zfs_condense_pct` threshold, so there was no reason to expect a natural condense to fire; this was a judgement made at the time from reading `metaslab_should_condense()`, not something waited out and measured. |
| `smp_pad[5]` reuse | It is on-disk format, so abandoned |

---

## 16. False conclusions ledger

This is the most reusable thing in this document. The patches repaired one
pool; the stack traces describe one failure. This table records thirty wrong
conclusions from the three days, in the sequence they happened, each with the
evidence that overturned it named beside it.

It is written as a ledger rather than a narrative for two reasons. First,
because an error that is only mentioned where it happened disappears into the
story; listed side by side, the errors turn out to have one shape, stated after
the table. Second, because a false-conclusion ledger is a diagnostic artifact
in its own right: a reader debugging a different ZFS problem can run their own
hypothesis down the "Claim" column and find several of their own assumptions
already refuted in the "Reality" column, without reading anything else here.

Each entry cost real time. Several cost hours; #4 nearly cost a boot pool and
#11 cost most of a day. Nothing in the table is hypothetical: every row was
believed, acted on, and then overturned by a specific piece of evidence that is
named.

| # | Claim | Reality |
|---|---|---|
| 1 | Docker and apps config causes the initial 15-min boot | Docker and apps were initially suspected; the pool import was wedged and was the underlying cause of the initial startup symptoms |
| 2 | TrueNAS NAS-133437 (HDD apps pool timeout) explains the later recurrence | The later recurrence was six stuck tasks plus a blocked pool import, not a separate Docker startup-delay problem |
| 3 | A failing disk, bad HBA, or wedged SAS expander | Refuted by dmesg, SMART, `sas2ircu`, `diskstats`, and a healthy RO import |
| 4 | `zdb -l` "failed to unpack label" means corrupt labels | Labels live on partitions; `zdb -l /dev/sda1` was fine |
| 5 | Intermittently flaky `sdk` and `sdp` | Artifact of `printf` with no newline when `zdb` output was empty. Three identical repeat runs disproved it. What is disproved is the *apparent run-to-run flakiness of `zdb -l` output*. The SLOG SSDs really did flicker on the SAS backplane (§3, §20 open item 3); that is a separate observation and is not what produced this one. |
| 6 | USB disk `sdq` pulled into the pool | Never appeared in any label |
| 7 | MMP and multihost, from #10828 | `fail_intervals=0` changed nothing, and `mmp_valid = 0` |
| 8 | fast_dedup DDT `FLUSHING CHECKPOINT` is the blocker | Zero DDT frames in any D-state stack once tunables were removed |
| 9 | `zfs_dedup_log_cap=0` disables the dedup log | `0` means unlimited or default |
| 10 | Block cloning and BRT | `BRT: empty`, `bcloneused 0`, and `zfs_bclone_enabled=0` changed nothing |
| 11 | `txg_sync` idle implies import succeeded | Two `txg_sync` threads, and `pgrep` was picking up boot-pool's |
| 12 | kstat `ONLINE` implies imported | `load_state 2 / Syncing ZIL claims`, so the load never finished |
| 13 | `midclt` or libzfs returning a pool ID implies imported | Middleware DB rows only, and `pool.query` returned `[]` |
| 14 | It's a TrueNAS kernel bug, so stock or newer ZFS will fix it | CachyOS and the installer hung identically |
| 15 | `zil_replay_disable=1` is the fix | Gates mount-time replay, not import-time verify and claim |
| 16 | `-F`, `-X` or `-T <txg>` will roll back past it | Same verify path runs first, and the uberblock ring spans only ~128 txgs while the SLOG existed in all of them |
| 17 | `zfs_recover=1` plus `zdb -e -bcsvL` from #12980 is a confirmed fix | The quote is real but comes from a metaslab-corruption case, not a ZIL hang. Here `zdb` hung on the same read, so the recipe cannot even run. |
| 18 | Issues #17528 and #17559 support the dedup theory | Neither issue describes this failure. Citing issue numbers is not evidence unless the page is actually read. |
| 19 | `-o zil_prune=yes` is available | Unmerged proposal (#11364) |
| 20 | Cachefile held a clean no-SLOG config | The `grep -c "type: 'log'"` = 0 came from boot-pool being the only entry |
| 21 | Export from a RO import rewrites the labels | Import timestamp unchanged, and the next import hung |
| 22 | The metaslab panic is `zfs_range_tree_add_impl` and `zfs_recover` will let it continue | The real panic is `VERIFY3U` in `space_map_load_callback`, which runs earlier and ignores `zfs_recover` |
| 23 | The space-map assert is new 2.4.x hardening absent from 2.3.4 | Refuted by source: the `VERIFY3U` is present in `zfs-2.3.3`, which is the incident's lineage, and the TrueNAS module running `zfs-2.3.3-107-gec5aa9bfd` crashed the machine on import. Do not read that crash as a confirmed panic at this assertion: no trace was captured, so the attribution is presumed, per row 25. The source reading settles the row without it. (§12 also recalls the assertion firing as `space_map.c:405` on a 2.0.2 report, but no citation was kept; unbacked recollection, and not needed.) |
| 24 | Space maps self-heal through normal use | They do not, without a full condense and rewrite |
| 25 | The TrueNAS GUI can import it normally, no preparation needed | The GUI performs a writable import, which crashed and rebooted the machine. No crash trace was captured, so the space-map assertion is the presumed rather than confirmed cause, but it is the only remaining hard panic on the stock import path |
| 26 | The pool vanished or the labels are damaged | Already imported. `zpool import` listed only boot-pool while `zpool status` showed `storage ONLINE`. Also, label `state: 0` was guessed as "exported" when `0` is ACTIVE. |
| 27 | Export hangs or is broken | Merely slow under load. `timeout 300` returned `rc: 0`, and exports are immediate now that the pool is healthy. |
| 28 | CachyOS was wiped and the patched module is gone | It still booted, with both patches intact in `/usr/src` |
| 29 | `grep smla_ncorrupt zfs.ko.zst` finds nothing, so the patch is missing | Local variable names do not survive compilation. Runtime dbgmsg proved it live. |
| 30 | The only fix is `zfs send` to a new pool | Refuted by the forced-condense repair |

The pattern is that nearly every false conclusion came from inferring success
or causation from an indirect signal, whether a kstat, a `pgrep` result, a
middleware ID, a suggestive but unrelated stack frame, or an issue-tracker
summary read without fetching the page. Every one was overturned by going one
level lower: SysRq-W instead of kstats, `ps aux` instead of `pgrep`, actual
source instead of issue titles.

---

## 17. Initial assumptions that were wrong

- That the SLOG could be cleanly removed. ZFS converts a removed log vdev to a
  `hole`, and on this pool the ZIL headers were still pointing at it. That is
  what happened here, not general ZFS behaviour: every natural removal route
  tested clears the headers first (`../CLAIMS.md` 3.11, 3.12, 3.14, 3.18), and
  how this pool avoided that is UNKNOWN (4.2). Among the `zpool` subcommands
  and flags tried during this incident and enumerated in the reproduction
  work's nine routes (`../reproducibility/FINDINGS.md` finding 12), none cleans
  this up once the devices are already gone, and none skips the hole. That is a
  bounded negative over the routes that were tried, not a proof that no such
  path exists; see `../CLAIMS.md` 3.20, which makes the same point explicitly.
- That `-m` handles a missing log device. It handles a log vdev that is OFFLINE
  or UNAVAIL in config. Against a hole (`guid: 0`, `is_hole: 1`) it is a
  no-op.
- That restoring the TrueNAS config could help. Vdev topology lives in the ZFS
  labels on the data disks. `storage_volume` stores `vol_name, vol_guid` and
  nothing else.
- That re-inserting the SSDs would restore the log. Members are matched by
  GUID, so wiped disks are indistinguishable from absent ones. And they were
  flickering, which would reintroduce the original I/O stalls.
- That `timeout N zpool import` bounds the operation. D-state ignores SIGKILL.
  The `zpool` process persists, keeps the spa resident, blocks
  `modprobe -r zfs`, and forces a hard reboot. `timeout` also silently
  destroyed diagnostic evidence.
- That a successful read-only import means the pool is healthy. It exercises
  neither faulty path. This was the most consequential wrong assumption of
  the entire incident.
- That one bug was the whole story. Fixing Bug #1 is what revealed Bug #2.
  The second fault had been masked the entire time.

---

## 18. Diagnostic methodology: what worked

1. Requiring direct kernel evidence before accepting any root cause. None of
   the four wrong root causes was ever supported by a blocked-task stack trace,
   and each was discarded once one was captured. Four checks were enough:

- Is this hypothesis visible in a D-state stack trace, or only in a suggestive
  statistic?
- Has the cited upstream issue actually been read, or only its title?
- Does the proposed fix touch pool metadata, and if so what is the least
  destructive alternative?
- What in the current diagnostic setup could be manufacturing this evidence?

The last check mattered most. Removing every dedup tunable before capturing the
stack trace is what exposed the real stack, because the tunables had been
perturbing timing and producing the DDT frames that the wrong theory rested on.

2. SysRq-W over SysRq-T, with confounders removed. `echo w` shows only
   uninterruptible tasks. Combined with no tunables and no `timeout` wrapper,
   it gave a clean, unambiguous answer after two days of noise.

3. Reading the actual source. `zil.c:1264-1329` (`zil_check_log_chain()`, same
   lines in both trees), `spa.c:5657-5677` (`spa_ld_verify_logs()`;
   `zfs-2.4.3`: `5600-5620`), `spa.c:5703-5725` (`spa_ld_claim_log_blocks()`;
   `zfs-2.4.3`: `5646-5668`), and the `spa_load_impl` call ordering at
   `spa.c:6163` and `6232` (`zfs-2.4.3`: `6106` and `6175`) are what made the
   fix designable instead of guessable. The `vdev_ishole` versus
   `vdev_islog` distinction, the `spa_writeable()` gate explaining the
   read-only asymmetry, and the discovery that the upstream fix tests the wrong
   predicate all came from source, not from issue trackers. Note what the last
   of those is and is not: the guard gap is a source fact, and closing it has
   never been demonstrated to prevent any hang (§9 correction, `../CLAIMS.md`
   2.7 and 2.8).

4. Verifying before writing. The RELA relocation scan (§10; the entry count and
   the script itself were not kept), the `readelf` virtual-to-file offset
   conversion, md5 comparison of both copies, `modprobe --show-depends` to
   prove the load path, and `zdb -l | grep name` before every `wipefs`. The
   last one is what prevented the boot pool being wiped.

5. Cross-OS reproduction. Hanging identically on CachyOS and the TrueNAS
   installer eliminated the TrueNAS-kernel and middleware class of hypotheses
   in one test. It does not prove the fault is on-disk state: all three
   environments run Linux and OpenZFS, so an OpenZFS-common cause would behave
   the same way.

6. Choosing repair over bypass. Patch B's `memset` plus `dsl_dataset_dirty`,
   and Patch D's forced condense, are the reason the pool is now portable
   instead of permanently dependent on a custom kernel module. Three separate
   bypasses (NOP patch, `metaslab_preload_enabled=0`, space-map skip) each
   worked, and each was insufficient, because none of them changed the bytes
   on disk.

7. Minimal change surface. Four logical patches touching four source files.
   `range_tree.c` was deliberately left alone once its checks were confirmed to
   honour `zfs_recover`. Forced condense fired on the two metaslabs with
   detected corrupt entries. That it did not fire elsewhere in the pool is
   consistent with the logs seen at the time, but those logs are unpublished,
   so read it as consistent-with rather than confirmed (§13).

---

## 19. Near-misses and self-inflicted damage

I nearly wiped my boot pool. A `labelclear` plus `wipefs` was lined up against
`/dev/sdo` and `/dev/sdp` on the strength of a device-name guess carried over
from an earlier boot. Those were the boot-pool disks. The only thing that
caught it was running `zdb -l | grep name` on each device first: `sdo` and
`sdp` came back `boot-pool`, while `sdk` and `sdl` came back `name: 'storage'`.
Note that `name: 'storage'` alone would not have been sufficient to identify
the SLOG, since every data disk reports it too; what made the check decisive
was the negative on `sdo`/`sdp`.

With four identically-modelled Samsung 480 G SSDs in the chassis and device
names reshuffling across boots and operating systems, name-based identification
was never safe. Serials and WWNs were the only reliable identifiers. Label
verification should be mandatory before any destructive command.

I destroyed one working state, and acted for hours as if I had destroyed a
second.

1. CachyOS was installed over the top of TrueNAS, discarding the working NOP
   patch.
2. TrueNAS was then reinstalled on the false premise that stock ZFS would now
   import cleanly. The GUI import crashed and rebooted the machine, and I
   assumed the reinstall had wiped CachyOS and with it the only patched module
   capable of repairing the pool. It had not: CachyOS still booted, with both
   patches intact in `/usr/src` (ledger #28), and the repair continued from
   there.

Both reinstalls were avoidable and both cost hours. The second was pure loss:
it fixed nothing, and the tooling I believed it had destroyed was intact the
whole time.

No metadata backup was ever obtained. Before modifying anything I wanted a copy
of the pool metadata, on the reasoning that the ZIL fix writes to dataset
headers and a bad write would be unrecoverable. Every attempt failed.
`zdb -e -ddd storage`, `zdb -ddd -u`, and `zdb -U /etc/zfs/zpool.cache` all
timed out or returned `can't open 'storage'`. The only artifact captured was a
single vdev label print (`txg: 16404589`). All modifications proceeded without
a backup. In hindsight, the read-only import window was the
moment to capture `zdb -mmmmm` and full label dumps to a file, before any
patching.

There was repeated unkillable state. Every failed attempt left a D-state `zpool`
holding the spa, requiring a hard reboot, perhaps a dozen times across three
days. This also blocked `modprobe -r zfs`, which at one point made it impossible
to load a patched module that had already been built and verified.

Tooling assumptions cost time as well. Several cycles were burned on `sas2ircu`,
`iostat` and `smartctl` in environments where they were not installed or did not
apply, including ATA-worded SMART greps run against SAS disks. Verify a tool
exists before building a diagnostic plan on it.

---

## 20. Final state and open items

### Resolved

The headline result: the post-repair scrub completed clean. From Jul 22 21:46:30
to Jul 27 06:29:18, which is 4 days 8 hours 42 minutes, a full scrub of the
repaired pool ran to completion and reported `scan done errors=0`, over the 140
T allocated that the final pool status records. The artifact is
[`evidence/2026-07-30-post-repair-history.txt`](evidence/2026-07-30-post-repair-history.txt),
and it is the only part of this document that a reader can independently open
and check. That artifact backs more than the scrub: it also records the repeated
stock imports, the patched module string `zfs-2.4.3-0-g83020cf-dirty-dist` that
confirms the incident tree is tag `83020cf`, the stock module string
`zfs-2.3.3-107-gec5aa9bfd`, and the scrub-cancel timestamp. Everything else in
this document is transcribed from private session logs (`../CLAIMS.md` §6b).

Why it carries the weight it does: Patch D forces a metaslab condense, which
discards and re-emits allocation metadata on disk, and Patch B zeroes a
dataset's ZIL header. Both are destructive operations performed on a pool with
no backup and no spare capacity. A full read of every reachable block
afterwards, with zero errors, is the evidence that neither of them lost data.
`../CLAIMS.md` records this and the repeated stock imports (1.8, 1.9) as the
strongest single result in the repository.

What a scrub does not cover, stated because Patch D is the more invasive of the
two. A scrub traverses the block tree and verifies checksums. It does not audit
space-map correctness. A re-emitted space map that over-reports free space
would pass a scrub cleanly and would only appear later as allocation into
occupied space. So this result is strong evidence for Patch B and partial
evidence for Patch D. What supports D beyond the scrub is the pool returning to
normal read-write service with no allocation fault reported. Scope is here and
in `../CLAIMS.md`.

What it does not establish: that any SLOG-only synchronous writes survived the
original failure. Those were never recoverable and the scrub says nothing about
them. It also does not extend beyond this pool and these builds.

The rest of the resolved state: the pool is in normal production service on
stock TrueNAS SCALE 25.10.4 with no patched module:

- Imports cleanly with `zpool import -f storage`, within a couple of minutes.
- Mounted at `/mnt/storage` and read-write.
- Survives reboots without hanging, without stuck jobs, and without the
  15-minute startup that began this whole investigation.
- Exports normally. No hangs.

### Open

1. Both bugs remain unfixed in OpenZFS, as of 2026-07-31. On that date
   OpenZFS #17427 and #12980 (ZIL and import hang) had no merged fix,
   and #13995 and #3111 (space-map repair) had been open for years. This is a
   time-sensitive statement about an external tracker; re-check it before
   citing it. On the `vdev_ishole` case specifically, the defensible statement
   is the narrow one: the predicate in `zil_check_log_chain()` is incomplete:
   it tests `vdev_islog && vdev_is_dead(vd)`, which a hole does not satisfy
   (`../CLAIMS.md` 3.1). That is a source fact. It is not supported to say
   the guard "addresses" this incident: Patch A as applied changed nothing on
   the hole path (1.12), and the condition it guards has since been shown not
   to hang a writable import on stock `zfs-2.4.3` (2.7, finding 16).

   This incident is a fully characterised observation, not a fully characterised
   reproduction. The precondition (a hole vdev together with a surviving
   non-zero `zh_log`) is not reachable by any of the nine routes tried across
   stock ZFS 2.2.2, 2.3.4, 2.4.1 and 2.4.3: a bounded negative rather than a
   proof of impossibility, and with no version covering every route. See
   `../reproducibility/FINDINGS.md` finding 12 and `../CONCLUSIONS.md` §3. The
   case rests on a separate, genuinely reproducible defect (finding 10), not on
   this incident. Finding 16 manufactured the precondition directly and found
   that it imports cleanly on stock `zfs-2.4.3`, which is why the
   `vdev_ishole` claim above is "the predicate is incomplete" rather than a
   claim about this incident.

2. Pool reports `Some supported features are not enabled`, not upgraded after
   being touched by ZFS 2.4.3. Leaving it un-upgraded is the right call for
   TrueNAS 2.3.x compatibility.

3. Root cause of the original SLOG failure was never established. SMART on
   both SSDs was clean (`No Errors Logged`, 0 reallocated, 9,573 and 55,052
   power-on hours) yet they flickered available and unavailable on the SAS
   backplane. Cabling, backplane slot, and SATA-SSD-behind-SAS-expander
   incompatibility all remain untested. If I re-add a SLOG, this needs
   answering first.

4. Operational hardening not yet done. The pool ran a SLOG with no tested loss
   procedure. `zpool remove <pool> <log>` while the devices are still healthy
   is trivial, whereas recovering after they were gone took me three days.

5. The cause of Bug #2 is unknown and was never investigated. The space-map
   corruption was never reproduced and no hypothesis for it was ever strong
   enough to script (`../CLAIMS.md` 4.7). It coincided with a scrub interrupted
   by a reboot. Bug #2's origin is as unexplained as Bug #1's; the repair is
   validated, the cause is not.

6. Why log verify did not block on the repair import is unknown. `../CLAIMS.md`
   1.13. See the note in §11.

---

## Appendix A: key stack traces

A.1: the original (Day 1) trace. Misleading, because it is a later stage of
Bug #1.

```
io_schedule -> cv_wait_common [spl]
txg_wait_synced_flags [zfs] -> txg_wait_synced [zfs]
spa_load_impl.constprop.0+0x3fe/0x5b0 [zfs]
spa_load -> spa_load_best -> spa_import -> zfs_ioc_pool_import
zfsdev_ioctl_common -> zfsdev_ioctl -> __x64_sys_ioctl -> do_syscall_64
```

This is `txg_wait_synced(..., spa->spa_claim_max_txg)` at `spa.c:6232` and
later, note `"Syncing ZIL claims"`.

A.2: the dedup and BRT trace. Not the blocker.

```
__cv_timedwait_common+0x129 -> __cv_timedwait_io+0x19 -> zio_wait+0x11a
dbuf_read+0x322 -> dmu_buf_hold_by_dnode+0x47
zap_table_load+0x74 -> zap_deref_leaf+0x81
fzap_length+0x79 -> zap_length_uint64+0xaf
ddt_zap_lookup+0x5d -> ddt_lookup+0x36f -> ddt_addref+0x4f
brt_pending_apply_vdev+0xca -> brt_pending_apply+0x4b
spa_sync+0x61 -> txg_sync_thread+0x1ec
```

The BRT was empty and dedup was not the blocker. This trace only appeared once
tunables perturbed which stage was reached.

A.3: the decisive SysRq-W trace. Bug #1, main thread:

```
taskq_wait+0x92/0xd0                    [spl]
dmu_objset_find_dp+0x16e/0x240          [zfs]
spa_check_logs+0x3a/0x60                [zfs]
spa_ld_verify_logs+0x37/0x90            [zfs]
spa_load_impl.constprop.0+0x2a5/0x5b0   [zfs]
spa_load -> spa_load_best -> spa_import -> zfs_ioc_pool_import
```

A.4: Bug #1, worker threads (`dmu_objset_find` taskq):

```
zio_wait+0x11a/0x240                    [zfs]
arc_read+0xfc7/0x1770                   [zfs]
zil_read_log_block+0xd9/0x3a0           [zfs]
zil_parse+0x23e/0x5a0                   [zfs]
zil_check_log_chain+0x112/0x1d0         [zfs]
dmu_objset_find_dp_impl -> dmu_objset_find_dp_cb -> taskq_thread
```

A.5: Bug #2, the hard assertion:

```
VERIFY3U(zfs_range_tree_space(smla->smla_rt) + sme->sme_run, <=, smla->smla_sm->sm_size)
    failed (17293090816 <= 17179869184)
PANIC at space_map.c:407:space_map_load_callback()

spl_panic -> space_map_load_callback+0x7d/0x90 -> space_map_iterate+0x237/0x3b0
-> space_map_load_length+0x76/0xf0 -> metaslab_load+0x3d6/0x880
-> find_valid_metaslab -> metaslab_activate -> metaslab_alloc_dva_range
-> metaslab_alloc_range -> zio_dva_allocate -> zio_execute -> taskq_thread
```

A.6: Bug #2, the earlier (secondary) range-tree panic:

```
PANIC: zfs: rt={spa=storage vdev_guid=5884354480802639419 ms_id=2719 ms_allocatable}:
  adding segment (offset=2a7c0182d000 size=10cb0000)
  overlapping with existing one (offset=2a7c00105000 size=123f6000)

zfs_panic_recover+0x77/0xa0 -> zfs_range_tree_add_impl+0x2a0/0x1370
-> zfs_range_tree_walk+0xdc/0x230 -> metaslab_load+0x552/0x870 -> metaslab_preload+0x5c/0x140
```

---

## Appendix B: flags and tunables tried

None of these import flags fixed either bug on their own:

```
-f            -m            -N            -F            -X            -T <txg>
-o readonly=on              -o cachefile=none           -o cachefile=<path>
-c /etc/zfs/zpool.cache     -d /dev/disk/by-id
-R /mnt       -D
```

Notable results:
- `-X` and `-n` require `-F`: `-n or -X only meaningful with -F`
- `-o readonly=on` was the only thing that ever imported before the patches
- `zpool set readonly=off` post-import returns
  `property 'readonly' can only be set at import time`
- `zpool set cachefile=...` under RO import returns `pool is read-only`
- `-c` after a RO import and export returns `no such pool available`, because
  the cachefile is written by `spa_write_cachefile()` from `spa_import()`,
  which is never reached when the load hangs

Module parameters tried:

```
zfs_multihost_fail_intervals=0     <- no effect (mmp_valid = 0 anyway)
zfs_bclone_enabled=0               <- no effect (BRT empty)
zfs_dedup_prefetch=0               <- no effect
zfs_dedup_log_cap=0                <- misread; 0 = unlimited
zfs_dedup_log_hard_cap             <- no effect
zfs_dedup_log_flush_txgs=1000000   <- no effect
zfs_dedup_log_flush_entries_max=0  <- no effect
zfs_dedup_log_flush_entries_min=0  <- no effect
zfs_max_async_dedup_frees=0        <- no effect
zfs_recover=1                      <- cannot demote VERIFY3U; useful only for zfs_panic_recover sites
zil_replay_disable=1               <- wrong lever; gates mount-time replay, not import-time verify/claim. Left at 0 for the repair so replay would run afterwards (it did)
metaslab_preload_enabled=0         <- hides preload panics only; allocator still hits it
spa_load_verify_data=0             <- used during repair
spa_load_verify_metadata=0         <- used during repair
```

`failmode`: attempted, and could not be reached. `failmode=wait|continue|panic`
was tried during the incident and would not take, by any command. Tier:
unbacked testimony, no captured artifact. The source reasoning that follows is
SOURCE (claim 3.23-3.26); the claim that the attempts were made is first-hand
report only, with no `zpool set` or `zpool import -o` output preserved in this
repository. It was not an oversight, and it was not a tunable that was skipped.
The source alone shows the setting was out of reach during the load, and does
not depend on the testimony.

Three reasons, all in `module/zfs/spa.c`. Line numbers are against `zfs-2.4.3`,
commit `83020cf`; the code is identical in `master` but the lines differ, and
[`../CLAIMS.md`](../CLAIMS.md) §7 gives both:

1. `zpool set failmode=...` needs the pool imported. It never was, writable.
2. `zpool import -o failmode=...` is applied too late. `spa_import()` calls
   `spa_load_best()` at `spa.c:7401` and only reaches
   `spa_prop_set(spa, props)` at `spa.c:7432`, after the load returns. The hang
   is inside `spa_load_best()`, in `spa_ld_verify_logs()`. The property is
   also gated on `spa_writeable(spa)`. An `-o failmode=` on the import command
   line therefore cannot affect the code path that hangs.
3. The only `failmode` in effect during the load is the one already on disk,
   read by `spa_ld_get_props()` (`spa.c:5284`) at `spa.c:5421`, called at
   `spa.c:6069`, before `spa_ld_verify_logs()` at `spa.c:6106`. For this pool
   that was TrueNAS's default, `wait`.

And ZFS's own automatic override cannot fire here either. `spa.c:5435` forces
`failmode` to `continue` when top-level vdevs are missing, precisely so that a
pool imported with missing devices cannot suspend or panic:

```c
if (spa->spa_missing_tvds > 0 &&
    spa->spa_failmode != ZIO_FAILURE_MODE_CONTINUE &&
    spa->spa_load_state != SPA_LOAD_TRYIMPORT) {
        spa_load_note(spa, "forcing failmode to 'continue' "
            "as some top level vdevs are missing");
        spa->spa_failmode = ZIO_FAILURE_MODE_CONTINUE;
}
```

The override cannot fire on this pool (`../CLAIMS.md` 3.25):

`spa_missing_tvds` is set from `vdev_root_open()`, whose counting test is, in
full (`vdev_root.c:102`, same in both trees):

```c
if (cvd->vdev_open_error && !cvd->vdev_islog &&
    cvd->vdev_ops != &vdev_indirect_ops)
```

There are two independent reasons the removed SLOG is not counted, and the
first has nothing to do with holes:

1. `!cvd->vdev_islog` excludes log vdevs outright. This guard deliberately
   ignores logs. A failed log, plain UNAVAIL with no hole anywhere, would not
   have been counted either. Whatever else is true, this override was never
   going to fire for a missing SLOG.
2. And a hole has no open error anyway. `vdev_open()` sets a hole
   `VDEV_STATE_HEALTHY` at `vdev.c:2248` and returns 0 at `vdev.c:2254-2255`,
   so `vdev_open_error` is 0 and the first clause fails as well.

`spa_missing_tvds` was 0, and the override never ran.

There is a further guard the hole defeats, in the same function as the failmode
override's consequence: `spa_ld_verify_logs()` will tolerate a failed
`spa_check_logs()` and continue with "dropping the logs" (`spa.c:5605-5609`),
but only `if (spa->spa_missing_tvds != 0)`. With a hole that counter is 0 too,
so the import would have hard-failed with `VDEV_AUX_BAD_LOG`
(`spa.c:5613-5614`) even if it had got that far. It did not; it hung first. See
[`../CLAIMS.md`](../CLAIMS.md) 3.26.

A note on how these guards differ, because it is easy to lump them together.
Bug #1's shape, a guard written for "the log device is gone" keyed on a
predicate that a `hole` does not satisfy, appears in `zil_check_log_chain()`'s
`vdev_islog` test and in the `spa_missing_tvds` test above at
`spa.c:5605-5609`. That is two instances. Two other things are often miscounted
into it, and neither belongs:

- The `vdev_root_open()` counting test is not an instance: it does not fail to
  notice a hole, it deliberately declines to count logs.
- The `vs_alloc` gate in `spa_vdev_remove_log()` is not an instance either: it
  is an allocation-accounting test with no hole predicate in it, defeated by a
  zero byte count rather than by hole-ness. It is a real defect, but a
  different one, a safety step skipped with no error returned.

See `../CLAIMS.md` 3.25.

A circular argument against `failmode=continue` ("the ZIO was not returning an
error, it was blocked on a condition variable") does not work:
`failmode=continue` is the setting intended to make a ZIO return `EIO` instead
of blocking. The source facts above replace that argument.

Whether a pool that already carries `failmode=continue` before its log starts
failing avoids the hang is answered in the test environment.
`../reproducibility/07-path-h-yank-live-log.sh` passes
`-o failmode="$FAILMODE"` to `zpool create`, so the pool carries the setting
from creation, before the log is yanked. Run at `FAILMODE=continue` on
`zfs-2.4.3` it does not hang: `remove exit=0`, hole created, every `zh_log`
cleared. At `panic` it panics with `zio_suspend+0x1b0` in the trace. So the
ZIO's disposition is `zio_suspend()`, and under the default `wait` it never
returns while `spa_reset_logs()` holds `spa_namespace_lock`. See
`../reproducibility/FINDINGS.md` finding 15 and `../CLAIMS.md` 2.6, now
ESTABLISHED for the removal case in the test environment.

That result does not transfer to this incident, and the reason is the point of
this appendix: the suspend gate at `zio.c:5714-5720` requires
`spa_load_state == SPA_LOAD_NONE`, which is false during an import. Whatever
made this pool block in `zio_wait()` during a load, it was not that suspend.
`../CLAIMS.md` 2.6 remains UNKNOWN for the incident's import path.

Two scope limits travel with the finding-15 result: at `failmode=panic` the
panic fires during the script's step-6 scrub provocation, before
`zpool remove` is issued, so it does not isolate the `zil_parse()` read; and
`continue` and `panic` have each been run once, on `zfs-2.4.3` with script `07`
only.

There is also a caution here against assuming `failmode` is the answer at all.
`../CLAIMS.md` 4.9 argues that a read whose DVA resolves to a hole should never
have blocked in the first place, and as of 2026-07-31 that is no longer only an
argument: finding 16 built the state and the import completed cleanly. Note the
mechanism (4.9): the read does not go to
`vdev_missing_io_start()`, because a read by DVA has `io_vd == NULL` and
dispatches through `vdev_mirror_ops`; `vdev_mirror_child_select()` returns -1,
no child I/O is issued, and `vdev_mirror_io_done()` sets `ENXIO`. Either way it
fails fast, and `zil_read_log_block()`'s `ZIO_FLAG_CANFAIL` disarms the
catch-all suspend. On that reading the import should have failed cleanly
regardless of `failmode`. This one hung anyway. Either something further is
involved or the blocking read was not to the hole. That is the sharpest open
question in this record.

---

*Command output, stack traces, source excerpts and diffs in this document are
transcribed from the recovery; selected excerpts are abridged for readability.*
