# Attempt log

One row per run. Record the ZFS version with every result; a negative on one
version is not a negative on all of them.

Precondition testing stands as follows as of 2026-07-31. Ten hypotheses
enumerated, of which seven were validly executed; four ZFS versions; seventeen
findings. Hypothesis A (`02`) was never run (see the NOT RUN row below) and
hypothesis I (`08`) ran only in an INVALID form whose fixed version was never
re-run, so neither counts as executed. Finding 18 was added on 2026-08-04,
after the date this header is scoped to, and came from a search for previous
upstream reports rather than from a run.

Mechanism of the finding-10 hang: SETTLED for the removal case in the test
environment on 2026-07-31. `failmode` was varied at last (finding 15):
`continue` removes the hang, `panic` panics at `zio_suspend()`. The ZIO's
disposition is `zio_suspend()` under the default `wait`. Claim 2.6 is
established for the removal case in the test environment. It does not explain
the incident, whose import-time path cannot reach that suspend; see findings 16
and 17 and claim 4.9.

The claimed-chain variant is closed negatively (finding 17, 2026-07-31). The
claimed state was produced deliberately, archived, and imported three times.
Writable import fails fast with EIO at `spa_load_verify()`, exit 1, no D-state
task; `zil_check_log_chain()` and `zil_parse()` are both entered and both
return, confirmed by ftrace. Read-only import fails too, which the incident's
did not. Neither the claimed nor the unclaimed form of the synthesised
precondition hangs on `zfs-2.4.3`, and the gap to the incident is therefore
wider than before, not narrower.

Still not complete: no stack was captured on 2.3.4; the incident's import hang
remains unexplained; and the remaining candidate differences between the
synthesis and the incident (the incident's build, scale, encryption, TrueNAS
middleware, a genuinely failing device, the concurrent space-map defect) are
all untested, with none favoured over any other.

On evidence artifacts, not every row here has a saved capture. Rows that rest
on prose only are marked [no artifact] in the note cell. A finding-by-finding
coverage table is in [`evidence/README.md`](evidence/README.md).

Version coverage is per script, not uniform. Read the ZFS column on every row.
In particular `07-path-h-yank-live-log.sh`, the script that reproduces the
hang, has been run on 2.2.2, 2.3.4 and 2.4.3, never on 2.4.1. 2.4.1 was the
baseline for the precondition scripts (01, 03, 04, 05), but note that `06` is
not in that list either: `06-path-g-vs-alloc-zero.sh` was run on 2.2.2, 2.3.4
and 2.4.3 only, and there is no 2.4.1 row for it anywhere in this table.
`01-verify-environment.sh` was never run on 2.2.2 either: this table logs `01`
on 2.4.1, `zfs-2.3.4` and `zfs-2.4.3` only (`CLAIMS.md` 3.16). This table is
authoritative for what was run. With 2.4.3 covered, the 2.4.1 gap no longer
matters much: the releases on either side of it both hang.

`zfs-2.4.3` was added on 2026-07-31 and closed that gap (finding 14). It is
both the tree the incident repair was built on and the only release containing
amotin's `1e1d64d`, which is absent from 2.2.2, every 2.3.x, and 2.4.0 through
2.4.2. Scripts `01`, `03`, `04`, `06` and `07` were run there: all four
precondition paths behave identically, and the hang reproduces with a captured
stack. Claim 4.5 is now DISPROVED rather than UNTESTED. `05`, the freeze route
and the offline route were not re-run on 2.4.3.

On ordering within 2026-07-31, a great many rows share that date and the table
is not self-ordering. Rows dated 2026-07-31 carry a session marker, `[S1]`
through `[S5]`, in the note cell:

- `[S1]`, morning, source review. Tag fetches and code reading, before the
  `zfs243` VM existed.
- `[S2]`, midday, `zfs243` build and script runs. Finding 14.
- `[S3]`, afternoon, `failmode` and `SPA_LOG_CLEAR`. Finding 15.
- `[S4]`, late afternoon, precondition synthesis. Finding 16.
- `[S5]`, evening, the claimed-chain variant, plus the journal recovery.
  Finding 17. Later than every other marker.

This matters in at least one place: claim 4.5 is re-tiered twice on the same
date, in opposite directions, and without the markers the two rows read as a
flat contradiction. In `[S1]` the source review re-tiered it from DISPROVED
back to UNTESTED because the comparison that had "disproved" it turned out to
be mis-specified. In `[S2]`, after actually running the scripts on `zfs-2.4.3`,
it was re-tiered from UNTESTED to DISPROVED. `[S2]` is later and is the current
tier. Nothing was reversed twice; the first move withdrew an unearned verdict
and the second earned it.

Outcome codes:

- CONFIRMED: the intended state was produced
- RULED OUT: the path completed but did not produce the state
- DEADLOCK: the run wedged the machine and taught us a mechanism
- BLOCKED: could not complete for an environmental reason
- INVALID: the run was measured wrongly and proves nothing
- NOT REPRODUCED: the behaviour was looked for and was not observed
- DISPROVED: the hypothesis was refuted
- CLOSED: the line of enquiry is finished

These are outcome codes for runs, local to this file. They are not the evidence
tiers; the only nine tiers are the ones at `../CLAIMS.md` §"Evidence tiers".
Where a row's outcome code and a claim's tier appear to conflict, the tier
wins.

A note on "new": no existing OpenZFS issue describing this hang on the
removal path was located, but the tracker search behind that is not recorded
here. Rows below say "hang reproduced" rather than "new bug" for that reason.

| Date | ZFS | Script / action | Outcome | Note |
|---|---|---|---|---|
| 2026-07-29 | 2.4.1 | manual: pool with log vdev, `zpool freeze`, sync writes, `zpool remove` | DEADLOCK | Produced finding 1. `spa_vdev_remove` blocks in `spa_reset_logs` -> `zil_reset` -> `zil_suspend` -> `zil_commit_impl`. Log removal resets every dataset ZIL by design. Stack saved to `evidence/`. Required `limactl stop --force`. |
| 2026-07-29 | 2.4.1 | manual: `zpool freeze` on a stock build | CONFIRMED | Finding 2. No debug build needed. |
| 2026-07-29 | 2.4.1 | manual: `zpool remove` of a healthy log vdev | CONFIRMED | Finding 3. Produces `hole_array[0]: 1`, `type: 'hole'`, `is_hole: 1`, matching the affected pool's signature. |
| 2026-07-29 | 2.4.1 | manual: freeze combined with remove | RULED OUT | Finding 4. Incompatible by construction: removal needs a txg to sync, a frozen pool cannot. Freeze is the wrong lever. |
| 2026-07-29 | 2.4.1 | `01-verify-environment.sh` | CONFIRMED | All 6 checks pass. Produced a vdev tree structurally identical to the affected pool: `hole_array[0]: 2`, `vdev_children: 3`, `children[2]` a hole. Clean removal leaves an importable pool. |
| | 2.2.2 / 2.4.1 | `02-path-a-import-m.sh` | NOT RUN | Superseded before it was needed. Path A is `import -m` with a missing log, and `05` tests A combined with D on the same code path, giving findings 7 and 8. Running A alone would add nothing. The script is kept because it isolates the path if anyone wants it. |
| 2026-07-29 | 2.4.1 | `03-path-c-failed-log.sh` | RULED OUT | Finding 5. Removal succeeded despite 100% injected I/O errors on the log; hole created; 180 data errors reported; but every `zh_log` was still cleared. Also exposed a bug in the gate: `zdb -dddd` never prints the ZIL header. Correct probe is `zdb -i`. |
| 2026-07-29 | 2.4.1 | `04-path-d-unopenable-dataset.sh` | RULED OUT | Finding 6. `zpool remove` refused: "Mount encrypted datasets to replay logs." No hole created. A second, purpose-built guard on log removal. |
| 2026-07-29 | 2.4.1 | positive control: hard power cut with 19,112 ZIL records in flight | CONFIRMED | [no artifact] Gate calibrated. Live unclaimed chains detected on `pc` and `pc/ds1` (1.15 G). Confirms `zdb -i` detects a non-zero `zh_log`. Flagged: this row has no saved capture and no finding number, and it is the calibration of the detection method every "all headers cleared" result in this table depends on. If the gate did not in fact detect what this run says it detected, every negative here is unsupported. Nothing was preserved but this row: no `zdb` output, no record of the 19,112 figure's derivation. It should be re-run with output captured to `evidence/`. |
| 2026-07-29 | 2.4.1 | read `cmd/zdb/zdb_il.c` from upstream | CONFIRMED | `dump_intent_log()` returns early on `BP_IS_HOLE(&zh->zh_log)`, so the `ZIL header:` line alone is the signal. The `claim_*` zeros are claim state, not header contents. Retracts an earlier false-positive claim. |
| 2026-07-29 | 2.4.1 | `05-path-f-import-m-plus-unopenable.sh` | RULED OUT | Findings 7 and 8. `import -m` leaves the log UNAVAIL, not a hole. The `SPA_LOG_CLEAR` path cleared every header including the encrypted dataset with no key. |
| 2026-07-29 | 2.2.2 | `03-path-c-failed-log.sh` on Ubuntu 24.04 | RULED OUT | Identical to 2.4.1: hole created, 170 data errors, all headers cleared. Weakens the version hypothesis. |
| 2026-07-29 | 2.2.2 | `04-path-d-unopenable-dataset.sh` | RULED OUT | Same guard present in 2.2.2: removal refused. The plain/enc header difference was mounted-vs-unmounted draining, not encryption. |
| 2026-07-29 | both | read `vdev_removal.c` `spa_vdev_remove_log()` | CONFIRMED | Finding 9. `spa_reset_logs()` is gated on `if (vd->vdev_stat.vs_alloc != 0)`. A wiped or absent log reports 0, so the reset is skipped and no error is returned. That it strands headers in practice is INFERRED, not shown; see `../CLAIMS.md` 4.1. |
| 2026-07-29 | 2.2.2 | `06-path-g-vs-alloc-zero.sh` | PARTIAL | Gate confirmed: log showed `ALLOC 0`, `remove exit=0`, hole created, reset skipped. No dangling header, because reaching that state needed an `import -m`, which clears them (f8). |
| 2026-07-29 | 2.2.2 | `07-path-h-yank-live-log.sh` | CONFIRMED (hang reproduced) | Finding 10. `zpool remove` of a log device failing under a live pool hangs unkillably in `zil_destroy_sync` -> `zil_parse` -> `arc_read` -> `zio_wait`. `txg_quiesce` wedged too. Reproduced from scratch on stock 2.2.2. Stack in `evidence/`. |
| 2026-07-29 | 2.2.2 | `08-path-i-vs-alloc-window.sh` | INVALID (probe bug, now fixed) | Originally used `zdb -i <pool>` against a live imported pool, which emits nothing, so the header count read 0 in all 12 rounds. The exported form showed all three datasets dirty at `vs_alloc` 27 MB, retracted the conclusion. Probe method was fixed to use `zdb -e -p "$WORK" -i "$POOL"` (matching `inspect_precondition()` in lib.sh), reading on-disk state correctly. Now redundant: finding 12 enumerated the routes tried and none produced a hole plus a surviving `zh_log`, a bounded negative over those routes, not a proof that no route exists. |
| 2026-07-29 | 2.2.2 | manual: wipe the log, then `zpool import` without `-m` | RULED OUT | Refused outright: "one or more devices is currently unavailable ... use '-m' to import the pool anyway". `zil_check_log_chain()` is never reached by this route. Contributes to finding 12. |
| 2026-07-29 | 2.2.2 | manual: `zpool offline` the log, then `zpool remove` | RULED OUT (one run, one version, no artifact) | Finding 11. Tier note, 2026-08-02: `CLAIMS.md` 3.18 was re-tiered from REPRODUCED to PARTIALLY TESTED on the strength of this row. It is a single run, never repeated on 2.4.1, 2.3.4 or 2.4.3, and the output below was transcribed live with nothing saved to `evidence/`. Offline is permitted and drives `vs_alloc` to 0, opening the finding-9 gate, and the removal created the hole. But offlining drains the ZIL first, so every header was already clear. Version scope added 2026-08-04: that last sentence holds for the single log used here, but not for a redundant log on `master`, where `520eeeaa6` skips the drain. See finding 11's correction and `CLAIMS.md` 3.18. |
| 2026-07-29 | both | enumeration complete | CLOSED | Finding 12. Eight routes tested (nine after the 2026-07-31 split of row 2 into 2a and 2b; see `FINDINGS.md` finding 12). Every one clears the headers, refuses, or hangs. No documented sequence produces a hole plus a surviving non-zero `zh_log`. Reclassified as an anomaly of the hardware incident, `../CONCLUSIONS.md` §3. |
| 2026-07-30 | 2.3.4 | `01-verify-environment.sh` | CONFIRMED | All checks pass on ZFS 2.3.4 (built from source, tag `zfs-2.3.4`, not the incident's build). Finding 13: same behavior as 2.2.2 and 2.4.1. |
| 2026-07-30 | 2.3.4 | `03-path-c-failed-log.sh` | RULED OUT | Same result: hole created, 170 data errors, all headers cleared. ZFS 2.3.4 behaves identically. |
| 2026-07-30 | 2.3.4 | `04-path-d-unopenable-dataset.sh` | RULED OUT | Same guard: removal refused. ZFS 2.3.4 behaves identically. |
| 2026-07-30 | 2.3.4 | `06-path-g-vs-alloc-zero.sh` | RULED OUT | Same result: hole created, all headers cleared. ZFS 2.3.4 behaves identically. |
| 2026-07-30 | 2.3.4 | `07-path-h-yank-live-log.sh` | CONFIRMED (120 s timeout only: no stack, hang not verified at any frame) | Finding 13. The evidence file says only that "`zpool remove` did not return within 120 seconds and the VM had to be force-stopped. That is all." No `/proc/<pid>/stack`, no hung-task watchdog output, no `ps` showing D-state. A 120-second non-return is consistent with the finding-10 hang and is inferred to be it from the 2.2.2 run, but it is equally consistent with any other stall. The frame is not observed on 2.3.4. Required `limactl stop --force`. Evidence in `evidence/2026-07-30-zil_parse-removal-hang-2.3.4.txt`. |
| 2026-07-31 | 2.4.3 (tag) | source review: fetched tag `zfs-2.4.3` and compared `vdev_hole_ops`, `vdev_log_state_valid()`, `vdev_open()`'s hole path against `master` | CONFIRMED | [S1] [no artifact: source reading only; no saved diff or `grep` output] Claim 3.27. Identical in both trees, so hole-vdev source reasoning transfers between the incident's build tree and current master without adjustment. |
| 2026-07-31 | 2.4.3 (tag) | source review: `failmode` reachability during `spa_load_impl()` | CONFIRMED | [S1] [no artifact: source reading only; line numbers re-verified 2026-07-31, but no capture saved] Claims 3.23-3.26. `zpool import -o failmode=` is applied by `spa_prop_set()` at `spa.c:7432`, after `spa_load_best()` at `spa.c:7401`; load-time value comes from `spa.c:5421`; the automatic `failmode=continue` override at `spa.c:5435` never fires for a hole, because `vdev_root_open()` counts only children with `vdev_open_error != 0` and a hole opens HEALTHY. Explains the incident-side report that `failmode` would not take by any command, a report that is testimony, with no captured artifact. |
| 2026-07-31 | 2.4.3 (tag) | source review: does mounting clear a dangling `zh_log`? | RULED OUT | [S1] [no artifact: source reading only] Claim 3.28 and 4.10. `zil_sync()`'s `keep_first` path preserves the DVA and only rewrites `blk_cksum` (`zil.c:4182-4192`, `zil.c:217-227`), so a mount cannot self-heal the state. Separately, the NOP'd incident import used `-N` and `zil_replay_disable=1`, and most datasets never mounted. Qualifies finding 8's reading of 3.14. |
| 2026-07-31 | 2.4.3 (tag) | source review: why does a read to a hole vdev block rather than fail fast? | OPEN: new question | [S1] [no artifact: source reading only; superseded, see the `zdb -R` row below] Claim 4.9. `vdev_missing_io_start()` returns `ENOTSUP` without blocking; `zil_read_log_block()` sets `ZIO_FLAG_CANFAIL`; the failmode suspend at `zio.c:5714` needs `ENXIO` plus `SPA_LOAD_NONE`. On this reading the import should fail cleanly, not hang. It hung in both environments. Reading incomplete, or the blocking read was not to the hole. This supersedes "test failmode" as the leading question. |
| 2026-07-31 | 2.4.3 (tag) | source review: does Patch A, as applied on the incident hardware, actually skip the chain? | RULED OUT: it does not | [S1] [partial artifact] The applied Patch A text quoted here was read back verbatim from the recovery machine and is preserved in `../CLAIMS.md` 1.12 and `../incident/patches/README.md`; the supporting source chain is reading only, with no capture. Claim 1.12. Applied text read back from the recovery machine: `if ((vd->vdev_islog && vdev_is_dead(vd)) \|\| vd->vdev_ishole) valid = vdev_log_state_valid(vd);`, with no NULL check, contrary to the documented diff. For a hole, `vdev_log_state_valid()` returns `B_TRUE` (`vdev_op_leaf` is true at `vdev_missing.c:132`, `vdev_removed` cleared at `vdev.c:2228`, `vdev_faulted` false), so `valid` stays true and `zil_check_log_chain()`'s early return never fires. Patch A is inert on the hole path; Patch B is what repaired the pool. Leaves claim 1.13 open: why verify did not block on the repair import. |
| 2026-07-31 | tags 2.2.2 to 2.4.3 | source review: which releases contain amotin's `1e1d64d`? | CONFIRMED | [S1] [partial artifact] The claim that each tag was fetched and grepped covers 2.2.2, 2.3.3, 2.3.4, 2.3.5, 2.4.0, 2.4.1, 2.4.2 and 2.4.3, but only the `zfs-2.4.3` greps are preserved, in `ENVIRONMENT.md`, as the pre-test verification commands for `zfs243`. The negative results for the other seven tags rest on this row alone. Claim 3.29. Fetched each release tag and grepped for the two markers the commit introduces. Present in `zfs-2.4.3` only; absent from 2.2.2, 2.3.3, 2.3.4, 2.3.5, 2.4.0, 2.4.1, 2.4.2. So the repair tree has it and none of the three test trees do, and the version hypothesis behind finding 13 was mis-specified. Re-tiers claim 4.5 from DISPROVED to UNTESTED. This is the first of two re-tierings of 4.5 on this date; see `[S2]`, which is later and re-tiers it back to DISPROVED after the scripts were actually run on `zfs-2.4.3`. Does not affect claim 3.1: `1e1d64d` matches an all-zero DVA and cannot cover this state in any tree. |
| 2026-07-31 | n/a | commit archaeology: provenance of the `vs_alloc != 0` gate | CONFIRMED | [S1] [no artifact: commit archaeology from upstream history; no saved `git log` or `git show` output] Provenance corrected 2026-08-04: the gate was not introduced or moved by `6c926f426a26`. It was already inside `spa_vdev_remove_log()`; that commit (Serapheim Dimitropoulos, 2019-01-31, closes #8347, reviewed by Ahrens and Behlendorf) only unwrapped it from a redundant `if (vd->vdev_islog)` and added the `ASSERT0(vs_alloc)`. The gate itself dates from `428870ff734` (Behlendorf, 2010-05-28, the illumos b121->b141 import), where it guarded the then-named `spa_offline_log()`. See `CLAIMS.md` §7. Separately, `1e1d64d` deleted the adjacent `ASSERT0(vd->vdev_stat.vs_alloc)`, with the commit message "While it should be so in perfect world, it might be not if space leaked at any point." That is the whole of the fact: one deleted assertion and the message that accompanied it, both in `git log`, recorded without interpretation. A single commit message does not establish a project-wide position; readers can weigh it themselves. `1e1d64d` also added `tests/zfs-tests/tests/functional/removal/removal_with_missing_log.ksh`, which already covers the `labelclear` + `import -m` + `remove` route and corroborates findings 8 and 9. |
| 2026-07-31 | 2.4.3 | build: VM `zfs243`, Debian 13, source build of tag `zfs-2.4.3` | CONFIRMED | [S2] Finding 14. Module reports `zfs-2.4.3-0-g83020cf`, zero commits past the tag, and the same commit the incident repair was built from. `1e1d64d` presence verified three ways before testing. |
| 2026-07-31 | 2.4.3 | `01-verify-environment.sh` | CONFIRMED | [S2] All six checks pass. Hole created on clean removal; pool stays importable. Identical to 2.2.2, 2.3.4, 2.4.1. |
| 2026-07-31 | 2.4.3 | `03-path-c-failed-log.sh` | RULED OUT | [S2] Hole created, 170 data errors, every `zh_log` cleared. Identical to all three earlier versions. |
| 2026-07-31 | 2.4.3 | `04-path-d-unopenable-dataset.sh` | RULED OUT | [S2] "Mount encrypted datasets to replay logs", `remove exit=1`, no hole. The replay guard is present in the hardened tree too. |
| 2026-07-31 | 2.4.3 | `06-path-g-vs-alloc-zero.sh` | RULED OUT | [S2] `ALLOC 0`, `remove exit=0`, hole created, reset skipped, headers clear. The `vs_alloc` gate is unchanged by `1e1d64d`. |
| 2026-07-31 | 2.4.3 | `07-path-h-yank-live-log.sh` | CONFIRMED (hang reproduced, stack captured) | [S2] Finding 14. `zpool remove` wedged in `zio_wait` <- `arc_read` <- `zil_parse` <- `zil_destroy` <- `zil_suspend` <- `zil_reset` <- `spa_reset_logs` <- `spa_vdev_remove`. Confirmed independently by the kernel hung-task watchdog at 120 s. `zpool list` returned exit 124. Required `limactl stop --force`. First stack for this hang on any version other than 2.2.2, and the newest release is no longer the untested one. `vs_alloc` after yank was 72K, non-zero. Evidence in `evidence/2026-07-31-zfs-2.4.3-test-results.txt`. |
| 2026-07-31 | 2.4.3 | observation during `07`: is `txg_quiesce` wedged? | NOT REPRODUCED | [S2] Only `zpool` was in D-state; `txg_quiesce` never blocked and never appears in `dmesg`. On 2.2.2 both were wedged. This is the only behavioural difference between versions found in this work. Scopes claim 2.2 to 2.2.2. Claims 2.1 and 2.3 hold on both. Cause not determined; possibly timing, observed for ~165 s only. |
| 2026-07-31 | 2.4.3 | conclusion: version hypothesis | CLOSED | [S2] Finding 14. All four paths behave identically on the one release that carries `1e1d64d`. Re-tiers claim 4.5 from UNTESTED to DISPROVED, the second and current of the two re-tierings on this date; `[S1]` above is the earlier one, which withdrew an unearned DISPROVED, and this one earns it by experiment, and widens claim 3.20's bounded negative to four releases including the hardened one. Discharges the coverage gap 3.29 flagged. |
| 2026-07-31 | 2.4.3 | `07-path-h-yank-live-log.sh` at `FAILMODE=continue` | RULED OUT (no hang) | [S3] Finding 15. `remove exit=0`, hole created, all `zh_log` cleared, script completed. Same script/build/state as the hanging run, one variable changed. Confirms the source prediction: `failmode=continue` breaks the third conjunct of the suspend gate at `zio.c:5714-5720`. Moves claim 2.6 to established for the removal case in the test environment. Also retires the speculation that this route strands a header: `zil_sync()` zeroes it at `zl_destroy_txg` regardless. |
| 2026-07-31 | 2.4.3 | `07-path-h-yank-live-log.sh` at `FAILMODE=panic` | CONFIRMED (kernel panic) | [S3] Finding 15. `Kernel panic ... failure mode property for this pool is set to panic`, with `zio_suspend+0x1b0` in the trace. Required adding `console=hvc0` to the guest cmdline first; the initial run produced no capturable output and was discarded as inconclusive rather than recorded as an inference. Scope limit: a persistent-log re-run shows the panic fires during the step-6 scrub provocation, before `zpool remove`, so it does not isolate the `zil_parse()` read. |
| 2026-07-31 | 2.4.3 | source + experiment: does `SPA_LOG_CLEAR` survive export/import? | RULED OUT | [S3] Finding 15, claim 1.13. `spa_set_log_state()` assigns an in-core field only (`spa_misc.c:2759`); zero references in `spa_config.c`/`vdev.c`; recomputed per-import from `spa_import_flags` (`spa.c:2781`). Experimentally, a plain import after `-m` + export is refused byte-identically to before. Plus: a hole never satisfies `vdev_islog && CANT_OPEN` (`spa.c:2825-2826`). Leading candidate for 1.13 closed; 1.13 stays UNKNOWN. |
| 2026-07-31 | 2.4.3 | synthesise the precondition via a test-only debug hook forcing the `vs_alloc==0` skip | CONFIRMED: state produced | [S4] Finding 16. `hole_array[0]: 2` + `DVA[0]=<2:15e6000:11000>` on `ziltest/ds1` and `<2:1000:1000>` on `ziltest`, verified at `zdb -iiiii`. First time this state has existed in the test environment. Partly demonstrates claim 4.1: given the skip, headers strand, every time. But the gate condition was not reproduced -- the hook fired with the log at `vs_alloc 22.0M`, and the real gate fires only at `vs_alloc == 0`, so "the `vs_alloc == 0` gate can strand a header" stays INFERRED. The hook is test-only and is not part of any patch here. |
| 2026-07-31 | 2.4.3 | writable import of the synthesised precondition, stock module | RULED OUT (no hang) | [S4] Finding 16, and the most consequential negative here. `zpool import -N` exit 0, pool ONLINE, no D-state, `dbgmsg` shows clean `LOADED`. Repeated from pristine restore. Absorption mechanism refined by finding 17 / claim 3.30: `traverse_zil_block()` skips an unclaimed chain before `spa_load_verify()` (`dmu_traverse.c:93-98`); `ZIO_FLAG_SPECULATIVE` (`zil.c:256-257`) and the `ECKSUM`/`ENOENT` swallow (`zil.c:1328`) are also real. Hole + dangling DVA is NOT sufficient to hang a writable import on 2.4.3. |
| 2026-07-31 | 2.4.3 | `zdb -R ziltest 2:20000:1000`, direct read against the hole vdev | CONFIRMED (fails fast) | [S4] Finding 16. Returns immediately; asserts inside `vdev_mirror_io_start()` at `vdev_mirror.c:616`. Corrects claim 4.9's cited mechanism (DVA reads dispatch to `vdev_mirror_ops`, not `vdev_missing_io_start()`) while confirming 4.9's conclusion that the read does not block. |
| 2026-07-31 | 2.4.3 | second import of the synthesised pool (claimed-chain variant) | ~~BLOCKED~~ superseded by `[S5]` below | [S4] Finding 16, as recorded at the time. Read as: always fails first with `label config unavailable` / `txg is too large`, an unexplained artifact, leaving the claimed-chain case untested and "the most promising open lead". All three parts of that were wrong and are corrected in the `[S5]` rows: it was not blocked, the label messages were not an artifact of the synthesis but a downstream consequence of an EIO in `spa_load_verify()`, and the variant has since been tested and does not hang. Row kept unedited above the strikethrough because this is a chronological log. |
| 2026-07-31 | 2.4.3 | housekeeping: raw captures and test apparatus archived | n/a | [S4] `/proc/<pid>/stack`, the hung-task `dmesg`, and both kernel panic traces saved verbatim to `evidence/2026-07-31-zfs-2.4.3-raw-captures.txt`. The debug hook saved to `patches/lab-only-skip-reset-logs.txt`, including a note that the scripted edit accidentally dropped `static` from the adjacent `zfs_removal_ignore_errors`. Guest kernel cmdline change (`console=hvc0`) documented in `ENVIRONMENT.md`. |
| 2026-07-31 | 2.4.3 | derive the claimed-chain state: restore the finding-16 precondition, `zpool import -N` once (claims the chain), `zpool export` | CONFIRMED: state produced | [S5] Finding 17. Verified on disk with `zdb -e -p ... -iiiii`: `claim_txg 37`, `claim_blk_seq 341`, `flags 0x2`, chain reads "already claimed", `DVA[0]=<2:15e6000:11000>`; `zdb -l` gives `hole_array[0]: 2`, `vdev_children: 3`, `txg: 51`. Archived inside the guest as `/root/CLAIMED-CHAIN-state.tgz` so the test is repeatable without re-deriving. Module md5 `20ca91a6a39fbe1a90cdea39feba95e5`, byte-identical to the archived stock module; the debug hook was not loaded for this or any later row. Evidence in `evidence/2026-07-31-claimed-chain-variant.txt`. |
| 2026-07-31 | 2.4.3 | writable import of the claimed-chain state, stock module | RULED OUT (no hang) | [S5] Finding 17, and the row that closes the last named lead. `cannot import 'ziltest': I/O error`, `EXIT=1`, and `ps -eo pid,stat,comm` shows no task in uninterruptible sleep. Fails fast; does not hang. Reproduced three times, twice from the archived state restored from scratch. Fails at `spa_load_verify()` with error=5 (EIO): dbgmsg `zio.c:1135:zfs_blkptr_verify_log(): ziltest: blkptr at ... DVA 0 has hole VDEV 2`. Mechanism source-confirmed at the `zfs-2.4.3` tag: `traverse_zil_block()` (`module/zfs/dmu_traverse.c:93-98`) returns -1 for an unclaimed chain and so hides the bad blkptr from verification, which is why finding 16's unclaimed variant imported cleanly; with `claim_txg != 0` the block is traversed and `zfs_blkptr_verify()` (`module/zfs/zio.c:1271`) rejects it. Bounded: `zfs-2.4.3` only. |
| 2026-07-31 | 2.4.3 | ftrace during the failing claimed-chain import: did `zil_check_log_chain()` block? | NOT REPRODUCED (it did not block) | [S5] Finding 17. `set_ftrace_filter` on `zil_check_log_chain zil_parse zil_claim spa_check_logs zfs_blkptr_verify`; after the import, `zil_check_log_chain` appears 4 times and `zil_parse` 3 times, and the load proceeded past both to "Verifying pool data". Machine-generated, not inferred from progress notes. `spa_check_logs` and `zfs_blkptr_verify` did not resolve as filter symbols on this build (inlined or static-folded) and are absent from the filter. |
| 2026-07-31 | 2.4.3 | read-only import of the claimed-chain state | RULED OUT (no hang), and a divergence from the incident | [S5] Finding 17. `zpool import -N -o readonly=on` also fails: `cannot import 'ziltest': I/O error`, `EXIT=1`. The affected pool imported read-only without complaint (`../CLAIMS.md` 1.1, OBSERVED). The claimed-chain state therefore fails both ways and is not a model of the incident; it is a third, distinct behaviour. |
| 2026-07-31 | 2.4.3 | recovery import of the claimed-chain state, `zpool import -N -F` | RULED OUT | [S5] Finding 17. `cannot import 'ziltest': one or more devices is currently unavailable`, `EXIT=1`. Recorded for completeness; `-F` does not change the outcome. |
| 2026-07-31 | tags 2.2.2 to master | release-tag grep: is the hole-vdev blkptr check newer than the incident's build? | DISPROVED | [S5] Finding 17. Hypothesis: if `zfs_blkptr_verify()`'s "has hole VDEV" check were newer than the incident's tree, its absence would explain why the incident hung where this fails fast. Each tag fetched from `github.com/openzfs/zfs` on 2026-07-31 and `module/zfs/zio.c` grepped for the format string. Present in every release checked: `zfs-2.2.2` (`zio.c:1113`), `zfs-2.3.3` (`:1290`, the incident's lineage), `zfs-2.3.4` (`:1290`), `zfs-2.4.1` (`:1271`), `zfs-2.4.3` (`:1271`), `master` (`:1266`). [partial artifact] the per-tag line numbers are transcribed into `evidence/2026-07-31-claimed-chain-variant.txt`; the raw `grep` output is not saved. |
| 2026-07-31 | 2.4.3 | recover the finding-14 hung-task trace from the systemd journal | CONFIRMED | [S5] `journalctl -b -5 -k` on guest `zfs243`; the journal is persistent across the forced power cycles, so the trace was never actually lost. Section 5 of the raw-captures file says the logs "were not retained"; that is true of the serial logs only. Gives (a) a machine-generated artifact for finding 14's hang, diffable against the transcription, and (b) machine-generated confirmation of `../CLAIMS.md` 2.2's "`txg_quiesce` NOT REPRODUCED on 2.4.3" (`txg_quiesce` appears nowhere in that boot's kernel log), which was previously supported only by a live `ps` reading. Appended as §6 of `evidence/2026-07-31-zfs-2.4.3-raw-captures.txt`. |
| 2026-07-31 | 2.4.3 | conclusion: the claimed-chain lead | CLOSED | [S5] Finding 17. Neither the claimed nor the unclaimed form of the synthesised precondition hangs a writable import on `zfs-2.4.3`. Supersedes claim 2.7's closing sentence and claim 4.9's "leading untested candidate" on both halves. The gap between the synthesis and the incident widens rather than closes. Remaining candidate differences (the incident's build (`zfs-2.3.3-107-gec5aa9bfd`), 140 T across many datasets, encrypted datasets, TrueNAS middleware and concurrent dataset operations, a genuinely failing device rather than a clean hole, and the space-map corruption on the same pool) are all untested, and none is favoured over any other. Not tested on 2.2.2, 2.3.4, 2.4.1 or the incident's build. |
