# ZFS: unkillable hang on `zpool remove` of a failing log device

`zpool remove` of a log device returning I/O errors hangs unkillably in
`zil_destroy_sync()` -> `zil_parse()` -> `arc_read()` -> `zio_wait()`. Reproduced
on stock OpenZFS 2.2.2, 2.3.4 and 2.4.3; the mechanism is established for the
removal case as `zio_suspend()` under the default `failmode=wait`. The incident
case study in `incident/` is background; the bug stands on the reproducer alone.

## Layout

| Path | Contents |
|------|----------|
| [`CLAIMS.md`](CLAIMS.md) | claims with evidence tiers; index of record |
| [`CONCLUSIONS.md`](CONCLUSIONS.md) | current position and next steps |
| [`incident/`](incident/) | case study and recovery of one 140 TB pool |
| [`incident/patches/`](incident/patches/README.md) | patches A-D as documented diffs |
| [`reproducibility/`](reproducibility/) | scripts, evidence captures, attempt log |
| [`reproducibility/evidence/`](reproducibility/evidence/) | verbatim captures from reproduction runs |
| [`reproducibility/patches/`](reproducibility/patches/README.md) | patches E and F as documented diffs |

## Reproducer

```sh
FAILMODE=wait sudo -E ./reproducibility/07-path-h-yank-live-log.sh
```

The script backs a log vdev with `file -> loop -> dm-linear`, drives synchronous
writes so the ZIL chain is live, unmounts the dataset so its header cannot drain,
then swaps the dm table to an `error` target. The subsequent `zpool remove`
never returns. At `FAILMODE=continue` it completes; at `FAILMODE=panic` it
panics at `zio_suspend+0x1b0`.

## Commands

```sh
./reproducibility/01-verify-environment.sh
FAILMODE=continue sudo -E ./reproducibility/07-path-h-yank-live-log.sh
./reproducibility/inspect.sh
```

## What is established

| Claim | Status | Detail |
|---|---|---|
| Removal hang | REPRODUCED | Stock 2.2.2, 2.3.4, 2.4.3; captured stacks on 2.2.2 and 2.4.3 |
| Mechanism, removal case | ESTABLISHED | `zio_suspend()` under `failmode=wait`; `continue` removes the hang |
| Import hang, incident | UNKNOWN | Synthesised precondition does not hang on `zfs-2.4.3` |
| Pool recovery | OBSERVED | Post-repair scrub, 4 days 8 hours 42 minutes, `scan done errors=0` |

Full claim index: [`CLAIMS.md`](CLAIMS.md). Conclusions:
[`CONCLUSIONS.md`](CONCLUSIONS.md).

## Source-level gaps

Against `zfs-2.4.3`, commit `83020cf`:

- `zil_check_log_chain()` misses `vdev_ishole` (`module/zfs/zil.c:1297`); patch A.
- Latent NULL dereference on an out-of-range vdev index
  (`module/zfs/zil.c:1296-1297`); patch A.
- `spa_vdev_remove_log()` skips `spa_reset_logs()` when `vs_alloc == 0`
  (`module/zfs/vdev_removal.c:2144`); patch E.
- `zil_sync()` preserves a dangling DVA under a fresh GUID via `keep_first`
  (`module/zfs/zil.c:4182-4192`).

Citation index for both `zfs-2.4.3` and `master`: [`CLAIMS.md` §7](CLAIMS.md).

## Patches

| Patch | Change | Status |
|---|---|---|
| A (corrected) | `vdev_ishole` guard + NULL check | Written, never built or run |
| B | Clear ZIL header when DVA resolves to a hole | Repaired the pool |
| C (incident form) | Space-map assertion replaced with warn-and-skip | Applied; must never be reused |
| C (recommended) | `zfs_panic_recover()` form | Not written as code |
| D | Force metaslab condense to rewrite corrupt space map | Applied on hardware |
| E | Remove the `vs_alloc == 0` gate | Diff exists, never built or run |
| F | Propagate `zil_destroy_sync()`'s discarded error | Fragments, do not compile |

Diffs: [`incident/patches/README.md`](incident/patches/README.md),
[`reproducibility/patches/README.md`](reproducibility/patches/README.md).

## Prior reports

The removal hang is a re-report. Tracker search 2026-08-04:

| Issue | State | Relation |
|---|---|---|
| [#1585](https://github.com/openzfs/zfs/issues/1585) (2013) | Closed stale 2016 | Same call chain and trigger; renames by `a1d477c24` map its stack 1:1 onto those captured here. `txg_quiesce` wedged in both |
| [#13273](https://github.com/openzfs/zfs/issues/13273) (2022) | Closed stale 2023 | Possible match; no stack posted |
| [#17427](https://github.com/openzfs/zfs/issues/17427), [#12980](https://github.com/openzfs/zfs/issues/12980) | Open | Similar import-path symptom; different sites |
| [#14775](https://github.com/openzfs/zfs/issues/14775) (2023) | Open | Unrelated `zl_suspend_lock` deadlock |

Over #1585 this adds a scripted reproducer, confirmation on three releases, and
the mechanism from a `failmode=continue` control run.

## Case study

A 12-disk, 2x raidz2 pool of 186 TB raw and 140 TB allocated imported read-only
but hung on any writable import after its mirrored SLOG failed and was removed.
Two on-disk defects were repaired on the hardware; the repaired pool passed a
full scrub reporting `scan done errors=0`. It happened once, on one machine, and
the hardware is back in service, so nothing there can be re-run.

[`incident/recovery-breakdown.md`](incident/recovery-breakdown.md) ·
[`incident/evidence/2026-07-30-post-repair-history.txt`](incident/evidence/2026-07-30-post-repair-history.txt)

## Credits

First reported by `niekbergboer` in
[#1585](https://github.com/openzfs/zfs/issues/1585) (2013), diagnosed by
`behlendorf`, reconfirmed by `FransUrbo` and `sempervictus` (2014). amotin's
`1e1d64d` is the log-removal hardening patch A extends and the `SPA_LOG_CLEAR`
sequence B reuses. The `vs_alloc != 0` gate comes from illumos `428870ff734`
(2010); `6c926f426a26` (2019) unwrapped it and added the `ASSERT0` amotin later
removed. The renames making #1585's stack legible are Matthew Ahrens'
`a1d477c24` (2016). Import-path reports:
[#17427](https://github.com/openzfs/zfs/issues/17427),
[#12980](https://github.com/openzfs/zfs/issues/12980). Claim-level attribution:
[`CLAIMS.md` 3.33](CLAIMS.md).

## Licensing

Patches are CDDL-1.0 ([`LICENSE-patches`](LICENSE-patches)); documentation,
analysis and test scripts are CC BY 4.0 ([`LICENSE-docs`](LICENSE-docs)). Reuse
with attribution. [`LICENSE`](LICENSE) has the summary.

## Note on method

Debugging was AI-assisted. All source-level analysis was verified against the
OpenZFS tree. Patches B, C (incident form) and D were written, built, applied
and validated on the affected hardware. Patch A was built and applied but the
form that ran is inert on the hole path ([`CLAIMS.md` 1.12](CLAIMS.md)); its
corrected form has never been built or run. Patches E and F are specifications,
never built or run.
