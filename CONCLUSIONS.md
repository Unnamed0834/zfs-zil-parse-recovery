# Conclusions

The removal-side hang has an established cause. The import-side hang remains
unexplained. They share a blocking site (`zil_parse()` -> `arc_read()` ->
`zio_wait()`) but not a mechanism. Evidence tiers are in
[`CLAIMS.md`](CLAIMS.md).

---

## 1. The reproducible bug: an unkillable hang reached through `zil_parse()`

### The bug

`zpool remove` of a log device whose backing store is returning I/O errors
hangs unkillably in `zil_destroy_sync()` -> `zil_parse()` ->
`zil_read_log_block()` -> `arc_read()` -> `zio_wait()`, and two callers reach
the same blocking site:

| Caller | Trigger | Evidence |
|---|---|---|
| `zil_destroy_sync()` during log removal | log device failing under a live pool | Reproduced on stock ZFS 2.2.2, `reproducibility/evidence/2026-07-29-zil_parse-removal-hang-2.2.2.txt` |
| `zil_check_log_chain()` at import | header DVA resolves to a hole vdev | Observed on the affected pool; mechanism UNKNOWN |

The second row is not explained. Finding 16 synthesised a hole vdev plus a
dangling non-zero `zh_log` DVA resolving to it and imported it writable on
stock `zfs-2.4.3`: it did not hang. Finding 17 tested the claimed-chain
variant and it failed fast with `EIO` instead. Both are REPRODUCED negatives
(`CLAIMS.md` 2.7 to 2.9). That state is not sufficient for the incident's hang;
at least one ingredient is unidentified (`CLAIMS.md` 1.13, 4.2 UNKNOWN). The
two rows share a blocking site (`CLAIMS.md` 2.4, SOURCE) and are not known to
share a cause.

`zil_parse()` is not missing an error path. It returns `int` and handles a
failed `zil_read_log_block()` by warning and breaking the loop. The hang is
that this path is never reached because the ZIO does not complete, so
`zio_wait()` never returns.

The hang is REPRODUCED (`CLAIMS.md` 2.1) on stock ZFS 2.2.2, on a source build
of the `zfs-2.3.4` tag, and on a source build of the `zfs-2.4.3` tag (findings
10, 13, 14), with verified stacks on 2.2.2 and 2.4.3. The 2.3.4 run was a
120-second timeout with no stack capture.

`txg_quiesce` was wedged alongside the removal on 2.2.2 but not on 2.4.3
(`CLAIMS.md` 2.2, finding 14). The machine still needs a power cycle and every
`zpool` command still blocks; the whole-pool stall is version-specific.

This defect is not new. `openzfs/zfs#1585`, filed 2013-07-11, posts the same
call chain under the pre-2016 names `spa_offline_log()` and `zil_vdev_offline()`
(renamed by `a1d477c24`), from the same trigger, with `txg_quiesce` wedged
exactly as seen here on 2.2.2. A maintainer acknowledged it the day it was
filed: "this read basically hangs while holding an important lock which causes
everything to block." It was reconfirmed by two further reporters in 2014, and
closed as stale in 2016 with "If anyone still hitting this let us know and
we'll reopen it." See `CLAIMS.md` 3.33 and finding 18.

What is new (`CLAIMS.md` 3.33) is a deterministic reproducer, confirmation on
2.2.2, 2.3.4 and 2.4.3, and the mechanism below. #1585's thread ends at a
description of the symptom.

### The mechanism: established for the removal case in the test environment

The ZIO's disposition is `zio_suspend()`, established by varying `failmode` on
`zfs-2.4.3` with `07-path-h-yank-live-log.sh`, one variable at a time
(`CLAIMS.md` 2.6, finding 15):

| `failmode` | Result |
|---|---|
| `wait` (default) | Hangs unkillably in `zil_parse` -> `arc_read` -> `zio_wait`; `zpool list` exits 124; forced power cycle |
| `continue` | No hang. `remove exit=0`, hole created, every `zh_log` cleared |
| `panic` | Kernel panic, `zio_suspend+0x1b0` in the captured trace |

The source gate is `zio.c:5714-5720`, which requires `ENXIO` and
`spa_load_state == SPA_LOAD_NONE` and `failmode != continue`, and all three of
those hold for a live-pool removal.

Two limits. The `failmode=panic` run dies during the step-6 `zpool scrub`
provocation, before `zpool remove` is issued (finding 15, caveat 1), so it
shows the disposition of uncorrectable I/O and does not isolate the
`zil_parse()` read. And none of this speaks to the incident.

### The incident's import caller: UNKNOWN

The suspend above cannot fire during a load, because it requires
`spa_load_state == SPA_LOAD_NONE`. Finding 16 removed the assumption underneath
the question: synthesising the precondition (a hole vdev plus a `zh_log` DVA
verified as resolving to it) and importing it writable on stock `zfs-2.4.3`
does not hang: exit 0, pool ONLINE, twice from pristine state (`CLAIMS.md`
2.7). The claimed-chain variant also does not hang (finding 17, `CLAIMS.md`
2.8, 3.31), so no candidate is now favoured over any other.

On the incident hardware `failmode` could not be reached during the load
(`CLAIMS.md` 3.23-3.24), and ZFS's automatic override is disabled by the hole
(3.25).

### Report the hang

File an issue: reproducer, stack, and `failmode` matrix. Not a patch yet. The
removal caller's mechanism is understood (finding 15); the import caller's is
not. Any fix has to cover both.

### Patch A

SOURCE (claims 3.1, 3.5, 3.6), not OBSERVED. The applied form was inert on the
hole path (claim 1.12). The gaps are real; there is no demonstration that
fixing them resolves the hang.

Submit the corrected form only (`incident/patches/README.md` Patch A), as
source analysis plus an untested patch.

1. The `vdev_ishole` case is missed. amotin's `1e1d64d` tests `BP_IS_HOLE`
   (an all-zero DVA) rather than `vdev_ishole`, so a valid-looking DVA pointing
   at a hole is not covered.
2. The NULL dereference is latent. `zil.c:1297` dereferences `vd` with no NULL
   check, despite `vdev_lookup_top()` returning NULL for an out-of-range vdev
   index.

Extending the predicate is not enough: `vdev_log_state_valid()` returns
`B_TRUE` for a hole, so routing the hole case into it leaves `valid` true and
changes nothing. The fix must set `valid = B_FALSE` directly.

### The `vs_alloc == 0` gate

The gate is SOURCE + REPRODUCED (3.8, finding 9). That it stranded this pool's
header is INFERRED (4.1).

Issue only. No patch.

`spa_vdev_remove_log()` gates the ZIL reset on
`if (vd->vdev_stat.vs_alloc != 0)`. When a log reports 0 the reset is skipped
and no error is returned. Every attempt to produce a stranded header through
this gate failed: every route to `vs_alloc == 0` also clears the headers.

### Patch E: make log-vdev removal atomic

SOURCE + REPRODUCED for the gate (finding 9). INFERRED for causation (4.1).
Written as a diff; never built, never run.

Issue first. Patch only if the gap is acknowledged: removing the gate changes
removal behaviour for every pool.

Caveat: removing the gate means a removal with a failing log now reaches
`spa_reset_logs()` where it previously did not. That is exactly the path that
hangs (findings 10, 14, 15). E and the hang report are coupled.

### Patch F: propagate the error `zil_destroy_sync()` currently discards

SOURCE (3.21). The discarded return is real. F does not fix the reproduced hang
(2.1): it never touches `zil_parse()` or the blocking `zio_wait()`, and an
error that is never produced cannot be propagated.

Issue first. Error-handling hygiene; useful only once the ZIO actually returns.

### Import-side detail that belongs in the issue

On the affected hardware `failmode` could not be reached during the load
(`CLAIMS.md` 3.23-3.24). Three source reasons, all in `module/zfs/spa.c` at
`zfs-2.4.3` (`CLAIMS.md` §7 has the `master` lines): `zpool set` needs an
imported pool; `zpool import -o failmode=` is applied by `spa_prop_set()` at
`spa.c:7432`, after `spa_load_best()` returns at `spa.c:7401`, and the hang is
inside that call; the value in effect during the load is whatever is already on
disk (`spa.c:5421`, read at `spa.c:6069`, before verify at `spa.c:6106`). The
report that `failmode` would not take on the hardware is first-hand testimony
with no captured artifact; the source reading does not depend on it.

A fourth guard also fails to help. `spa.c:5435` forces `failmode` to `continue`
when `spa_missing_tvds > 0`. It does not fire here: `vdev_root_open()` counts
with `if (cvd->vdev_open_error && !cvd->vdev_islog && cvd->vdev_ops !=
&vdev_indirect_ops)` (`vdev_root.c:102`), so log vdevs are excluded outright,
and a hole opens successfully with no open error (`vdev.c:2248-2255`). That is
a guard that deliberately ignores logs, not another hole-predicate miss. See
`CLAIMS.md` 3.25.

A read by DVA has `io_vd == NULL` and dispatches to `vdev_mirror_ops`, not to
`vdev_hole_ops` / `vdev_missing_io_start()`. `vdev_mirror_child_select()`
returns -1 (`vdev_mirror.c:546-551`), no child I/O is issued (`:659-660`), and
`vdev_mirror_io_done()` sets ENXIO (`:761-762`). Confirmed twice:
`vdev_mirror_io_start` in the `failmode=panic` trace, and
`zdb -R <pool> 2:20000:1000` against a hole asserting inside
`vdev_mirror_io_start()` at `vdev_mirror.c:616`. Finding 16 confirms the read
fails fast on the synthesised pool, so the open question is what the incident
pool had that the synthesis did not (`CLAIMS.md` 4.9).

`zio_suspend()` panics under `failmode=panic` (`zio.c:2668`). Had that setting
been reachable on the incident hardware the outcome would likely have been a
crash dump rather than an unkillable D-state, which is better diagnostically,
noting that the panic in the test environment fired on a scrub, not on the
`zil_parse()` read.

No next experiment is nominated. The `failmode` question (finding 15) and the
claimed-chain variant (finding 17) both closed negatively. Untested candidate
differences, none favoured: the incident's build (`zfs-2.3.3-107-gec5aa9bfd`);
140 T across many datasets; encrypted datasets; TrueNAS middleware and
concurrent dataset operations; a genuinely failing device instead of a clean
hole; the space-map corruption (1.5) on the same pool.

### Patches B, C and D

B, C (incident form), and D are OBSERVED on the affected hardware. None has a
reproducible test case. B and D change behaviour. The unconditional form of C
must never be reused. The recommended `zfs_panic_recover()` form has not been
written and has never been run.

These are repair capabilities one pool needed. Whether OpenZFS wants them, and
in what shape, is a design question.

D is close to what #13995 and #3111 have asked for since 2015. Neither B nor D
has a reproducible test case; that is the main gap before either could be
seriously proposed.

B is the patch that repaired the pool (claim 1.12). It is low-risk because the
`memset` + `dsl_dataset_dirty()` sequence is the existing `SPA_LOG_CLEAR` path
a few lines below in the same function (`zil.c:1217-1220` at `zfs-2.4.3`; claim
3.22). amotin's `1e1d64d` widened the zeroing from `BP_ZERO(&zh->zh_log)` to a
full-header `memset`; the `os_encrypted` / `os_next_write_raw` and
`dsl_dataset_dirty()` lines predate that commit. B adds one condition
(`vdev_ishole`), reaches an existing in-tree sequence, and omits `zio_free`
because the blocks sit on a vdev that no longer exists.

## 2. The incident: what was recovered, what was fixed, and what remains unknown

Cannot be re-run. Two independent on-disk defects on one pool: `storage`, 12
disks, 2x raidz2, 186 T raw and 140 T allocated.

### Defect 1: a ZIL header referencing a hole vdev

The symptom was that read-only import succeeded. Every writable import hung
forever in uninterruptible sleep, unkillable, and requiring a hard reboot. The
hang and its SysRq-W stack are OBSERVED (1.2). Hole plus dangling DVA is not
sufficient to explain it: the same precondition imports cleanly on stock
`zfs-2.4.3` unclaimed (finding 16, claim 2.7), and the claimed-chain variant
fails fast with `I/O error` at `spa_load_verify()` rather than hanging (finding
17, claims 2.8, 2.9, 3.31). At least one further ingredient is unidentified.

What was on disk: the removed SLOG was retained in the vdev tree as a hole
(`guid: 0`, `is_hole: 1`), and at least one dataset's ZIL header still held a
non-zero DVA resolving to that hole. `zil_check_log_chain()` guards only on
`vd->vdev_islog && vdev_is_dead(vd)`, and a hole has `vdev_islog = 0`, so the
guard never fired. On the incident pool the non-zero DVA led into
`zil_parse()` and a read that never completed in `zio_wait()`. Why that ZIO
never completes is not established here; see §1. Read-only import worked
because verify and claim run only when `spa_writeable(spa)`.

`zil_parse()` is not missing an error path; it returns `int` and handles a
failed `zil_read_log_block()` by warning and breaking the loop. The hang is
that the ZIO never completes so that handling is never reached.

The fix applied on the hardware was two source patches to `module/zfs/zil.c`:

- Patch A, `zil_check_log_chain()`: extend the guard with `|| vd->vdev_ishole`.
- Patch B, `zil_claim()`: when the header's DVA resolves to a hole, `memset`
  the header, `dsl_dataset_dirty()` the dataset, and return. `zio_free`
  deliberately omitted because the blocks live on a vdev that no longer exists.

Only B did anything. A ran as
`if ((vd->vdev_islog && vdev_is_dead(vd)) || vd->vdev_ishole) valid =
vdev_log_state_valid(vd);`, and `vdev_log_state_valid()` returns `B_TRUE` for
a hole, so `valid` stayed true and the skip never happened (`CLAIMS.md` 1.12).
The corrected form of A is in `incident/patches/README.md`; it was never built
or run. Open question 1.13: verify runs before claim (`spa.c:6106` before
`spa.c:6175`), so if A was inert, something else let `spa_ld_verify_logs()`
through on the repair import.

The `memset` plus `dsl_dataset_dirty()` is the part that matters. It commits
the repair to disk instead of merely stepping over it, which is why the pool
no longer needs a patched module.

### Defect 2: space-map corruption

The symptom was that once defect 1 was fixed and the allocator ran for the
first time, the pool panicked:

```
VERIFY3U(zfs_range_tree_space(smla->smla_rt) + sme->sme_run, <=, smla->smla_sm->sm_size)
    failed (17293090816 <= 17179869184)
PANIC at space_map.c:407:space_map_load_callback()
```

This was a `VERIFY`, not `zfs_panic_recover()`, so `zfs_recover=1` could not
demote it. Nine entries were rejected by the `SM_FREE` recovery load across two
metaslabs: `ms_id 2` on vdev 0 and `ms_id 2719` on vdev 1. The incident
evidence supports inconsistent or redundant FREE records and observed overlap
or double-counting, and it does not decode every record well enough to prove
that all nine were exact duplicates.

The fix was applied and validated, and consisted of two patches:

- `space_map.c`: replace the assertion with a counted skip in the `SM_FREE`
  loading path, so the recovery can construct a usable in-memory allocatable
  tree for this pool. The skip is an incident-specific recovery change, not a
  general unconditional safety rule.
- `metaslab.c`: when the loader reports skipped records, set
  `ms_condense_wanted` and `vdev_dirty()`, forcing `metaslab_condense()` to
  discard the on-disk space map and re-emit it from the resulting allocatable
  tree.

The two metaslabs with detected corrupt entries were rewritten in one txg:

```
metaslab.c:3945:metaslab_condense(): condensing: txg 16404697, msp[2]    vdev id 0, forcing condense=TRUE
metaslab.c:3945:metaslab_condense(): condensing: txg 16404697, msp[2719] vdev id 1, forcing condense=TRUE
```

### Verification: the strongest single result here

The post-repair scrub is the strongest single result on the incident side
(`CLAIMS.md` 1.8, 1.9 and the note beneath them), and the only claim there
backed by an artifact a reader can open.

The pool exported cleanly, then imported repeatedly with plain `zpool import -f
storage` on unmodified stock TrueNAS ZFS, including in a later fresh-install
environment, and a post-repair scrub subsequently ran 4 days 8 hours 42 minutes
and completed with `scan done errors=0`. The artifact records the start and end
but does not preserve the scanned-byte total, so the 140 T figure comes from the
final pool status. See `incident/evidence/2026-07-30-post-repair-history.txt`.

This matters because a forced metaslab condense rewrites allocation metadata
and a zeroed ZIL header discards a dataset's intent log, and a clean scrub over
the whole pool afterwards is what supports the statement that neither repair
lost data.

Two bounds apply and both are real. First, on coverage, this is repeated stock
imports on two TrueNAS installs plus one full scrub between 2026-07-22 and
2026-07-27, so it says nothing about untested ZFS releases. Second, and more
important, a scrub does not audit space-map correctness. It traverses the
block tree and verifies checksums of reachable blocks. A re-emitted space map
that over-reports free space would pass a scrub and would only appear later as
allocation into occupied space. As a result the clean scrub is strong evidence
for Patch B, which zeroed a ZIL header, and only partial evidence for Patch D,
which rewrote allocation metadata. What supports D beyond the scrub is the pool
returning to normal read-write service with no allocation fault reported.

Both repairs are on disk and portable, and no patched module is required.

### Approaches rejected during recovery

Three bypasses worked and were each refused as insufficient because none of
them changed the bytes on disk: a binary NOP of both `call` sites in `zfs.ko`,
`metaslab_preload_enabled=0`, and an unconditional space-map skip. Choosing
repair over bypass is what made the outcome portable.

## 3. How they relate: the gap between the synthesis and the incident

The two results above share a blocking site and not a mechanism. Keep that
boundary explicit.

### Two different questions, two different answers

"Root cause" is ambiguous here, so it should be split:

| Question | Answer | Status |
|---|---|---|
| Why was the pool unrecoverable, hanging unkillably with no diagnostic? | A read issued from `zil_parse()` never completes, so the thread waits forever in `zio_wait()` | Blocking site confirmed from source and reproduced through a second caller (findings 10, 14). For the removal caller the mechanism is now ESTABLISHED: `zio_suspend()` under `failmode=wait` (2.6, finding 15). For the import caller it is UNKNOWN and harder than before: the synthesised precondition does not hang on 2.4.3 (2.7, finding 16) |
| How could the pool come to be in that state at all? | `spa_vdev_remove_log()` skips `spa_reset_logs()` entirely when the log reports `vs_alloc == 0`, returning no error | Gate confirmed; that it stranded this pool's header is inferred, not shown |

| Question | Answer | Status |
|---|---|---|
| Why does the ZIO never complete, so that the existing error path is never reached? | Removal caller: established (`zio_suspend()` under `failmode=wait`, 2.6, finding 15). Import caller: not established, and reframed | SPLIT, 2026-07-31. Removal case in the test environment: settled by varying `failmode` (finding 15): `continue` removes the hang, `panic` panics at `zio_suspend+0x1b0`, default `wait` blocks forever while `spa_reset_logs()` holds `spa_namespace_lock`; source gate `zio.c:5714-5720`. Incident import case: `failmode` could not be reached during the load on the affected hardware (three source reasons, `CLAIMS.md` 3.23 and 3.24), and ZFS's automatic override is disabled by the hole (3.25); the suspend in the test environment cannot fire during a load, and the synthesised precondition does not hang on 2.4.3 (2.7, finding 16). The import side is the remaining blocker on proposing a fix |

Report the second of those as a gap, not as the demonstrated cause of anything.
The recovery still stands: the pool was in that state, the state was captured,
the repair worked, and the post-repair scrub completed with
`scan done errors=0` after 4 days 8 hours 42 minutes. The bug report still
stands on finding 10 and on source-level gaps anyone can read. The incident is
a case study, not a reproducer.

### Unreproducible items, specific to the hardware incident

How the affected pool came to hold a hole vdev together with a surviving
non-zero `zh_log` was not reproduced by any route tried, and it is treated here
as an artifact of that specific hardware failure. That is a bounded negative
over the routes enumerated below, not a demonstration that no route exists.
The state itself was later manufactured directly with a test-only debug hook
(finding 16), which is a statement about the state, not about how the pool
reached it.

Ten hypotheses were enumerated, seven of which were validly executed across four
ZFS versions (2.2.2, 2.3.4, 2.4.1 and 2.4.3); hypothesis A was superseded before
it ran, because `05` exercises the same code path. Every route that was executed
either clears the ZIL headers, refuses the operation, or hangs. The full
enumeration is in
[`reproducibility/FINDINGS.md`](reproducibility/FINDINGS.md) findings 12 and 13
and [`reproducibility/ATTEMPTS.md`](reproducibility/ATTEMPTS.md).

Plausible causes, none of them demonstrated and none to be asserted:

- A partially completed `spa_reset_logs()` against SLOG SSDs that were
  flickering between available and unavailable. On 2.2.2 a reset was observed
  clearing one dataset before aborting, so partial completion is possible in
  principle.
- An operation interrupted by a crash or forced reboot. There were many during
  the incident.
- The malformed `py-libzfs: zpool remove storageNone` call recorded in that
  pool's own history at `2026-07-19.22:57:28`, the same second as a concurrent
  `zfs set mountpoint=legacy` on a sibling dataset. Never tested.

Also unreproducible:

- The space-map corruption itself (defect 2), which was never reproduced. It
  coincided with a scrub interrupted by a reboot, and while the repair is
  validated the cause remains unknown.
- The original SLOG hardware failure. SMART was clean on both SSDs, reporting
  `No Errors Logged` and 0 reallocated sectors, yet they flickered on the SAS
  backplane. Cabling, backplane slot and SATA-SSD-behind-SAS-expander
  interaction are all untested, and this needs answering before any SLOG is
  re-added to that machine.

### How closely the test environment matched the incident environment

Plainly, it did not fully match. The test environment ran Ubuntu/Debian on
aarch64 with stock distro OpenZFS 2.2.2 and 2.4.1, plus the `zfs-2.3.4` and
`zfs-2.4.3` release tags built from source on Debian 13, driving `zpool`
directly against file and device-mapper vdevs. The incident by contrast ran
TrueNAS SCALE 25.10.4, the current stable TrueNAS release at the time (Goldeye,
with 25.10.5 succeeding it four days after the incident), with TrueNAS's own
OpenZFS build on kernel `6.12.91-production+truenas`, x86-64, removal driven by
`middlewared` through py-libzfs, against two SATA SSDs flickering behind a SAS
expander.

The test environment's `zfs-2.3.4` source build is not the incident's ZFS
tree. TrueNAS describes the release as `2.3.4-1`, but the module on the
affected system identified itself as `zfs-2.3.3-107-gec5aa9bfd`, a snapshot
107 commits past the `zfs-2.3.3` tag. See
`incident/evidence/2026-07-30-post-repair-history.txt` and
`incident/recovery-breakdown.md` §14. What the 2.3.4 testing shows is that
behaviour is stable across three releases spanning the incident's version
range; it does not show behaviour on the incident's build.

The specific gaps, in descending order of concern:

1. There is no middleware. The anomalous `py-libzfs: zpool remove storageNone`
   call in the pool's history cannot be expressed without TrueNAS middleware,
   so the middleware-provenance hypothesis was never testable in the test
   environment. TrueNAS was also actively patching log-vdev removal in this
   release cycle (25.10.3, NAS-140080), which makes the middleware layer a live
   variable, not a detail.
2. TrueNAS ships its own OpenZFS build, so stock OpenZFS behaviour on
   Ubuntu/Debian is evidence about stock OpenZFS, not about TrueNAS's build.
   The `zfs-2.3.4` tag was built from source on Debian 13, which narrows the
   version gap but is neither the TrueNAS build nor even the same commit (see
   the version note two paragraphs above). The related `1e1d64d` gap, where none of
   the three original test trees carried it while the incident repair tree
   `zfs-2.4.3` does, was closed on 2026-07-31 by adding a fourth VM at that
   exact commit (`CLAIMS.md` 3.29, finding 14). The TrueNAS-build gap remains.
3. The space-map corruption has no synthetic representation at all, because no
   cause was ever hypothesised strongly enough to script, so defect 2 is a
   repair result only, with its origin unknown.
4. Architecture (aarch64 vs x86-64) and vdev backing (dm-error injection vs
   flickering SATA-behind-SAS) differ, accepted deliberately: the defects are
   control flow, and "I/O fails" was the failure mode that
   mattered.

Why the closure still stands, and where the argument stops. The anomaly
classification does not rest on the enumerated negatives alone. It also rests
on two guards found in source, namely `spa_reset_logs()` and the
encrypted-dataset replay refusal, whose effect is to prevent this state, and
additionally on finding 10, where the nearest route tried ends in a hang
rather than in the state. Those effects are version-independent source facts.
Two limits, stated so they are not glossed over: calling those guards
"purpose-built" for this state is inference about intent, not something
traced to a commit message, and "nearest route" means nearest among the nine
that were tried, a statement about the search, not about the space. A future
success on a TrueNAS-faithful rig would change how the precondition is
explained, not the finding that none of the routes tried on stock ZFS produces
it.
