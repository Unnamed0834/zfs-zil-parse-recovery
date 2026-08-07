# Claims and evidence

Every substantive claim in this repository, with what actually backs it. Sorted
by strength of evidence, strongest first.

The purpose of this file is to make it impossible to mistake a hypothesis for a
demonstrated fact. If a claim is not listed here, treat it as commentary.

Evidence tiers:

- OBSERVED happened on the affected hardware, with captured output
- REPRODUCED reproduced from scratch on an unmodified upstream ZFS build:
  either a stock distro package, or a clean source build from a release tag.
  The versions used differ per claim and are named inline
- SOURCE confirmed by reading OpenZFS source
- PARTIALLY TESTED some aspects tested, others not; scope stated inline
- UNTESTED the experiment that would settle it was never run, or was run in
  a form that could not have settled it
- ESTABLISHED demonstrated by experiment and also explained from source, with
  the explanation predicting the experiment's outcome in advance
- INFERRED consistent with the evidence but not demonstrated
- DISPROVED refuted by source or experiment
- UNKNOWN open question

These nine are the only tiers. Words such as "proven", "supported" or
"conclusive" appear in the prose of other documents as informal emphasis. They
carry no tier weight. Where any of them conflicts with a row in this file, the
row wins.

Three composition forms are permitted, and nothing else. A Tier cell may
contain a single tier, or one of these:

- `A + B`. The claim is backed both ways. `SOURCE + REPRODUCED` (3.8)
  means confirmed by reading the tree and by running it, both. Both halves are
  claimed at full strength.
- `A for <scope>; B for <scope>`, with as many scopes as the claim needs.
  The claim splits. 2.6 is `ESTABLISHED` for the removal case and `UNKNOWN`
  for the incident import; 4.1 is `INFERRED`, `REPRODUCED` and `UNTESTED`
  across three. Every scope is named inline and none may be quoted without
  its scope. This is the form most likely to be misread by someone quoting
  the strongest word in the cell.
- `REPRODUCED (negative)`. A reproduced non-occurrence, as in 2.7 to
  2.9. This is a genuine experimental result, not an absence of one, but it is
  bounded by the versions and configurations actually run. See 3.20 on why a
  non-existence claim is never universal.

Any qualifier beyond these is prose, not tier, and lives in the Backing column.
Rows 2.2 and 3.23 carry such qualifiers; in each case the tier is the
capitalised word and the rest is scope.

A note on section numbers. The sequence runs 1, 2, 3, 4, 5, 5b, 5c, 5d, 6b,
7. There is no §5a and no §6. This is deliberate: sections were appended as the
work progressed, and renumbering would silently break the citations that other
documents in this repository already make into them (`incident/README.md` and
`incident/recovery-breakdown.md` both cite §6b by name). Stale pointers are a
worse failure than an ugly sequence. Claim numbers behave the same way, which
is why §3 continues in §§5b-5d: rows 3.18-3.28 are physically below §4.

All source citations in this repository are against the `zfs-2.4.3` release
tag, commit `83020cf`, which is the tree the incident patches were developed
against, unless a citation explicitly says `master`. Every line number was
re-verified against both trees on 2026-07-31; the full index, including the
differing `master` line for each, is in §7. Where a document cites `master`
line numbers it now says so inline.

---

## 1. The incident and its recovery

| # | Claim | Silo | Tier | Backing |
| --- | --- | --- | --- | --- |
| 1.1 | A 12-disk, 2x raidz2 pool (186 T raw, 140 T allocated) imported read-only but hung forever on any writable import after its mirrored SLOG failed and was removed | Incident | OBSERVED | `incident/recovery-breakdown.md` §6, capacity table §2 |
| 1.2 | The hang was in `spa_ld_verify_logs` -> `spa_check_logs` -> `dmu_objset_find_dp` -> `zil_check_log_chain` -> `zil_parse` -> `zil_read_log_block` -> `arc_read` -> `zio_wait` | Incident | OBSERVED | SysRq-W capture, breakdown §8 and appendix A.3/A.4 |
| 1.3 | The removed log vdev was retained as a hole: `hole_array[0]: 2`, `vdev_children: 3`, `children[2]` with `guid: 0`, `is_hole: 1` | Incident | OBSERVED | `zdb -l /dev/sda1` and `zdb -e -p /dev/disk/by-id storage`, breakdown §9. Not `zdb -C`: that command failed on every attempt (`can't open 'storage': No such file or directory`) because the pool could not be opened by name while imported read-only or while the writable import hung |
| 1.4 | NOPing both `call` sites (`spa_ld_verify_logs`, `spa_ld_claim_log_blocks`) in `zfs.ko` allowed a writable import | Incident | OBSERVED | breakdown §10, byte-level verification and md5 |
| 1.5 | A second, independent defect existed: inconsistent `SM_FREE` space-map records tripping `VERIFY3U(...) failed (17293090816 <= 17179869184)` at `space_map.c:407` | Incident | OBSERVED | breakdown §12, panic text |
| 1.6 | Nine entries were rejected by the `SM_FREE` recovery load in two metaslabs: `ms_id 2` on vdev 0 and `ms_id 2719` on vdev 1 | Incident | OBSERVED | breakdown §13, nine `cmn_err` warnings; the raw warnings do not independently decode each record's type or prove each was an exact duplicate |
| 1.7 | Forcing `ms_condense_wanted` rewrote both metaslabs on disk in a single txg (16404697) | Incident | OBSERVED | dbgmsg `forcing condense=TRUE`, breakdown §13. The reasoning behind it was predictive. Three source facts were read first (`metaslab_should_condense()`, `metaslab_sync()`'s early-return exception, and `metaslab_preload()`), the outcome was predicted from them, and the outcome then occurred. The tier stays OBSERVED rather than ESTABLISHED because this was a single recovery action on one pool, not a controlled experiment with a comparison run |
| 1.8 | Both defects were repaired on disk. The pool then imported repeatedly with plain `zpool import -f storage` on unmodified stock ZFS, including in a later fresh-install environment | Incident | OBSERVED | breakdown §14; `incident/evidence/2026-07-30-post-repair-history.txt` |
| 1.9 | A post-repair scrub subsequently ran 4 days 8 hours 42 minutes and completed with `scan done errors=0` | Incident | OBSERVED | breakdown §20; `incident/evidence/2026-07-30-post-repair-history.txt`, which timestamps it `2026-07-22.21:46:30` `scan setup` to `2026-07-27.06:29:18` `scan done errors=0`. Exact interval: 4d 8h 42m 48s |
| 1.10 | The second defect was invisible until the first was fixed, because read-only imports never load a metaslab for allocation | Incident | SOURCE | breakdown §12 |
| 1.11 | The SLOG SSDs were cleared with `labelclear` and `wipefs` before the log vdev was removed | Incident | OBSERVED | breakdown §3 timeline. Load-bearing for 4.1: a wiped log is a route to `vs_alloc == 0`, which is the gate in 3.8 |
| 1.12 | Patch A, in the form that ran on the affected hardware, cannot have changed the hole path. The applied line was `if ((vd->vdev_islog && vdev_is_dead(vd)) \|\| vd->vdev_ishole) valid = vdev_log_state_valid(vd);`, with no NULL check. For a hole, `vdev_log_state_valid()` returns `B_TRUE`, so `valid` stays true and `zil_check_log_chain()`'s `if (!valid) return (0)` never fires. The repair of the pool is attributable to Patch B | Incident | SOURCE + OBSERVED | Applied text read back verbatim from the recovery machine's `/usr/src/zfs-2.4.3/module/zfs/zil.c:1191` and `:1322` on 2026-07-22. Source chain: `vdev_missing.c:132` (`vdev_op_leaf = B_TRUE`), `vdev.c:2228` (`vdev_removed = B_FALSE` set before the hole early-return at `:2254`), `vdev.c:2248` (HEALTHY), `vdev.c:5728-5730`, the body of `vdev_log_state_valid()` (§7 cites its definition line, `5726`). See `incident/patches/README.md` Patch A |
| 1.13 | Why `spa_ld_verify_logs()` did not block on the repair import, given 1.12 | Incident | UNKNOWN | Verify runs at `spa.c:6106`, before claim at `spa.c:6175`, so Patch B cannot explain it. One candidate is now closed. `spa_log_state` already being `SPA_LOG_CLEAR` from the `import -m` at `2026-07-19.22:42:44`, making `spa_check_logs()` return early (3.4), was eliminated four ways in finding 15: `spa_set_log_state()` assigns an in-core field only (`spa_misc.c:2759`); there are zero references to it in `spa_config.c` or `vdev.c`; it is recomputed per import from `spa_import_flags` (`spa.c:2781`); and experimentally a plain import after `-m` + export is refused byte-identically to before. A hole also never satisfies `vdev_islog && CANT_OPEN` (`spa.c:2825-2826`). Remaining unchecked candidate: the header having drained during the earlier writable import under the NOP'd module, which 4.10 rules out only for the `-N` repair import. Same shape as 4.9 |

What 1.8 and 1.9 establish, and the one thing they do not, is this. The repairs
are committed to disk, the pool imports on unmodified stock modules, and a full
scrub found no checksum error anywhere in the block tree. This is the strongest
single result in the repository.

The limit is stated here because it is a real one. A scrub traverses the block
tree and verifies the checksums of reachable blocks. It does not audit
space-map correctness. A re-emitted space map that over-reports free space
would pass a scrub cleanly and would show up later as allocation into occupied
space. So the clean scrub is strong evidence for Patch B, which zeroed a ZIL
header, and for the absence of data loss. It is not a complete check on
Patch D, which rewrote allocation metadata. What supports Patch D beyond the
scrub is the pool returning to normal read-write service with no allocation
fault reported.

What 1.12 changes is narrow. It does not touch 1.8 or 1.9: the pool was repaired
and the scrub is clean. What it changes is which patch did it, namely Patch
B, not Patch A.

---

## 2. Independently reproducible defect

| # | Claim | Silo | Tier | Backing |
| --- | --- | --- | --- | --- |
| 2.1 | `zpool remove` of a log device whose backing device is failing hangs unkillably in `zil_destroy_sync` -> `zil_parse` -> `zil_read_log_block` -> `arc_read` -> `zio_wait` | Reproducibility | REPRODUCED | `reproducibility/evidence/2026-07-29-zil_parse-removal-hang-2.2.2.txt`, stock ZFS 2.2.2, no patched module. Also reproduced with a captured stack on `zfs-2.4.3`, `reproducibility/evidence/2026-07-31-zfs-2.4.3-test-results.txt` (finding 14), and as a stackless 120 s timeout on `zfs-2.3.4`. On 2.4.3 the `zil_read_log_block`, `zil_destroy_sync` and `spa_vdev_remove_log` frames are inlined away; the chain is the same. Not a new defect: the same chain was reported upstream in 2013 as `#1585` and closed as stale in 2016; see 3.33 before describing this as a discovery |
| 2.2 | That hang also wedges `txg_quiesce`, stalling the entire pool, not just the removal | Reproducibility | REPRODUCED on 2.2.2 only | Same 2.2.2 capture, `dmesg`. NOT REPRODUCED on 2.4.3 (finding 14): only `zpool` was in D-state, and `txg_quiesce` never blocked or appeared in `dmesg`. This is the sole behavioural difference between versions found in this work. Do not state the pool-wide stall without naming the version. Whether 2.4.3 genuinely improved this or the run (~165 s) simply ended too early is not determined. Corroborated 2026-07-31 by a machine-generated artifact rather than a live `ps` reading: the persistent systemd journal on guest `zfs243` shows no `txg_quiesce` frame anywhere in the boot that ran script `07`; see section 6 of `reproducibility/evidence/2026-07-31-zfs-2.4.3-raw-captures.txt` |
| 2.3 | Recovery requires a power cycle. The process cannot be killed and holds `spa_namespace_lock` | Reproducibility | REPRODUCED | Same 2.2.2 run, and again on 2.4.3, where `timeout 120` around the removal expired without effect and a concurrent `zpool list` returned exit 124 |
| 2.4 | 2.1 and 1.2 block at the same site, `zil_parse()` -> `zil_read_log_block()` -> `arc_read()` -> `zio_wait()`, reached through two different callers | Both | SOURCE | `module/zfs/zil.c`; both stacks quoted in the evidence files |
| 2.5 | `zil_parse()` does have an error path. It returns `int`, checks the return of `zil_read_log_block()`, emits `cmn_err(CE_WARN, "ZFS read log block error %d, ...")` and breaks the loop. The hang is that this path is never reached, because `zio_wait()` never returns | Both | SOURCE | `module/zfs/zil.c`, `zil_parse()`, verified against `zfs-2.3.4` and `master` |
| 2.6 | Why the ZIO issued by `arc_read()` never completes, leaving `zio_wait()` blocked indefinitely | Both | ESTABLISHED for the removal case in the test environment; UNKNOWN for the incident import | In the test environment, settled 2026-07-31 (finding 15). The ZIO's disposition is `zio_suspend()`. Three-way: at `failmode=continue` the hang disappears (`remove exit=0`); at `failmode=panic` the kernel panics with `zio_suspend+0x1b0` in the trace; at the default `wait` it blocks forever while `spa_reset_logs()` holds `spa_namespace_lock`, so nothing can clear the suspension. Source gate at `zio.c:5714-5720` requires `ENXIO` + `SPA_LOAD_NONE` + `failmode != continue`; all three hold for a live-pool removal. Incident, still unknown. That suspend cannot fire during an import (`spa_load_state != SPA_LOAD_NONE`), and finding 16 shows the synthesised precondition does not hang on 2.4.3. See 4.9 and 2.7 |
| 2.7 | A hole vdev plus a dangling non-zero `zh_log` DVA resolving to it is NOT sufficient to hang a writable import on `zfs-2.4.3`, whether the chain is unclaimed or claimed | Reproducibility | REPRODUCED (negative) | Two experiments. (a) Unclaimed chain, finding 16, `reproducibility/evidence/2026-07-31-precondition-synthesis.txt`. The state was synthesised via a test-only debug hook forcing the `vs_alloc==0` skip, verified at DVA level (`hole_array[0]: 2`, `DVA[0]=<2:15e6000:11000>`), then imported writable on a pristine stock module: exit 0, pool ONLINE, no D-state, clean `LOADED` in `dbgmsg`. Repeated from pristine restore. (b) Claimed chain, finding 17, `reproducibility/evidence/2026-07-31-claimed-chain-variant.txt`. Importing once claims the chain (`claim_txg 37`, `flags 0x2`, "already claimed", same DVA); re-importing that state fails fast with `I/O error`, exit 1, no D-state, three runs. `zil_check_log_chain()` and `zil_parse()` are both entered and both return, confirmed by ftrace, 4 and 3 entries respectively, and the load proceeds past log verify to `spa_load_verify()`, which rejects the blkptr via the hole-vdev check (3.30). Version scope: `zfs-2.4.3` only. Not tested on 2.2.2, 2.3.4, 2.4.1 or the incident's build. Does not overturn 1.2 (OBSERVED), 3.1 or 3.6. Unclaimed-import mechanism refined by 3.30 |
| 2.8 | The claimed-chain variant is tested and closed negatively | Reproducibility | REPRODUCED (negative) | Finding 17. Net effect is that the gap between the synthesis and the incident widens: neither variant hangs. Remaining untested candidate differences, none now favoured over any other: the incident's build (`zfs-2.3.3-107-gec5aa9bfd`); 140 T across many datasets; encrypted datasets; TrueNAS middleware and concurrent dataset operations; a genuinely failing device rather than a clean hole; and the space-map corruption (1.5) present on the same pool. Label messages are downstream of 3.31, not a blocker |
| 2.9 | Read-only import of the *claimed*-chain state also fails, which the incident's read-only import did not | Reproducibility | REPRODUCED (negative) | Finding 17. `zpool import -N -o readonly=on` returns `I/O error`, exit 1. The affected pool imported read-only without complaint (1.1, OBSERVED). The claimed-chain state is therefore a third distinct behaviour, not a closer model of the incident |

This is the only fully independent reproduction in the repository, and it is
reproducible today without reference to the incident pool.

But read 2.7 to 2.9 before describing defect 1. The removal-side hang (2.1)
is solid and its mechanism is now established (2.6). The import-side story is
not: synthesising the incident's precondition exactly and importing it on
`zfs-2.4.3` does not hang, on either variant. An unclaimed chain imports
cleanly; a claimed chain fails fast with `EIO`. Whatever made the affected pool
hang on import has not been identified, and the mechanism this repository has
been asserting for defect 1 is incomplete. As of finding 17 there is no
favoured candidate for the missing ingredient.

---

## 3. Confirmed mechanisms

| # | Claim | Silo | Tier | Backing |
| --- | --- | --- | --- | --- |
| 3.1 | `zil_check_log_chain()` guards only on `vd->vdev_islog && vdev_is_dead(vd)`. A hole vdev has `vdev_islog = 0`, so the guard never fires | Both | SOURCE | `module/zfs/zil.c:1297` at `zfs-2.4.3`; the same line number in `master`. Function spans `1264-1329` in both |
| 3.2 | `zil_parse()`'s loop condition is `!BP_IS_HOLE(&blk)`, so an all-zero DVA terminates safely. The defect requires a non-zero DVA | Both | SOURCE | `module/zfs/zil.c` |
| 3.3 | Log verify and claim run only `if (type != SPA_IMPORT_ASSEMBLE && spa_writeable(spa))`, which is why read-only import succeeds | Incident | SOURCE | `module/zfs/spa.c:5604`, in `spa_ld_verify_logs()` at `spa.c:5600`. (`master`: gate `5661`, function `5657`) |
| 3.4 | `spa_check_logs()` calls `zil_check_log_chain()` only for `SPA_LOG_MISSING` or `SPA_LOG_UNKNOWN`, returning early on `SPA_LOG_CLEAR` | Both | SOURCE | `module/zfs/spa.c:2843`, switch at `2848`. (`master`: `2900`) |
| 3.5 | amotin's "Fix log vdev removal issues" change is present in `zfs-2.4.3` but tests `BP_IS_HOLE`, not `vdev_ishole`, so it does not cover this case | Both | SOURCE | `module/zfs/zil.c:1099` (`zil_destroy`) and `:1173` (`zil_claim`), same line numbers in `master`. Version scope, verified 2026-07-31 by checking the release tags directly; see 3.29. The change is in `zfs-2.4.3` and not in 2.2.2, 2.3.3, 2.3.4, 2.3.5, 2.3.6, 2.3.7, 2.4.0, 2.4.1 or 2.4.2. It is also in `zfs-2.3.8` (2026-06-08). SHA discipline: the master commit is `1e1d64d665e30fbedfc551b38271e1e2f280d3e0`, which is *not* an ancestor of any release tag. It reached `zfs-2.4.3` as cherry-pick `50697dc93` and `zfs-2.3.8` as `ec88deb2c`. Where this repository writes `1e1d64d` it means the change, not the tag ancestry |
| 3.6 | `zil_check_log_chain()` dereferences `vd` with no NULL check, but `vdev_lookup_top()` returns NULL for an out-of-range index | Both | SOURCE | the `vdev_lookup_top()` call is `zil.c:1296`, the unguarded deref `:1297`, in both trees. Latent NULL deref; see `incident/patches/README.md` Patch A |
| 3.7 | `spa_vdev_remove()` calls `spa_reset_logs()`, which walks datasets via `dmu_objset_find()` and performs `zil_reset` -> `zil_suspend` -> `zil_commit_impl`, before the log vdev becomes a hole | Reproducibility | SOURCE + PARTIALLY TESTED | finding 1. The stack capture (on 2.4.1, against a *frozen* pool that deadlocked mid-walk) proves the call path is entered; it does not demonstrate completion for every dataset. That the walk clears every header is separately shown by 3.12 |
| 3.8 | `spa_reset_logs()` is gated on `if (vd->vdev_stat.vs_alloc != 0)`. When a log reports 0, the reset is skipped entirely and no error is returned | Reproducibility | SOURCE + REPRODUCED | `module/zfs/vdev_removal.c:2144`, `spa_vdev_remove_log()` (`master`: `2148`); confirmed empirically in `reproducibility/06`, log showed `ALLOC 0`, `remove exit=0`, hole created |
| 3.9 | `zpool import -m` does not create a hole. It leaves the log vdev as UNAVAIL | Reproducibility | REPRODUCED | finding 7, `reproducibility/05` |
| 3.10 | Among the routes tried, only `zpool remove` produced a hole | Reproducibility | PARTIALLY TESTED | findings 3 and 7. What is REPRODUCED is the narrow positive, that `zpool remove` produces a hole with `is_hole: 1`. What is bounded is the exclusion of every other route. Bounded by 3.20: non-existence not REPRODUCED |
| 3.11 | The `SPA_LOG_CLEAR` path in `zil_claim()` clears every dataset's `zh_log`, including a dataset whose encryption key is unavailable | Reproducibility | REPRODUCED | finding 8, `reproducibility/05` |
| 3.12 | `spa_reset_logs()` clears headers even when every log I/O returns an error. It loses the data, reports data errors, and leaves no dangling DVA | Reproducibility | REPRODUCED | finding 5, `reproducibility/03` |
| 3.13 | `zpool remove` of a log is refused outright when a dataset is encrypted and its key is unloaded: "Mount encrypted datasets to replay logs" | Reproducibility | REPRODUCED | finding 6, `reproducibility/04`; `lib/libzfs/libzfs_pool.c:4438`. Exactly one trigger was tested, an encrypted dataset with its key unloaded, and it hits a purpose-built encryption pre-check whose error string names encryption. The general "unholdable dataset" case is UNTESTED on every version |
| 3.14 | A mounted dataset drains its own ZIL and zeroes `zh_log`. Unmounting is what makes a header persist | Reproducibility | REPRODUCED | finding 8 analysis, `reproducibility/04` on 2.2.2. Qualified by 3.28: this holds for a dataset that goes on taking sync writes, which overwrite `zh_log` via `zil_sync()`'s LWB loop. A dataset that is merely mounted, with `ZIL_REPLAY_NEEDED` clear, takes `zil_sync()`'s `keep_first` path, which preserves the existing DVA under a fresh GUID |
| 3.15 | `dump_intent_log()` returns early on `BP_IS_HOLE(&zh->zh_log)`, so the presence of a `ZIL header:` line in `zdb -i` is itself the signal that `zh_log` is non-zero | Both | SOURCE | `cmd/zdb/zdb_il.c`. This is the repository's detection method, not an incidental observation: it gives a read-only, non-wedging probe for the bug state. `reproducibility/lib.sh` `inspect_precondition()` is built on it |
| 3.16 | `zpool freeze` is available on the builds where `01` was run, no debug build required | Reproducibility | REPRODUCED | finding 2. `reproducibility/ATTEMPTS.md` logs `01-verify-environment.sh` on three builds: 2.4.1, `zfs-2.3.4` and `zfs-2.4.3`. Availability on 2.2.2 is UNTESTED |
| 3.17 | `zpool freeze` cannot be combined with `zpool remove`. Removal needs a txg to sync, a frozen pool cannot, so it deadlocks | Reproducibility | REPRODUCED | finding 4 |
| 3.29 | The tree that carried the repair and the trees that carried the reproduction testing differ by amotin's fix. The incident repair was built on `zfs-2.4.3`, which contains it; the test environment ran 2.2.2, the `zfs-2.3.4` tag and 2.4.1, none of which do. So the fix ran as that change plus Patches A to D on top; the testing ran without it at all | Both | SOURCE | Checked by fetching each release tag from `github.com/openzfs/zfs` on 2026-07-31 and grepping for the two markers the commit introduces, the `zil_claim()` `BP_IS_HOLE` early return and the widened `memset(zh, 0, sizeof (zil_header_t))`. The commit is dated 2026-03-04, authored by `alexander.motin@TrueNAS.com`, and closes openzfs/zfs#18277. For exact SHAs per branch see 3.5. This row is about test coverage only. It does not weaken 3.1 or 3.5; see the note below |
| 3.30 | `traverse_zil_block()` skips an unclaimed chain before it can be verified, and this, not `ZIO_FLAG_SPECULATIVE` alone, is why finding 16's unclaimed variant imported cleanly. With `claim_txg == 0` and a birth txg at or past `spa_min_claim_txg()`, the callback returns -1 and the block is never handed to the traversal, so `spa_load_verify()` never examines it. With `claim_txg != 0` the guard does not fire, the block *is* traversed, and 3.31 rejects it | Reproducibility | SOURCE + REPRODUCED | `module/zfs/dmu_traverse.c:93-98` at `zfs-2.4.3`; behaviour confirmed both ways by finding 17. Both `ZIO_FLAG_SPECULATIVE` (`zil.c:256-257`) and the `ECKSUM`/`ENOENT` swallow (`zil.c:1328`) are also real; the traversal skip is what keeps `spa_load_verify()` away from the bad blkptr |
| 3.31 | OpenZFS already carries an explicit hole-vdev check on block pointers, and it is what catches the claimed-chain case. `zfs_blkptr_verify()` rejects a DVA whose vdev index resolves to a hole; `spa_load_verify()` counts it as a metadata error and the import fails with `EIO` rather than blocking | Reproducibility | SOURCE + REPRODUCED | `module/zfs/zio.c:1271` at `zfs-2.4.3` (the format string `"blkptr at %px DVA %u has hole VDEV %llu"`; emitted at runtime through `zfs_blkptr_verify_log()`, reported in `dbgmsg` as `zio.c:1135`). Observed in finding 17: `ziltest: blkptr at ... DVA 0 has hole VDEV 2`, then `spa_load_verify found 1 metadata errors`, then `FAILED: spa_load_verify failed [error=5]`. Note the tension with 3.1: the blkptr layer checks for hole vdevs; `zil_check_log_chain()` does not |
| 3.32 | The "unexplained label artifact" recorded in finding 16 is a downstream symptom of 3.31, not an artifact of the lab debug hook | Reproducibility | REPRODUCED | Finding 17, full `dbgmsg` in `reproducibility/evidence/2026-07-31-claimed-chain-variant.txt`. Order of events: `spa_load_verify` fails `EIO` on the hole-vdev blkptr; `spa_load_retry: rewind, max txg: 50`; the rewind caps the acceptable uberblock at txg 42, below the label's own txg 51; the label is discarded as `too large (51 > 42)`; the retry reports `label config unavailable`. The lab debug hook is not implicated |
| 3.33 | The reproduced removal hang (2.1) is a re-report of a known, maintainer-acknowledged defect, not a discovery. `openzfs/zfs#1585` (2013-07-11, "Kernel hang when removing faulted log device") posts a `zpool` stack of `zio_wait` <- `arc_read_nolock` <- `dsl_read_nolock` <- `zil_parse` <- `zil_destroy_sync` <- `zil_destroy` <- `zil_suspend` <- `zil_vdev_offline` <- `dmu_objset_find` <- `spa_offline_log` <- `spa_vdev_remove` <- `zfs_ioc_vdev_remove`, with `txg_quiesce` also in D-state. This is the same chain as 2.1 under the pre-2016 names | Reproducibility | SOURCE + OBSERVED (upstream) | The rename is verified: `a1d477c24` ("OpenZFS 7614, 9064 - zfs device evacuation/removal", Ahrens, 2016-09-22) renames `spa_offline_log` -> `spa_reset_logs` and `zil_vdev_offline` -> `zil_reset`. Issue state read from the GitHub API 2026-08-04: open 2013-07-11, closed 2016-10-05 by `behlendorf` with "Closing as stale. If anyone still hitting this let us know and we'll reopen it." Reconfirmed in-thread 2014 by two further reporters. Maintainer diagnosis in-thread, 2013-07-11: "trying to remove the faulted log device causes zfs to try and read from it. This read basically hangs while holding an important lock which causes everything to block." What this repository adds over #1585: (a) deterministic reproducer `reproducibility/07-path-h-yank-live-log.sh`; (b) confirmation on 2.2.2, `zfs-2.3.4` and `zfs-2.4.3`; (c) mechanism 2.6 via `failmode`. Those are already claimed at 2.1 and 2.6 |

3.29 is about which trees were tested. It is not a suggestion that `1e1d64d`
would have helped. It would not, and that matters more than the coverage gap:

`1e1d64d` tests `BP_IS_HOLE(&zh->zh_log)`, an all-zero DVA. The incident
pool held a valid, non-zero DVA whose vdev index resolved to a hole, which
that test does not match (3.5, 3.2). Independently of the tag arithmetic, the
affected system was a fresh install of the current TrueNAS release, fully
updated as of 2026-07-22, and the current release at the time of writing is the
same one, and it hung. Whatever that build did or did not carry, the state was
not covered. The gap in 3.1 stands on its own and no version of `1e1d64d`
closes it. That gap is what Patch A is for.

It does bear on two narrower, test-hygiene points: (a) 4.5's
"2.4.x is already hardened" hypothesis was never actually tested by the original
three-way comparison, because the 2.4.x the test environment ran does not carry
the hardening; and (b) for a week no reproduction script had been run on 2.4.3,
so the negative results had a version-coverage hole where a reader would most
expect them not to.

Both were closed on 2026-07-31 by building a `zfs-2.4.3` VM (`zfs243`, at
commit `83020cf`, module string `zfs-2.4.3-0-g83020cf`) and running scripts
`01`, `03`, `04`, `06` and `07` against it (finding 14). All four precondition
paths behave identically to the unhardened trees, and the hang reproduces there
with a captured stack. 4.5 is accordingly now DISPROVED on proper grounds. The
reproduction work and the incident work now share a commit.

---

## 4. Inferred, not demonstrated

Causation claims in this section are scoped; read the tier cell before citing a row.

| # | Claim | Silo | Tier | Note |
| --- | --- | --- | --- | --- |
| 4.1 | The `vs_alloc == 0` skip (3.8) is what stranded the dangling header on the affected pool | Incident | INFERRED for the incident; REPRODUCED for the skip in isolation; UNTESTED for the gate | Three separate propositions, three different tiers (cite as 4.1a, 4.1b, 4.1c). (a) REPRODUCED: *skipping* `spa_reset_logs()` while a live ZIL chain exists on the log strands a header dangling into the hole, in one step, every time (finding 16, twice from pristine restore, verified at DVA level). (b) UNTESTED: that the *gate* can reach that state. This is UNTESTED in the tier's precise sense, "run in a form that could not have settled it", because the skip was forced with a test-only debug hook while the log reported `vs_alloc 22.0M` (`reproducibility/evidence/2026-07-31-precondition-synthesis.txt`:103), whereas the real gate fires only at `vs_alloc == 0`. Reaching `vs_alloc == 0` while a live chain still references the log is an accounting inconsistency that was never produced: every natural route to `vs_alloc == 0` clears the headers on the way (3.11, 3.18, finding 8). (c) INFERRED: that the affected pool took that route. amotin's deletion of the adjacent `ASSERT0(vd->vdev_stat.vs_alloc)` (see 3.5 for SHAs) is consistent with such an inconsistency being possible, but that is one commit message, not evidence. What is claimed: "skipping the reset strands headers" is REPRODUCED; "the `vs_alloc == 0` gate strands headers" is not, and is not claimed. Also, `reproducibility/06` confirmed the gate but did not strand a header, because reaching `vs_alloc == 0` naturally needs an `import -m`, which clears headers (3.11) |
| 4.2 | The exact sequence that produced a hole together with a surviving non-zero `zh_log` | Incident | UNKNOWN | Ten hypotheses across ZFS 2.2.2, 2.3.4, 2.4.1 and 2.4.3, seven of them validly executed (A never run; E not expressible without TrueNAS middleware, see 4.3; I run only in an invalid form). Every documented route clears the headers, refuses, or hangs. Full enumeration in `reproducibility/FINDINGS.md` findings 12 and 13. Classified as an anomaly of the hardware incident, see `CONCLUSIONS.md` §3. Scope caveat: the `zfs-2.3.4` release tag was tested, which is not the build the incident ran; see 4.8. Testing closed |
| 4.3 | The malformed `py-libzfs: zpool remove storageNone` call at `2026-07-19.22:57:28` played a role | Incident | UNKNOWN | Recorded in the pool's own `zpool history`, same second as a concurrent `zfs set`. Never tested, and not testable in the test environment: the call form cannot be expressed through plain `zpool`/`zfs`; it requires TrueNAS `middlewared`/py-libzfs. This is hypothesis E in `reproducibility/FINDINGS.md`'s enumeration. Do not confuse it with Patch E, an unrelated proposed change to the `vs_alloc` gate |
| 4.4 | A dataset unreachable by `dmu_objset_find()` keeps its header during removal | Reproducibility | DISPROVED | 3.11 and 3.13. Encryption causes refusal, not skipping. Scope: encrypted case only |
| 4.5 | ZFS 2.4.x is already hardened against this relative to 2.3.4 | Reproducibility | DISPROVED | Tested properly on 2026-07-31 (finding 14). A `zfs-2.4.3` VM (`zfs243`, commit `83020cf`) was built and scripts `01`, `03`, `04`, `06` and `07` run against it. All four precondition paths behave identically to 2.2.2 and 2.3.4, and the hang reproduces with a captured stack. The hardened tree is not hardened against any of this. Not re-run on 2.4.3: `05`, the freeze route, the offline route |
| 4.6 | What caused the original SLOG hardware failure | Incident | UNKNOWN | SMART clean on both SSDs (`No Errors Logged`, 0 reallocated) yet they flickered on the SAS backplane. Cabling, backplane slot and SATA-behind-SAS-expander all untested |
| 4.7 | What caused the space-map corruption (1.5) | Incident | UNKNOWN | Never reproduced, and never attempted synthetically: no hypothesis for its cause was ever strong enough to script. Coincided with a scrub interrupted by reboot |
| 4.8 | That the negative results generalize to the incident's own environment: TrueNAS 25.10.x, its own OpenZFS build, and removal driven through `middlewared` / py-libzfs | Both | PARTIALLY TESTED | The `zfs-2.3.4` release tag was built and tested on Debian 13 (finding 13) and behaves identically to 2.2.2 and 2.4.1. This is not the incident's build. The incident's running module reported `zfs-2.3.3-107-gec5aa9bfd`, a snapshot 107 commits past the `zfs-2.3.3` tag; see `incident/evidence/2026-07-30-post-repair-history.txt`. Also untested: kernel `6.12.91-production+truenas`, x86-64, and the malformed `py-libzfs: zpool remove storageNone` call, which cannot be expressed without middleware. Full fidelity chart in `CONCLUSIONS.md` §3, "How closely the test environment matched the incident environment" |
| 4.9 | Why a read whose DVA resolves to a hole vdev blocks, instead of failing fast. | Reproducibility | DISPROVED (the premise: it does *not* block) | Three parts. (a) The cited mechanism was the wrong entry point. A read by DVA has `io_vd == NULL` and dispatches to `vdev_mirror_ops`, not to `vdev_hole_ops`/`vdev_missing_io_start()`. Confirmed twice: `vdev_mirror_io_start` appears in the `failmode=panic` trace, and `zdb -R <pool> 2:20000:1000` against a hole asserts inside `vdev_mirror_io_start()` at `vdev_mirror.c:616`. The real path is `vdev_mirror_map_init()` -> `vdev_mirror_child_select()` returning -1 (`:546-551`, `vdev_readable(hole)` false) -> no child I/O issued at all (`:659-660`) -> `vdev_mirror_io_done()` sets ENXIO (`:761-762`). (b) Confirmed empirically on both variants: unclaimed, the read is never issued at all because the chain is skipped before traversal (3.30) and the import completes cleanly; claimed, the blkptr is rejected by the hole-vdev check (3.31) and the import fails fast with `EIO`. Neither blocks, and `zil_check_log_chain()`/`zil_parse()` were both observed by ftrace to run and return (2.7). (c) The question that replaced it, "what did the incident have that a synthesised pool does not?", has no favoured candidate. The claimed-chain variant led until finding 17 tested it and closed it (2.8). Does not contest 1.2, 1.3 or 1.8 |
| 4.10 | That mounting datasets under the NOP-patched module cleared the dangling headers before the repair import | Incident | DISPROVED | Considered and ruled out. The NOP'd import used `zpool import -f -N storage` (`-N`, do not mount); `zil_replay_disable=1` was set, which routes a mount to `zil_destroy(zilog, B_FALSE)` (`zfs_vfsops.c:767-768`; `master`: `796-797`), the `keep_first == B_FALSE` path that calls `zil_destroy_sync()` and would hit the same `zil_parse()` block; and most datasets never mounted at all, because the root filesystem was read-only |
| 4.11 | That the hole-vdev blkptr check (3.31) was added after the incident's build, which would explain why the incident hung where the synthesis fails fast | Reproducibility | DISPROVED | Finding 17. Checked by fetching each release tag from `github.com/openzfs/zfs` on 2026-07-31 and grepping `module/zfs/zio.c` for the `"has hole VDEV"` format string: present at `zfs-2.2.2` (`zio.c:1113`), `zfs-2.3.3` (`:1290`, the incident's lineage), `zfs-2.3.4` (`:1290`), `zfs-2.4.1` (`:1271`), `zfs-2.4.3` (`:1271`) and `master` (`:1266`). Present in every release checked, including the one the incident ran |


---

## 5. Patches, by evidence backing and contribution type

| Patch | What it does | Silo | Backing | Conclusiveness | Contribution type | Medium |
|---|---|---|---|---|---|---|
| F | Propagate the error `zil_destroy_sync()` currently discards up to `spa_vdev_remove_log()` | Reproducibility | 3.21 SOURCE | The discarded return is real and source-confirmed. F does not fix the reproduced hang (2.1): it never touches `zil_parse()` or the blocking `zio_wait()`, and an error that is never produced cannot be propagated | Issue, describing 2.1 and 2.6 | Issue first |
| A | `vdev_ishole` guard in `zil_check_log_chain`, plus the NULL check | Both | 3.1, 3.6 SOURCE. Not validated on hardware; see 1.12 | The gap is source-confirmed and the NULL deref is real. But the form that ran on the affected pool routed the hole case into `vdev_log_state_valid()`, which returns `B_TRUE` for a hole, so it changed nothing (1.12). The corrected form, which sets `valid = B_FALSE` directly, is written but never built and never run | Patch submission | PR (rebase onto master first). Must be submitted as the corrected form |
| B | `zil_claim()` clears a hole-vdev ZIL header, repairing in place | Incident | 1.8 OBSERVED on real hardware; the patch that actually repaired the pool (1.12) | OBSERVED on the affected pool only. Reuses the existing upstream `SPA_LOG_CLEAR` sequence from `1e1d64d` (3.22), so the mechanism has precedent even though the trigger is new | RFC | Discussion before PR |
| E | Stop skipping the reset on `vs_alloc == 0` | Reproducibility | 3.8 SOURCE + REPRODUCED; causation 4.1 INFERRED | The gate is SOURCE and REPRODUCED. The causation is INFERRED; do not claim 4.1 as demonstrated | Issue describing the gap | Issue |
| C | Space-map assertion made recoverable via `zfs_panic_recover()` | Incident | 1.5 OBSERVED | OBSERVED. The incident repair worked, but the recommended form is unwritten and never run. Only the unconditional skip was ever executed, and it must never be reused | RFC (only the gated form) | Discussion before PR |
| D | Force metaslab condense to rewrite a corrupt space map | Incident | 1.6, 1.7, 1.9 OBSERVED | OBSERVED on the affected pool only | RFC | Discussion before PR; depends on C |

A to D, as applied on the affected hardware, are documented in
`incident/patches/`; candidates E and F are specified in
`reproducibility/patches/`.

---

## 5b. Additional confirmed mechanisms, findings 11 and 12

| # | Claim | Silo | Tier | Note |
| --- | --- | --- | --- | --- |
| 3.18 | On the single run logged, `zpool offline` on a log vdev was permitted, drove `vs_alloc` to 0, and drained the ZIL doing it, so headers were cleared before the gate opened | Reproducibility | PARTIALLY TESTED | finding 11. One run, on one version (2.2.2), with no saved artifact; the output was transcribed live and `reproducibility/ATTEMPTS.md` records it in prose only. Whether the drain is guaranteed by design, and whether it holds under a failing device, is untested. Version scope, added 2026-08-04: this no longer describes `master` for a redundant log. `520eeeaa6` (Alan Somers, 2026-06-24, closes #18664, post-`zfs-2.4.3`) gates the log branch of `vdev_offline_locked()` on `dtl_required`, so both `metaslab_group_passivate()` and the `spa_reset_logs()` call at `vdev.c:4675` are now skipped when the log is redundant. The observation above still holds for a single log, which is what finding 11 actually ran: `vdev_dtl_required()` returns `B_TRUE` immediately when `vd == tvd`, and a lone log leaf *is* its own top-level vdev. It does not hold for one side of a mirrored log on `master`, where the ZIL is no longer drained. Relevant to the incident, whose SLOG was a mirror (1.1): on a post-`520eeeaa6` build, offlining one side of it would not clear the headers |
| 3.19 | `zpool import` without `-m` on a wiped or missing log is refused outright, so `zil_check_log_chain()` is never reached | Reproducibility | REPRODUCED | finding 12 |
| 3.20 | No sequence of `zpool`/`zfs` commands *among the nine routes enumerated in finding 12* produces a hole vdev together with a surviving non-zero `zh_log` | Reproducibility | PARTIALLY TESTED | finding 12. This is a bounded negative, not a universal one, and it cannot be "REPRODUCED": a non-existence claim is not reproducible, only the individual routes are. Version coverage is not uniform, and no version has full route coverage. Counting the nine post-split routes, `reproducibility/ATTEMPTS.md` supports: six on 2.2.2 (2a, 2b, 3, 4, 5, 7); five on 2.4.1 (1, 2a, 5, 6, 8); five on 2.3.4 (1, 2a, 2b, 4, 5); five on 2.4.3 (the same five as 2.3.4), the release carrying `1e1d64d` (finding 14). The bounded negative holds per cell of that matrix, not per version; the per-route matrix is in `reproducibility/FINDINGS.md` finding 12. An undocumented or untried sequence is not excluded, and neither is TrueNAS's build. See 4.8 |
| 3.21 | `zil_destroy_sync()` is `void` and discards `zil_parse()`'s return with a `(void)` cast; `zil_destroy()` drops it in turn, so `spa_reset_logs()` cannot see a per-dataset ZIL failure | Both | SOURCE | `module/zfs/zil.c`, verified against `zfs-2.4.3` and `master`. This is a real gap, but it is not the cause of the reproduced hang (2.5, 2.6) |
| 3.22 | The `memset(zh, 0, sizeof (zil_header_t))` + `os_encrypted`/`os_next_write_raw` + `dsl_dataset_dirty()` sequence in `zil_claim()`'s `SPA_LOG_CLEAR` path is pre-existing upstream code. Patch B reuses that exact sequence under a `vdev_ishole` condition | Both | SOURCE | `module/zfs/zil.c:1217-1220` at `zfs-2.4.3`. Precise attribution: amotin's `1e1d64d` did not introduce the whole sequence. Its diff changes `BP_ZERO(&zh->zh_log);` to `memset(zh, 0, sizeof (zil_header_t));`; the `if (os->os_encrypted) ... os_next_write_raw` and `dsl_dataset_dirty()` lines are unchanged context and predate it. amotin widened the zeroing from the DVA to the whole header |

## 5c. The `failmode` question, resolved at source

Two separate results. 3.23 and 3.24 are why `failmode` could not be reached
during the load: three mechanisms, two of them inside 3.23. 3.25 and 3.26 are a
different point: two guards ZFS provides for "a top-level vdev is gone" that a
hole defeats.

For "`failmode` was unreachable during the load", cite 3.23-3.24. For "the
guards that would have helped were defeated", cite 3.25-3.26. For the section as
a whole, cite 3.23-3.26.

| # | Claim | Silo | Tier | Backing |
| --- | --- | --- | --- | --- |
| 3.23 | `failmode` could not be changed on the affected pool at incident time. Two of the three reasons are here: `zpool set` requires an imported pool; and `zpool import -o failmode=` is applied by `spa_prop_set()` at `spa.c:7432`, after `spa_load_best()` returns at `spa.c:7401`, additionally gated on `spa_writeable(spa)`. The hang is inside `spa_load_best()`, so no import-time `-o` can reach it | Incident | SOURCE, with an unrecorded observational half | The source half is verified: `module/zfs/spa.c` at `zfs-2.4.3` (`master`: `7508`, `7477`). The observational half has no artifact. `failmode` was attempted on the hardware and would not take (`incident/recovery-breakdown.md` appendix B), but no captured output of those attempts exists in this repository, only the first-hand report. Treat "attempted and refused" as testimony and the mechanism as source |
| 3.24 | The third reason: the only `failmode` in effect during `spa_load_impl()` is the value already persisted on the pool. `spa_ld_get_props()` (`spa.c:5284`) reads it at `spa.c:5421`, and is called at `spa.c:6069`, before `spa_ld_verify_logs()` at `spa.c:6106`. For the affected pool that was TrueNAS's default, `wait` | Incident | SOURCE | `module/zfs/spa.c` at `zfs-2.4.3` (`master`: `5341`, `5478`, `6126`, `6163`) |
| 3.25 | ZFS's automatic `failmode` override never fires for a removed log, hole or not. `spa.c:5435` forces `failmode` to `continue` when `spa_missing_tvds > 0`. `spa_missing_tvds` is set by `vdev_root_open()`, whose counting test is `if (cvd->vdev_open_error && !cvd->vdev_islog && cvd->vdev_ops != &vdev_indirect_ops)` (`vdev_root.c:102`). Two independent reasons it is not counted: log vdevs are excluded outright by `!cvd->vdev_islog`, so a failed log never counts either; and a hole opens successfully, is set `VDEV_STATE_HEALTHY` (`vdev.c:2248`) and returns 0 from `vdev_open()` (`vdev.c:2254-2255`), so `vdev_open_error` is 0 as well | Incident | SOURCE | `zfs-2.4.3` (`master`: `5492`, `vdev_root.c:102` unchanged, `vdev.c:2273`/`2279-2280`). Defect shape at 3.1 and 3.26 only; 3.8 is allocation-accounting; 3.25 excludes logs by design |
| 3.26 | A hole vdev also defeats the "drop the logs" mercy path. `spa_ld_verify_logs()` tolerates a failed `spa_check_logs()` by logging "dropping the logs" and continuing (`spa.c:5605-5609`), but only `if (spa->spa_missing_tvds != 0)` (`:5607`). With a hole that counter is 0 (3.25), so the import hard-fails via `spa_vdev_err(rvd, VDEV_AUX_BAD_LOG, ENXIO)` at `spa.c:5613-5614` instead. On the affected pool it never got that far, because it hung first | Incident | SOURCE | `module/zfs/spa.c` at `zfs-2.4.3` (`master`: `5662-5666`, `5664`, `5670-5671`) |

3.23 to 3.26 establish that the `failmode` avenue was not overlooked during the
incident; on the source reading it was closed. Three mechanisms put the setting
out of reach during the load, and a fourth, the one ZFS provides automatically
for exactly this situation, is disabled by the same hole vdev that caused the
problem. All four are verifiable by reading the tree. They do not establish
that `failmode` would have changed the outcome had it been reachable; see 2.6
and 4.9, where the more basic question of why the read blocks is still open.

One question that reads as open here is not: a pool already carrying
`failmode=continue` before its log begins failing. Every script that creates
the scratch pool passes `-o failmode="$FAILMODE"` to `zpool create`
(`reproducibility/07-path-h-yank-live-log.sh:142`,
`reproducibility/lib.sh:107`), so the pool carries the setting from creation,
before the log is yanked at step 6. Finding 15 ran exactly that at
`FAILMODE=continue`: no hang, `remove exit=0`. That is the same run that
established 2.6.

What remains open on `failmode` is narrower: `continue` and `panic` have
each been run once, on `zfs-2.4.3` with script `07` only. No other script, and
no other version, has been run at anything but the default `wait`. See 2.6.

## 5d. Verification of the incident's source tree

| # | Claim | Silo | Tier | Backing |
| --- | --- | --- | --- | --- |
| 3.27 | The `zfs-2.4.3` release tag, the tree the incident patches were developed against, is identical to current `master` in `vdev_hole_ops` (`.vdev_op_leaf = B_TRUE`, `vdev_missing.c:132` in both), `vdev_log_state_valid()` (`vdev.c:5726`; `master`: `5810`), and `vdev_open()`'s hole path (`vdev.c:2248`/`2254-2255`; `master`: `2273`/`2279-2280`). The code is the same; only line numbers move. Source reasoning about hole-vdev behaviour therefore transfers between the two trees without adjustment | Incident | SOURCE | Fetched and diffed directly at tag `zfs-2.4.3` (commit `83020cf`) against `master` (`023d44b9e`, 2026-07-28), re-verified 2026-07-31. `83020cf` is also independent corroboration of the incident record: the recovery module reported itself as `zfs-2.4.3-0-g83020cf-dirty-dist`, which is this tag exactly, plus local edits |
| 3.28 | A dangling ZIL DVA survives a mount. In `zil_sync()`'s destroy block, `memset(zh, 0, sizeof (zil_header_t))` at `zil.c:4178` runs on both paths, but the `keep_first` branch at `zil.c:4182-4192` then restores `zh->zh_log = blk` after `zil_init_log_chain()`, which rewrites only `blk_cksum`: the two GUID words, objset id and seq (`zil.c:217-227`). The DVA is not touched. A pool in the hole-plus-dirty-header state therefore cannot self-heal by being mounted; something must actively zero the header. This is the source justification for Patch B doing `memset` rather than skipping | Both | SOURCE | `module/zfs/zil.c`, identical line numbers in `zfs-2.4.3` and `master`. Qualifies 3.14: a dataset that takes further sync writes does overwrite `zh_log` via the LWB loop at `zil.c:4206-4207`; a dataset that is merely mounted does not |

## 6b. How to validate each tier

What a third party can and cannot check, stated plainly.

| Tier | Validatable by a reader? | How |
|---|---|---|
| REPRODUCED | Yes, independently | Run the script in `reproducibility/` on a stock distro package, or on a source build from a release tag. `reproducibility/ENVIRONMENT.md` pins the VM, kernel and ZFS versions. Raw captures in `reproducibility/evidence/` include the exact commands used. Which versions were used is per claim, not blanket: the precondition paths were run on 2.2.2, 2.4.1, 2.3.4 and 2.4.3; the removal hang (2.1) was run on 2.2.2, 2.3.4 and 2.4.3, with a captured stack on 2.2.2 and 2.4.3 but not on 2.3.4, and never run on 2.4.1; the import-side negatives (2.7 to 2.9) were run on 2.4.3 only. Eleven of the eighteen findings have no evidence artifact and exist as prose only; the per-finding coverage table is in `reproducibility/evidence/README.md` |
| SOURCE | Yes | Every claim cites file and line, and §7 gives both the `zfs-2.4.3` and the `master` line for each. Fetch either tree and read it. Nothing rests on a paraphrase |
| ESTABLISHED | Yes, but it is the most demanding one | Requires *both* halves independently: re-run the experiment (as REPRODUCED) and check that the cited source predicts its outcome (as SOURCE). The repository has exactly one ESTABLISHED claim, 2.6. To validate it: run `07-path-h-yank-live-log.sh` at `FAILMODE=wait` (hangs) and at `FAILMODE=continue` (does not), then read `zio.c:5714-5720` and confirm all five gate conditions hold for that ZIO. If the source reading did not predict the experiment, the tier is wrong and should be REPRODUCED + SOURCE instead |
| OBSERVED | No, not independently | The hardware has been repaired and returned to service, so the failure state no longer exists. What remains is the captured output quoted in `incident/recovery-breakdown.md` |
| DISPROVED | Yes, independently | The claim is refuted by source or experiment. A third party can verify the refutation by re-running the experiment or reading the source cited |
| PARTIALLY TESTED | Yes, partially | Some aspects have been tested (e.g., ZFS 2.3.4-1 on Debian), but the full environment (TrueNAS build, middleware, x86-64) has not. A third party can verify the tested portion |
| UNTESTED | Yes, by running it | The experiment is named inline. Nothing rests on it either way; it is recorded so the gap is not mistaken for a result |
| INFERRED / UNKNOWN | Not applicable | These are explicitly not claims |

### The honest limitation on OBSERVED

The incident evidence is transcribed from private debugging session logs which
are not published, because they contain credentials and management addresses.
The selected stack traces, `zdb` output and dbgmsg lines in
`incident/recovery-breakdown.md` are transcribed and selectively abridged, but a
sceptical reader cannot diff them against a source. They should be read as a
first-hand report, not as independently verifiable evidence.

---

## 7. Source citation index

Every SOURCE citation in this repository, re-verified on 2026-07-31 and
again in full on 2026-08-04 against two trees fetched from
`github.com/openzfs/zfs`:

- `zfs-2.4.3`, commit `83020cf`, the incident's tree, and the default for
  every citation in this repository
- `master`, commit `023d44b9e`, dated 2026-07-28

The code is the same in both for every row below; only line numbers move. This
table exists so a reader never has to guess which tree a number came from, and
so the next person can re-verify mechanically rather than by reading prose.

| What | File | `zfs-2.4.3` | `master` | Used by |
|---|---|---|---|---|
| `zil_check_log_chain()` definition | `module/zfs/zil.c` | 1264 | 1264 | 3.1, 3.6 |
| `vdev_lookup_top()` call | `module/zfs/zil.c` | 1296 | 1296 | 3.6, Patch A |
| the unguarded `vdev_islog && vdev_is_dead` test | `module/zfs/zil.c` | 1297 | 1297 | 3.1, 3.6, Patch A |
| `zil_destroy()` `BP_IS_HOLE` early return (amotin) | `module/zfs/zil.c` | 1099 | 1099 | 3.5 |
| `zil_claim()` `BP_IS_HOLE` early return (amotin) | `module/zfs/zil.c` | 1173 | 1173 | 3.5, 3.22, Patch B |
| `zil_read_log_block()` `ZIO_FLAG_CANFAIL` | `module/zfs/zil.c` | 251 | 251 | 4.9 |
| `ZIO_FLAG_SPECULATIVE` on an unclaimed chain | `module/zfs/zil.c` | 256-257 | 256-257 | 2.7, 3.30 |
| the `ECKSUM`/`ENOENT` swallow in `zil_check_log_chain()` | `module/zfs/zil.c` | 1328 | 1328 | 2.7, 3.30 |
| `traverse_zil_block()` unclaimed-chain skip | `module/zfs/dmu_traverse.c` | 93-98 | 93-98 | 3.30 |
| `zfs_blkptr_verify()` hole-vdev rejection | `module/zfs/zio.c` | 1271 | 1266 | 3.31, 4.11 |
| `zfs_blkptr_verify_log()` (the `dbgmsg` call site) | `module/zfs/zio.c` | 1135 | 1135 | 3.31 |
| `zil_init_log_chain()` (rewrites `blk_cksum` only) | `module/zfs/zil.c` | 217-227 | 217-227 | 3.28 |
| `zil_sync()` `memset(zh, 0, ...)` | `module/zfs/zil.c` | 4178 | 4178 | 3.28 |
| `zil_sync()` `keep_first` branch restoring the DVA | `module/zfs/zil.c` | 4182-4192 | 4182-4192 | 3.28 |
| `zil_sync()` LWB loop overwriting `zh_log` | `module/zfs/zil.c` | 4206-4207 | 4206-4207 | 3.14, 3.28 |
| `spa_check_logs()` definition | `module/zfs/spa.c` | 2843 | 2900 | 3.4 |
| `spa_ld_get_props()` definition | `module/zfs/spa.c` | 5284 | 5341 | 3.24 |
| the `failmode` read (`spa_prop_find(ZPOOL_PROP_FAILUREMODE)`) | `module/zfs/spa.c` | 5421 | 5478 | 3.24 |
| automatic `failmode=continue` override | `module/zfs/spa.c` | 5435 | 5492 | 3.25 |
| `spa_ld_verify_logs()` definition | `module/zfs/spa.c` | 5600 | 5657 | 3.3, 3.26 |
| the `spa_writeable(spa)` gate | `module/zfs/spa.c` | 5604 | 5661 | 3.3 |
| "dropping the logs" mercy path | `module/zfs/spa.c` | 5605-5609 | 5662-5666 | 3.26 |
| `spa_vdev_err(rvd, VDEV_AUX_BAD_LOG, ENXIO)` | `module/zfs/spa.c` | 5613-5614 | 5670-5671 | 3.26 |
| `spa_ld_claim_log_blocks()` definition | `module/zfs/spa.c` | 5646 | 5703 | breakdown §18, Patch B lock safety |
| `spa_ld_get_props()` call site | `module/zfs/spa.c` | 6069 | 6126 | 3.24 |
| `spa_ld_verify_logs()` call site | `module/zfs/spa.c` | 6106 | 6163 | 3.24, breakdown §9 |
| `spa_ld_claim_log_blocks()` call site | `module/zfs/spa.c` | 6175 | 6232 | breakdown §9 |
| `spa_load_best()` call in `spa_import()` | `module/zfs/spa.c` | 7401 | 7477 | 3.23 |
| `spa_prop_set()` call in `spa_import()` | `module/zfs/spa.c` | 7432 | 7508 | 3.23 |
| `vdev_missing_io_start()` `SET_ERROR(ENOTSUP)` | `module/zfs/vdev_missing.c` | 73 | 73 | 4.9 |
| `vdev_hole_ops` `.vdev_op_leaf = B_TRUE` | `module/zfs/vdev_missing.c` | 132 | 132 | 3.27 |
| `vdev_root_open()` counting test (`vdev_open_error && !vdev_islog && !indirect`) | `module/zfs/vdev_root.c` | 102 | 102 | 3.25 |
| `vdev_open()` sets `VDEV_STATE_HEALTHY` | `module/zfs/vdev.c` | 2248 | 2273 | 3.25, 1.12 |
| `vdev_open()` clears `vdev_removed` on success | `module/zfs/vdev.c` | 2228 | 2253 | 1.12, Patch A |
| `vdev_open()` returns 0 for a hole | `module/zfs/vdev.c` | 2254-2255 | 2279-2280 | 3.25, 3.27, 1.12 |
| `vdev_is_dead()` returns true for holes by design | `module/zfs/vdev.c` | 4754-4756 | 4838-4840 | 1.12, Patch A |
| `vdev_log_state_valid()` definition (returns `B_TRUE` for a hole) | `module/zfs/vdev.c` | 5726 | 5810 | 3.27, 1.12, Patch A |
| `vdev_missing_open()` (used by `vdev_hole_ops`, returns 0) | `module/zfs/vdev_missing.c` | 46-62 | 46-62 | 1.12 |
| failmode-sensitive suspend (`ENXIO` + `SPA_LOAD_NONE`) | `module/zfs/zio.c` | 5714-5720 | 5780-5786 | 4.9 |
| `!CANFAIL` catch-all suspend | `module/zfs/zio.c` | 5722-5724 | 5788-5790 | 4.9 |
| `zio_suspend()` panics under `failmode=panic` | `module/zfs/zio.c` | 2668 | 2677 | `CONCLUSIONS.md` §2 |
| `zil_replay_disable` routing a mount to `zil_destroy` | `module/os/linux/zfs/zfs_vfsops.c` | 767-768 | 796-797 | 4.10, Patch F |
| `zil_destroy_sync()` callers outside `zil.c` | `module/zfs/dsl_destroy.c` | 925, 975 | 868, 918 | Patch F |
| `space_map_load_callback()` `VERIFY3U` | `module/zfs/space_map.c` | 406-407 | 405-406 | 1.5, Patch C |
| `metaslab_condense()` "condensing" dbgmsg | `module/zfs/metaslab.c` | 3929 | 3946 | 1.7, Patch D |
| `vdev_ishole` struct field | `include/sys/vdev_impl.h` | 284 | 276 | Patch A, Patch B |
| the `vs_alloc != 0` gate | `module/zfs/vdev_removal.c` | 2144 | 2148 | 3.8, Patch E |

On the commits cited, and where they actually live. OpenZFS lands changes on
`master` and cherry-picks them onto release branches, so a master SHA is
generally not an ancestor of a release tag. Verified 2026-08-04:

| Change | `master` SHA | Release SHA | In which tags | Used by |
|---|---|---|---|---|
| "Fix log vdev removal issues" (amotin, 2026-03-04, closes #18277) | `1e1d64d66` | `50697dc93` (2.4-release), `ec88deb2c` (2.3-release) | `zfs-2.4.3`, `zfs-2.3.8` | 3.5, 3.22, 3.29, 4.1, Patch B |
| "Simplify log vdev removal code" (Dimitropoulos, 2019-01-31, closes #8347) | `6c926f426a26` | none | 2.0.0 onward | 3.8 note. Did not introduce the `vs_alloc` gate; it unwrapped an existing gate from a redundant `if (vd->vdev_islog)` and added the `ASSERT0(vs_alloc)` that `1e1d64d` later removed |
| origin of the `vs_alloc != 0` gate | `428870ff734` (Behlendorf, 2010-05-28, "Update core ZFS code from build 121 to build 141") | none | all | 3.8, Patch E. Inherited illumos b121->b141 code, originally guarding `spa_offline_log()` |
| `spa_offline_log` -> `spa_reset_logs`, `zil_vdev_offline` -> `zil_reset` | `a1d477c24` (Ahrens, 2016-09-22) | none | 0.8.0 onward | 3.33 (maps #1585's 2013 stack onto the modern one) |
| skip `spa_reset_logs()` on `zpool offline` of a redundant log | `520eeeaa6` (Somers, 2026-06-24, closes #18664) | not yet in a release tag | `master` only; not in `zfs-2.4.3` or anything earlier | 3.18 version scope. Gates the log branch of `vdev_offline_locked()` on `dtl_required`. Does not touch `spa_vdev_remove_log()`, so 2.1 and 3.8 are unaffected |

The upstream issues cited, with state read from the GitHub API on 2026-08-04:

| Issue | State | Relation | Used by |
|---|---|---|---|
| [#1585](https://github.com/openzfs/zfs/issues/1585) | closed stale 2016-10-05 | Same call chain as 2.1 | 3.33 |
| [#13273](https://github.com/openzfs/zfs/issues/13273) | closed stale 2023-08-12 | possible match, no stack posted | 3.33 |
| [#17427](https://github.com/openzfs/zfs/issues/17427) | open | import path, no stack posted | `CONCLUSIONS.md` §3 |
| [#12980](https://github.com/openzfs/zfs/issues/12980) | open, Status: Stale | import path, stack is `txg_sync` | `CONCLUSIONS.md` §3 |
| [#14775](https://github.com/openzfs/zfs/issues/14775) | open | not related, `zl_suspend_lock` deadlock from #14514 | recorded so it is not re-proposed |
| [#18277](https://github.com/openzfs/zfs/issues/18277) | closed 2026-03-04 | the PR for amotin's fix | 3.5, 3.29 |

Line-number notes for §7 citations: `spa.c:5657` (3.3) and `spa.c:2900` (3.4)
are `master` lines, not `zfs-2.4.3`. For 3.23 the `spa_prop_set()` call is not
at `spa.c:7428` (that is the `if (props != NULL)` four lines above). The
`master` failmode-sensitive suspend block is `5780-5786` (`5783` is the `ENXIO`
line; `5789` is already in the adjacent `!CANFAIL` statement).

`space_map.c:407` and `metaslab.c:3945` in `incident/recovery-breakdown.md` are
quoted panic and dbgmsg output from the patched module at the time, not pristine
tree citations. In pristine `zfs-2.4.3` the `VERIFY3U` spans 406-407 and the
condense dbgmsg is at 3929. The transcript is left as captured.
