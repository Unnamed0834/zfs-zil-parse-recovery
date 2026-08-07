# ZFS: unkillable hang on `zpool remove` of a failing log device

`zpool remove` of a log device whose backing store is returning I/O errors
hangs unkillably in `zil_destroy_sync()` -> `zil_parse()` ->
`zil_read_log_block()` -> `arc_read()` -> `zio_wait()`. Reproduced from scratch
on stock OpenZFS across three releases (2.2.2, 2.3.4, 2.4.3), with captured
stacks on 2.2.2 and 2.4.3. The mechanism is established for the removal case:
`zio_suspend()` under the default `failmode=wait`.

This is not a new defect. The same call chain was reported in 2013 as
[openzfs/zfs#1585](https://github.com/openzfs/zfs/issues/1585), acknowledged by
a maintainer, and closed as stale in 2016 with an offer to reopen it. What is
new is a deterministic reproducer, confirmation on current releases, and the
mechanism. See "Previously reported occurrences" below.

The incident case study in `incident/` is background. The bug stands on the
reproducer alone.

---

## Reproducer

```bash
FAILMODE=wait sudo -E ./reproducibility/07-path-h-yank-live-log.sh
```

The script creates a pool with a log vdev backed by `file -> loop -> dm-linear`,
drives synchronous writes so the ZIL chain is live, unmounts the dataset so its
header cannot drain, then swaps the dm table to an `error` target so the device
fails without exporting the pool. The subsequent `zpool remove` never returns.

## What is established

| What | Status | Details |
|---|---|---|
| Removal hang | REPRODUCED | Stock ZFS 2.2.2, `zfs-2.3.4`, `zfs-2.4.3`, with captured stacks on 2.2.2 and 2.4.3 |
| Mechanism (removal case) | ESTABLISHED | `zio_suspend()` under `failmode=wait`; `continue` removes the hang, `panic` panics at `zio_suspend+0x1b0` |
| Import hang (incident) | UNKNOWN | Synthesised precondition does not hang on `zfs-2.4.3`; at least one further ingredient is unidentified |
| Pool recovery | OBSERVED | Post-repair scrub: 4 days 8 hours 42 minutes, `scan done errors=0` |

For the full claim index with evidence tiers see [`CLAIMS.md`](CLAIMS.md). For
conclusions and next steps see [`CONCLUSIONS.md`](CONCLUSIONS.md).

---

## Previously reported occurrences

The removal hang is a re-report, not a discovery. Searched 2026-08-04:

| Issue | State | Relation |
|---|---|---|
| [#1585](https://github.com/openzfs/zfs/issues/1585) "Kernel hang when removing faulted log device" (2013) | Closed stale 2016 | Same call chain. Its `zpool` stack is `zio_wait` <- `arc_read_nolock` <- `dsl_read_nolock` <- `zil_parse` <- `zil_destroy_sync` <- `zil_destroy` <- `zil_suspend` <- `zil_vdev_offline` <- `dmu_objset_find` <- `spa_offline_log` <- `spa_vdev_remove`. `spa_offline_log`/`zil_vdev_offline` were renamed to `spa_reset_logs`/`zil_reset` by `a1d477c24` (2016), so this maps 1:1 onto the stacks captured here. Same trigger (log faulted on I/O errors) and `txg_quiesce` also wedged, matching the 2.2.2 run. Closed with "If anyone still hitting this let us know and we'll reopen it" |
| [#13273](https://github.com/openzfs/zfs/issues/13273) "zpool remove of log device hangs" (2022) | Closed stale 2023 | Possible match. No stack posted, so unconfirmed |
| [#17427](https://github.com/openzfs/zfs/issues/17427) (2025), [#12980](https://github.com/openzfs/zfs/issues/12980) (2022) | Both open | Similar symptom on the import path (writable import hangs, `readonly=on` works). Not claimed as the same site: #17427 posts no stack, #12980's stack is `txg_sync` |
| [#14775](https://github.com/openzfs/zfs/issues/14775) (2023) | Open | Not related. A different deadlock, `zl_suspend_lock`, introduced by #14514 |

Over #1585 this adds a scripted reproducer, confirmation on 2.2.2, 2.3.4 and
2.4.3, and the mechanism (`zio_suspend()` under `failmode=wait`, isolated by a
`failmode=continue` control run).

---

## Source-level gaps

Found by reading OpenZFS source (all against `zfs-2.4.3`, commit `83020cf`):

- `zil_check_log_chain()` does not guard on `vdev_ishole`; it guards only on
  `vdev_islog && vdev_is_dead`, and a hole has `vdev_islog = 0`
  (`module/zfs/zil.c:1297`). Patch A (corrected form) addresses this.
- There is a latent NULL dereference because `vdev_lookup_top()` can return
  NULL for an out-of-range vdev index and `zil_check_log_chain()` dereferences
  it without any check (`module/zfs/zil.c:1296-1297`). Patch A addresses this
  as well.
- `spa_vdev_remove_log()` skips `spa_reset_logs()` entirely when `vs_alloc
  == 0`, with no error returned (`module/zfs/vdev_removal.c:2144`). Patch E
  addresses this, though it is coupled to the hang.
- A dangling ZIL DVA survives a mount because the `keep_first` path in
  `zil_sync()` preserves the DVA under a fresh GUID
  (`module/zfs/zil.c:4182-4192`).

A full index of every source citation in both `zfs-2.4.3` and `master` is given
in [`CLAIMS.md` section 7](CLAIMS.md).

## Patches

| Patch | What | Status | Where |
|---|---|---|---|
| A (corrected form) | `vdev_ishole` guard + NULL check in `zil_check_log_chain()` | Written, never built, never run | [`incident/patches/README.md`](incident/patches/README.md) |
| B | Clear ZIL header when DVA resolves to hole vdev | This is the patch that repaired the pool | [`incident/patches/README.md`](incident/patches/README.md) |
| C (incident form) | Space-map assertion replaced with warn-and-skip | Applied on hardware; must never be reused | [`incident/patches/README.md`](incident/patches/README.md) |
| C (recommended form) | `zfs_panic_recover()` version of the above | Does not exist as code yet | [`incident/patches/README.md`](incident/patches/README.md) |
| D | Force metaslab condense to rewrite corrupt space map | Applied on hardware | [`incident/patches/README.md`](incident/patches/README.md) |
| E | Remove the `vs_alloc == 0` gate on `spa_reset_logs()` | Diff exists, never built, never run; coupled to the hang | [`reproducibility/patches/README.md`](reproducibility/patches/README.md) |
| F | Propagate `zil_destroy_sync()` discarded error | Fragments, does not compile; does not fix the hang | [`reproducibility/patches/README.md`](reproducibility/patches/README.md) |

---

## Case study, 140 TB pool recovery

A 12-disk, 2x raidz2 pool of 186 TB raw and 140 TB allocated imported
read-only, but hung unkillably on any writable import after its mirrored
SLOG failed and was removed. Two on-disk defects were repaired on the affected
hardware, and the repaired pool then passed a full scrub of 4 days 8 hours 42
minutes reporting `scan done errors=0`. This happened once, on one machine,
and the hardware has since been returned to service, so nothing on this side
can be re-run.

- Full writeup:
  [`incident/recovery-breakdown.md`](incident/recovery-breakdown.md)
- Evidence:
  [`incident/evidence/2026-07-30-post-repair-history.txt`](incident/evidence/2026-07-30-post-repair-history.txt)

The removal-side hang covered by the reproducer above has an established
cause. The import-side hang remains unexplained. They share a blocking site
but not a mechanism.

---

## Repository structure

| Path | What it is |
|---|---|
| [`CLAIMS.md`](CLAIMS.md) | Every substantive claim, with evidence tier. The index of record |
| [`CONCLUSIONS.md`](CONCLUSIONS.md) | What was fixed, scope, authorship, anomaly boundary |
| [`incident/`](incident/) | Case study, recovery, patches A-D applied to hardware |
| [`incident/patches/`](incident/patches/) | Patches A-D as documented diffs (A corrected form, B, C incident form, D) |
| [`reproducibility/`](reproducibility/) | Runnable scripts, evidence captures, attempt log |
| [`reproducibility/evidence/`](reproducibility/evidence/) | Verbatim captures from reproduction runs |
| [`reproducibility/patches/`](reproducibility/patches/) | Patches E and F as documented diffs |

---

## Credits

The hang was first reported as
[#1585](https://github.com/openzfs/zfs/issues/1585) (2013) by `niekbergboer`,
diagnosed in-thread by `behlendorf`, and reconfirmed by `FransUrbo` and
`sempervictus` in 2014. amotin's "Fix log vdev removal issues" (#18277;
`1e1d64d` / `50697dc93`) is the log-removal hardening Patch A extends and whose
`SPA_LOG_CLEAR` sequence Patch B reuses. The `vs_alloc != 0` gate is inherited
illumos code from `428870ff734` (2010); `6c926f426a26` (Dimitropoulos, 2019)
unwrapped it and added the `ASSERT0` that amotin later removed. The renames
that make #1585's stack legible (`spa_offline_log` -> `spa_reset_logs`,
`zil_vdev_offline` -> `zil_reset`) are Matthew Ahrens' `a1d477c24` (2016).
Import-path symptom reports: [#17427](https://github.com/openzfs/zfs/issues/17427),
[#12980](https://github.com/openzfs/zfs/issues/12980). Claim-level attribution
is in [`CLAIMS.md`](CLAIMS.md) 3.33.

---

## Licensing

Dual license:

- Patch material is CDDL-1.0, matching OpenZFS so it can be submitted upstream
  without a licensing obstacle. See [`LICENSE-patches`](LICENSE-patches).
- Documentation, analysis and test scripts are CC BY 4.0. See
  [`LICENSE-docs`](LICENSE-docs). Reuse welcome with attribution.

See [`LICENSE`](LICENSE) for the summary.

---

## Note on method

Debugging was AI-assisted. All source-level analysis was verified against the
OpenZFS tree. Patches B, C (incident form) and D were written, built, applied
and validated on the affected hardware. Patch A was built and applied but the
form that ran is inert on the hole path ([`CLAIMS.md` 1.12](CLAIMS.md)); its
corrected form has never been built or run. Patches E and F are specifications,
never built or run. The engineering decisions, including rejecting four
incorrect root causes and choosing on-disk repair over bypass, were mine.
