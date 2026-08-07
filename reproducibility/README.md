# Reproduction testing

The complete record of attempting to reproduce, on a clean system, the state
that the incident pool of 186 TB raw and 140 TB allocated was in when it
became unimportable, that state being a dataset ZIL header holding a non-zero
DVA whose vdev index resolves to a vdev that has become a `hole`.

That state has now been built, and on its own it is not enough. Finding 16
synthesised it in the test environment on `zfs-2.4.3` and verified it at DVA
level (`hole_array[0]: 2`, `DVA[0]=<2:15e6000:11000>`), then imported the pool
writable on a pristine stock module: exit 0, pool ONLINE, no D-state, clean
`LOADED` in `dbgmsg`, repeated from a pristine restore
(`evidence/2026-07-31-precondition-synthesis.txt`, the 07-31 `[S4]` rows of
`ATTEMPTS.md`, `../CLAIMS.md` 2.7). A hole plus a dangling DVA is not enough to
hang a writable import. The incident's stack (`../CLAIMS.md` 1.2) is OBSERVED
and is not in question; what is missing is at least one further ingredient,
which has not been identified.

Finding 17 closed the last named candidate. The claimed-chain variant was
tested the same day and it does not hang either. Importing the synthesised pool
once claims the chain (`claim_txg 37`, `flags 0x2`); re-importing that state
fails fast with `I/O error`, exit 1, no D-state, across three runs.
`zil_check_log_chain()` and `zil_parse()` were both observed by ftrace to run
and return. It fails later, at `spa_load_verify()`, because
`zfs_blkptr_verify()` rejects a blkptr naming a hole vdev (`../CLAIMS.md`
3.31). The "label artifact" that was thought to block the experiment was a
downstream symptom of that same EIO, not a blocker (`../CLAIMS.md` 3.32). See
`evidence/2026-07-31-claimed-chain-variant.txt`. There is now no favoured
candidate for the incident's missing ingredient.

The positive half of finding 16 matters too, with one qualification. Forcing
the `vs_alloc == 0` skip (`../CLAIMS.md` 3.8) with a test-only debug hook
strands dangling headers in one step, every time. So skipping the reset is
demonstrated to strand headers. The gate condition itself was not reproduced:
the hook fired with the log reporting `vs_alloc 22.0M`, whereas the real gate
fires only at `vs_alloc == 0`, and every natural route to zero clears the
headers first. What stays INFERRED is both whether the gate can reach a
strandable state at all and whether the incident took that route
(`../CLAIMS.md` 4.1). The hook is test-only and is not part of any patch here:
`patches/lab-only-skip-reset-logs.txt`.

Testing of the natural precondition routes is closed. Ten hypotheses were
enumerated across ZFS 2.2.2, 2.3.4, 2.4.1 and 2.4.3, of which seven were validly
executed. Hypothesis A (`02`) was never run at all; it was superseded by
`05` (the `02` NOT RUN row in `ATTEMPTS.md`), and hypothesis I (`08`) was run
only in an INVALID form. That probe used `zdb -i` against a live imported pool
and read 0 headers in all 12 rounds, and the fixed script was never re-run (the
`08` INVALID row in `ATTEMPTS.md`). None of it was on a TrueNAS-faithful
environment, and none of it on the incident's actual build
(`zfs-2.3.3-107-gec5aa9bfd`; the test environment built the `zfs-2.3.4` and
`zfs-2.4.3` release tags). See `../CONCLUSIONS.md` §3, "How closely the test
environment matched the incident environment", for the full fidelity gap. The
precondition was not reachable naturally by any route tried, and it was
classified as an anomaly of the hardware incident. That is a bounded negative,
not a proof of impossibility; see `../CLAIMS.md` 3.20. One adjacent bug, an
unkillable hang on log removal, was reproduced from scratch instead (findings 10
and 14).

A version-coverage hole was found and closed on 2026-07-31. None of the three
original test trees contains amotin's `1e1d64d`; it ships only in `zfs-2.4.3`,
which is also the tree the incident repair was built on. So the "2.4.x is
already hardened" hypothesis behind finding 13 had never actually been tested.
A fourth VM (`zfs243`) was built at commit `83020cf` and scripts `01`, `03`,
`04`, `06` and `07` were re-run there: all four precondition paths behave
identically, and the removal hang reproduces with a captured stack (finding 14,
`evidence/2026-07-31-zfs-2.4.3-test-results.txt`). Claim 4.5 is now DISPROVED
on proper grounds. `05`, the freeze route and the offline route were not re-run
there. See `../CLAIMS.md` 3.29.

The mechanism of the hang in the test environment is settled; the incident's is
not. `failmode` was varied at last (finding 15, the 07-31 `[S3]` rows of
`ATTEMPTS.md`). At `failmode=continue` the removal hang disappears
(`remove exit=0`, hole created, headers cleared), at `failmode=panic` the
kernel panics with `zio_suspend+0x1b0` in the trace, and at the default `wait`
it blocks forever while `spa_reset_logs()` holds `spa_namespace_lock`. The
ZIO's disposition is `zio_suspend()`, gated at `zio.c:5714-5720` on `ENXIO` +
`SPA_LOAD_NONE` + `failmode != continue`, and all three hold for a live-pool
removal. Claim 2.6 is therefore ESTABLISHED for the removal case. It does not
carry over to the incident, because that suspend cannot fire during an import:
`spa_load_state != SPA_LOAD_NONE`. On the incident hardware `failmode` could
not be reached during the load anyway (`../CLAIMS.md` 3.23-3.24). See
`../CLAIMS.md` 4.9.

`lib.sh` exposes the `FAILMODE` variable, which is applied by every script that
creates the scratch pool and echoed into `record_env`:

```bash
FAILMODE=continue sudo -E ./07-path-h-yank-live-log.sh
```

The default is `wait`, which is what every result in `ATTEMPTS.md` before the
07-31 `[S3]` rows was produced under. `continue` and `panic` have each
been run once, on 2.4.3 with `07` only (finding 15). Note the scope limit
recorded there: at `failmode=panic` a persistent-log re-run shows the panic
firing during the step-6 scrub provocation, before `zpool remove` is issued, so
it does not isolate the `zil_parse()` read.

Read `FINDINGS.md` before running anything. It records what has been
established and what is still open. Findings 16 and 17 are the ones to read if
you read only two, and 17 corrects three statements in 16.

---

## Safety

Seven of these scripts can leave the machine needing a hard reboot: the six
marked "risky" in the table below, plus `07`, which is marked "hangs".

A hung ZFS import or removal sits in uninterruptible sleep, so it cannot be
killed with any signal, it holds `spa_namespace_lock`, and it blocks every
subsequent `zfs` and `zpool` command including `modprobe -r zfs`. The only exit
is a forced power cycle.

- Run in a disposable VM. Never on a host with real pools attached.
- `01-verify-environment.sh` is safe and cannot hang, so start there.
- `07-path-h-yank-live-log.sh` is the dangerous one. It reliably wedges the VM
  at the default `failmode=wait`: it has done so on 2.2.2, 2.3.4 and 2.4.3
  (the `07` rows of 07-29, 07-30 and 07-31 in `ATTEMPTS.md`), each time
  needing `limactl stop --force`. At `FAILMODE=continue` it completes without
  hanging (the `[S3]` `FAILMODE` rows of 07-31). At `FAILMODE=panic` it
  panics the guest (the same rows).
- `03-` can also hang. It wraps the removal in `timeout 90`, which does not
  help if the thread is in D-state.
- `02-` has never been run at all (its NOT RUN row in `ATTEMPTS.md`). Treat it
  as untried code, not as a validated safe path.
- Recovery from a wedge: `limactl stop --force <vm> && limactl start <vm>`
  (VM names: `zfslab`, `zfs234`, `truenas-lab`, `zfs243`; see `ENVIRONMENT.md`)

---

## Files

| File | Safe? | Purpose |
|---|---|---|
| `ENVIRONMENT.md` | n/a | Exact steps to build the four test VMs |
| `FINDINGS.md` | n/a | What is confirmed, what is open |
| `ATTEMPTS.md` | n/a | Dated log of every attempt and its outcome |
| `evidence/` | n/a | Raw captured artifacts, verbatim |
| `patches/` | n/a | Candidate patches E and F, plus the test-only debug hook used in finding 16 |
| `lib.sh` | n/a | Shared helpers. Sourced, not run. |
| `01-verify-environment.sh` | yes | Proves findings 2 and 3. No hang risk. |
| `02-path-a-import-m.sh` | risky | Hypothesis A: lose the log, import `-m`. Never run; superseded by `05`, so A is ruled out by inheritance only. |
| `03-path-c-failed-log.sh` | risky | Hypothesis C: fail the log device, then remove it. Ruled out, see finding 5. |
| `04-path-d-unopenable-dataset.sh` | risky | Hypothesis D: encrypted dataset with key unloaded. Ruled out, finding 6. |
| `05-path-f-import-m-plus-unopenable.sh` | risky | Hypothesis F: `import -m` plus an unholdable dataset. Ruled out, findings 7 and 8. |
| `06-path-g-vs-alloc-zero.sh` | risky | Hypothesis G: wiped log so `vs_alloc == 0`. Confirms the gate, finding 9. |
| `07-path-h-yank-live-log.sh` | hangs | Hypothesis H: fail the log under a live pool. Reproduces the removal hang, findings 10 and 14. Wedges the VM at `failmode=wait`. |
| `08-path-i-vs-alloc-window.sh` | risky | Hypothesis I: race the `vs_alloc` window. Its only run was INVALID (probe bug, since fixed in the script but never re-run). See its row in `ATTEMPTS.md`. |
| `inspect.sh` | yes | Read-only precondition check against on-disk state. |
| `teardown.sh` | yes | Destroy scratch pool, clear injection, remove files. |

---

## Procedure

```bash
# 1. build the VM (see ENVIRONMENT.md for the full version-pinned steps)
limactl shell zfs243

# 2. verify the environment and the confirmed findings. Safe.
sudo ./01-verify-environment.sh

# 3. reproduce the removal hang. This WILL wedge the VM at the default
#    failmode=wait (findings 10, 14).
sudo ./07-path-h-yank-live-log.sh

# 3b. or run the same script with the hang suppressed (finding 15)
FAILMODE=continue sudo -E ./07-path-h-yank-live-log.sh

# 4. read the precondition gate it prints
sudo ./inspect.sh

# 5. clean up
sudo ./teardown.sh
```

---

## The precondition gate

Two conditions define the state that the incident pool was in:

- (a) a top-level vdev with `is_hole: 1`
- (b) at least one dataset whose `zh_log` DVA is non-zero

Condition (a) alone is harmless, because `zil_parse()` loops on
`!BP_IS_HOLE(&blk)`, so an all-zero DVA terminates the walk safely
(`../CLAIMS.md` 3.2). Condition (b) supplies a DVA that the walk will actually
follow.

The gate records the incident's state. It does not predict a hang. Finding 16
built exactly this state, confirmed the DVA resolves to the hole, and the
writable import completed cleanly on stock `zfs-2.4.3` (`../CLAIMS.md` 2.7).
Three mechanisms absorb an unclaimed chain. The one that keeps
`spa_load_verify()` off the bad blkptr is `traverse_zil_block()`
(`dmu_traverse.c:93-98`, `../CLAIMS.md` 3.30). `ZIO_FLAG_SPECULATIVE`
(`zil.c:256-257`) and the `ECKSUM`/`ENOENT` swallow at `zil.c:1328` are also
real. Passing the gate is a reason to record the state, not a reason to expect
a wedge.

`inspect.sh` checks both. If (b) fails, that route did not produce the state,
so record it in `ATTEMPTS.md` and try another. Note that `zdb -i` alone shows
only that `zh_log` is non-zero (`../CLAIMS.md` 3.15); establishing that
the DVA names the hole needs `zdb -iiiii`, as finding 16 did.

---

## Capturing a hang

Two different hangs are in play here and they must not be conflated.

### The removal-side hang: reproduces reliably

This is the one to run. `07-path-h-yank-live-log.sh` at the default
`failmode=wait` wedges `zpool remove` in D-state on 2.2.2, 2.3.4 and 2.4.3
(findings 10 and 14), and while it is stuck, from a second shell:

```bash
echo w > /proc/sysrq-trigger && dmesg | tail -80
ps -eo pid,stat,comm | awk '$2 ~ /D/'
sudo cat /proc/<pid>/stack
```

It is reproduced if the blocked stack reaches `zio_wait` through
`spa_vdev_remove` -> `spa_reset_logs` -> `zil_reset` -> `zil_suspend` ->
`zil_destroy` -> `zil_parse` -> `arc_read`. On 2.4.3 the `zil_read_log_block`,
`zil_destroy_sync` and `spa_vdev_remove_log` frames are inlined away, but the
chain is the same (`../CLAIMS.md` 2.1). `txg_quiesce` was wedged too on 2.2.2
but not on 2.4.3 (`../CLAIMS.md` 2.2, the 07-31 `[S2]` `txg_quiesce` row in
`ATTEMPTS.md`), so do not report the pool-wide stall without naming the version.
Reference captures are `evidence/2026-07-29-zil_parse-removal-hang-2.2.2.txt`
and `evidence/2026-07-31-zfs-2.4.3-raw-captures.txt`.

Recovery needs `limactl stop --force`.

### The import-side hang: not reproduced in the test environment

The incident hung on writable import in `spa_ld_verify_logs` ->
`spa_check_logs` -> `dmu_objset_find_dp` -> `zil_check_log_chain` ->
`zil_parse` -> `zil_read_log_block` -> `arc_read` -> `zio_wait` (`../CLAIMS.md`
1.2, OBSERVED). No run in the test environment has produced that stack,
including the one run that had the precondition in hand (finding 16). Do not
set up a writable import expecting to capture it. If you attempt the
claimed-chain variant or any other candidate ingredient, capture with the same
commands above, and additionally record `/proc/spl/kstat/zfs/import_progress`
and the `dbgmsg` tail; finding 16's negative rests on a clean `LOADED` line
there.

Whatever the outcome, save it to `evidence/` with the date and ZFS version, and
add a row to `ATTEMPTS.md` naming the version and the `failmode` used.

---

## Current status

Ten hypotheses were enumerated and seven validly executed (`02` never run,
hypothesis E not expressible without TrueNAS middleware, and `08` only in an
INVALID form), across ZFS 2.2.2, 2.3.4, 2.4.1 and 2.4.3, producing seventeen
findings (`FINDINGS.md`). Finding 18 came later, from a search for previous
upstream reports rather than from a run.

Finding 9 records the `vs_alloc == 0` gate on the ZIL reset.
`spa_vdev_remove_log()` gates the reset on
`if (vd->vdev_stat.vs_alloc != 0)` (`vdev_removal.c:2144`). A wiped, absent or
unreadable log reports 0, so `spa_reset_logs()` is skipped and no error is
returned, and the removal proceeds to create the hole. The gate is confirmed
empirically by `06` on 2.2.2, 2.3.4 and 2.4.3. That skipping the reset strands
headers is now shown, not merely inferred; that the gate itself can reach a
state with a header left to strand is not (the finding-16 hook fired at
`vs_alloc 22.0M`). That this gate stranded the incident pool stays INFERRED
(`../CLAIMS.md` 4.1). See finding 16 below.

Findings 10 and 14 record a separately reportable bug, reproduced from scratch
on stock 2.2.2, on a source build of the `zfs-2.3.4` tag, and on a source build
of `zfs-2.4.3`. "New" here means no prior report was located, not that novelty
is established. `zpool remove` of a log device that is failing under a live
pool hangs unkillably in `zil_parse` -> `arc_read` -> `zio_wait`. This is the
same blocking site as the incident's import-time hang, with a different caller
(`../CLAIMS.md` 2.4). Stacks were captured on 2.2.2
(`evidence/2026-07-29-zil_parse-removal-hang-2.2.2.txt`) and on 2.4.3
(`evidence/2026-07-31-zfs-2.4.3-test-results.txt`, finding 14, corroborated by
the kernel hung-task watchdog at 120 s). The 2.3.4 run captured no stack, a
120 s timeout only, so that version's frame is inferred from the other two.
`07-path-h-yank-live-log.sh` was never run on 2.4.1 (the version-coverage note
at the head of `ATTEMPTS.md`).

Finding 15 records the mechanism of that hang, established for the removal case
in the test environment. The ZIO's disposition is `zio_suspend()`, shown two
ways, plus a third that is suggestive only. The two are the `failmode`
`wait`-versus-`continue` contrast above, one variable with opposite outcomes
matching a prediction made in advance from source, and the source gate at
`zio.c:5714-5720`. The third, the captured `zio_suspend+0x1b0` panic trace,
does not isolate the `zil_parse()` read, because the panic fires during the
step-6 scrub provocation before `zpool remove` is issued. It shows the
disposition of uncorrectable I/O on that pool and no more (finding 15, caveat
1), and counting it as a third establishment overstates it. `../CLAIMS.md` 2.6
is ESTABLISHED for that case and UNKNOWN for the incident import. Also closed
here is that `SPA_LOG_CLEAR` does not survive export/import, which retires the
leading candidate for claim 1.13, though 1.13 itself stays UNKNOWN.

Finding 16 records the precondition synthesised, and the negative that follows
from it. There are two results in one run on `zfs-2.4.3`:

- *Positive.* Forcing the `vs_alloc == 0` skip with a test-only hook produced
  the state for the first time, verified at DVA level: `hole_array[0]: 2`,
  `is_hole: 1`, and `DVA[0]=<2:15e6000:11000>` on `ziltest/ds1`. Given the
  skip, headers strand every time. The qualification is that the hook fired at
  `vs_alloc 22.0M`, so what is demonstrated is that *skipping the reset*
  strands headers, not that the `vs_alloc == 0` gate can reach a state with
  a header left to strand (`../CLAIMS.md` 4.1).
- *Negative.* Importing that pool writable on a pristine stock module does not
  hang: exit 0, ONLINE, no D-state, clean `LOADED`, repeated from pristine
  restore. Hole plus dangling DVA is therefore not sufficient to hang a
  writable import on `zfs-2.4.3` (`../CLAIMS.md` 2.7). It also corrects
  `../CLAIMS.md` 4.9's cited mechanism: a read by DVA has `io_vd == NULL` and
  dispatches to `vdev_mirror_ops`, not to `vdev_missing_io_start()`, and
  `zdb -R ziltest 2:20000:1000` against the hole returns immediately, asserting
  in `vdev_mirror_io_start()` at `vdev_mirror.c:616`.

This is bounded, not universal, one state on one release, and it does not
overturn the incident (1.2 is OBSERVED), 3.1, 3.6 or the removal-side hang.
What it does is remove the assertion that this state alone explains defect 1.
At least one further ingredient is involved and has not been identified, and
candidates are listed in `FINDINGS.md` findings 16 and 17. The claimed-chain
variant led until finding 17 tested it and closed it, and no candidate is now
favoured over any other.

On `zil_parse()` itself, it is not missing an error path; it returns `int`,
handles a failed `zil_read_log_block()`, and warns via `cmn_err` when the chain
is claimed (`../CLAIMS.md` 2.5). What the error path
lacks is a caller that looks at it, because `zil_destroy_sync()` discards the
return with a `(void)` cast (`../CLAIMS.md` 3.21), which finding 15
demonstrated on demand at `failmode=continue`: silent exit 0, no `cmn_err`.

Ruled out as natural routes to the precondition: A and F (`import -m` clears
every header and leaves the log UNAVAIL, not a hole; A by inheritance from F,
never run itself), C (a failing log still gets reset), D (removal refused
outright), G (`vs_alloc == 0` reachable, but every natural route there clears
headers first), I (INVALID run, then redundant).

Route coverage is not uniform. What `ATTEMPTS.md` actually records:

- 2.2.2: at most seven routes (the 07-29 rows), and one of those,
  `08`, was INVALID. `01` was never run there, so the healthy-log removal route
  is not logged on 2.2.2, and neither is the freeze route.
- 2.4.1: at most five distinct routes (the 07-29 rows). The
  failing-log-under-a-live-pool route (`07`) was never run there.
- 2.3.4: the four precondition paths `01`, `03`, `04`, `06`, plus `07`
  (the 07-30 rows).
- 2.4.3: the same four precondition paths plus `07`
  (the 07-31 `[S2]` rows); `05`, the freeze route and the offline route were
  not run there.

No single version covers all nine routes of `FINDINGS.md` finding 12, so the
closure is a bounded negative over the routes tried, on the versions each was
tried on; see `../CLAIMS.md` 3.20.

The precondition is closed as a natural route and reopened as a
synthetic one. Producing a hole together with a surviving dangling header was
not reachable by any documented `zpool`/`zfs` sequence tried, and it remains
classified as an anomaly of the hardware incident (`../CONCLUSIONS.md` §3). It
was reachable after all with a test-only debug hook (finding 16), and the state
so produced does not hang a writable import on 2.4.3.

See `ATTEMPTS.md` for the full run log and `FINDINGS.md` for the analysis.
