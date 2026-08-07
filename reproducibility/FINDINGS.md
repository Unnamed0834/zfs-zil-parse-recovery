# Reproduction findings

> This is a chronological notebook of the reproduction work. Findings are
> numbered in the order they were established, and later ones supersede earlier
> ones. Finding 1's framing was corrected by finding 9, finding 13's premise was
> corrected by finding 14, and the overall conclusion is finding 12 as amended
> by 14, 16 and 17. Findings 16 and 17 are the ones to read if you read only
> two, and 17 corrects three separate statements in 16. Later findings revise
> earlier ones. The settled position
> is in [`../CONCLUSIONS.md`](../CONCLUSIONS.md).
>
> Several section headings below announce closure ("Testing is complete", "the
> enumeration is complete", "What could not be tested"). Each is true as of the
> point in the notebook where it appears and each was later reopened. Forward
> pointers are inserted at every one of them.

Empirical results from attempting to reproduce the hole-vdev ZIL hang
synthetically. Recorded because one of them changes how the bug should be
reported. Eighteen findings, seventeen of them from testing across four ZFS
versions (2.2.2, 2.3.4, 2.4.1 and 2.4.3) and the eighteenth from a search for
previous upstream reports.


The test environment for findings 1 to 11 was as follows.

Four VMs were used across this notebook, not one. The table below is the
first of them and applies to findings 1 to 11 only. Findings 13, 14, 15, 16 and
17 ran on other guests and other ZFS versions, each named in its own section.
The full matrix is in [`ENVIRONMENT.md`](ENVIRONMENT.md). Do not attribute a
later finding to the VM below.

| | |
|---|---|
| Host | Apple Silicon (arm64), macOS 26.5.2, Lima 2.2.0 with Apple Virtualization.framework |
| Guest | Ubuntu 26.04 LTS, kernel `7.0.0-28-generic`, aarch64 |
| ZFS | `2.4.1-1ubuntu5` (`zfs-kmod-2.4.1-1ubuntu5`), stock distro build |

ZFS 2.4.1 is two point releases below the `zfs-2.4.3` tag the repair was built
against (2.4.2 sits between them). The affected code has been diffed only
between `zfs-2.4.3` and `master` (`../CLAIMS.md` 3.27 and §7); 2.4.1 was not
included in that comparison, so treat "the affected code is unchanged" as
checked for 2.4.3-vs-master and untested for 2.4.1. The defect is pure control
flow, so aarch64 is a valid platform to demonstrate it on.

---

## Finding 1: log-vdev removal explicitly resets every dataset ZIL

This is the important one.

`zpool remove <pool> <logdev>` was issued against a frozen pool. It blocked in
D-state. The stack:

```
zpool remove t2 /var/tmp/t2/slog

[<0>] cv_wait_common+0x1c0/0x230        [spl]
[<0>] __cv_wait+0x24/0x58               [spl]
[<0>] zil_commit_impl+0x298/0x13a0      [zfs]
[<0>] zil_suspend+0x160/0x408           [zfs]
[<0>] zil_reset+0x20/0xd8               [zfs]
[<0>] dmu_objset_find_impl+0x108/0x350  [zfs]
[<0>] dmu_objset_find+0x80/0xf0         [zfs]
[<0>] spa_reset_logs+0x38/0xb8          [zfs]
[<0>] spa_vdev_remove+0x608/0x940       [zfs]
[<0>] zfs_ioc_vdev_remove+0x6c/0xf0     [zfs]
[<0>] zfsdev_ioctl_common+0x820/0x8f0   [zfs]
```

So `spa_vdev_remove()` calls `spa_reset_logs()`, which walks every dataset via
`dmu_objset_find()` and performs `zil_reset` then `zil_suspend` then
`zil_commit_impl` on each one. What that walk does, when it completes, is
to flush and clear every dataset's ZIL header before the vdev becomes a hole.
That is why removing a healthy log device leaves no dangling references.

> Scope. The ordering above is not general: finding 9 shows the reset does
> not run at all when the log reports `vs_alloc == 0`, and the removal still
> creates the hole. The capture behind this finding was taken against a
> frozen pool that deadlocked mid-walk, so it shows the call path is
> entered. It does not show the walk completing for every dataset. See
> `../CLAIMS.md` 3.7.

### Why this reframes the bug

The dangling reference on the affected pool is consistent with
`spa_reset_logs()` not achieving its goal for at least one dataset while the
removal proceeded anyway. On that pool the log SSDs were flickering between
available and unavailable, so a per-dataset `zil_commit_impl()` against a dying
device would have failed rather than completed. How the pool actually reached
its state is tiered UNKNOWN (`../CLAIMS.md` 4.2); "consistent with" is what
the evidence supports.

Patch A (the `vdev_ishole` guard) was written to make that state survivable.
Note the correction in `../CLAIMS.md` 1.12: the form that ran on the incident
hardware does not achieve it, because it delegates to `vdev_log_state_valid()`,
which returns `B_TRUE` for a hole. The corrected form in
`../incident/patches/README.md` has never been built or run.

> Superseded by finding 9. This finding originally concluded that
> `spa_vdev_remove()` "is not atomic with respect to ZIL cleanup", and called
> that the root cause. Reading `vdev_removal.c` later showed that is wrong. The
> removal aborts cleanly when the reset returns an error:
>
> ```c
> if (vd->vdev_stat.vs_alloc != 0)
>         error = spa_reset_logs(spa);
> *txg = spa_vdev_config_enter(spa);
> if (error != 0) {
>         metaslab_group_activate(mg);
>         return (error);
> }
> ```
>
> So it is atomic with respect to the vdev config. The actual gap is that the
> reset is skipped entirely when `vs_alloc == 0`, returning no error at all
> (finding 9). A separate and much smaller non-atomicity was observed on 2.2.2,
> where a reset cleared one dataset's header before aborting on another, but
> that leaves the config unchanged and does not produce the defect.
>
> The blocking site as finally understood is inside `zil_parse()`, at
> `arc_read()` -> `zio_wait()` (finding 10 and `../CONCLUSIONS.md` §2). Note
> that this is a location, not a root cause; see the correction at the head
> of finding 10.

---

## Finding 2: `zpool freeze` is available on the stock builds tested

A draft note once warned that `zpool freeze` might require a
debug build. It does not. It was available on all three builds where
`01-verify-environment.sh` was run: the stock Ubuntu `zfsutils-linux` package
`2.4.1-1ubuntu5`, and source builds of the `zfs-2.3.4` and `zfs-2.4.3` tags.
No debug build was needed on any of them. Availability on 2.2.2 is UNTESTED
(`ATTEMPTS.md` has no `01` row for 2.2.2). No other distribution, packaging or
build configuration was checked.

---

## Finding 3: removing a log vdev reproduces the config signature, but not identically

On a scratch pool, `zpool remove` of the log produced:

```
hole_array[0]: 1
vdev_children: 2
    type: 'root'
        type: 'file'
        type: 'hole'
        is_hole: 1
```

This matches the affected pool's signature in kind but not in detail
(`hole_array[0]: 2`, `vdev_children: 3`, `children[2]` a hole), differing in the
index and the child count because that pool had two raidz2 vdevs plus the log.
Producing the hole is not the hard part.


---

## Finding 4: freeze plus remove deadlocks, so freeze is the wrong lever

Because `spa_vdev_remove()` needs `zil_commit_impl()` to complete, and a frozen
pool cannot sync a transaction group, the two cannot be combined. The removal
blocks forever and the pool is unrecoverable without a hard reboot.

This invalidates the original "freeze, then remove" approach. The log device
must fail, not merely be frozen out of syncing.

## Finding 5: `spa_reset_logs()` clears ZIL headers even against a log device whose I/O is failed by `zinject`

Hypothesis C tested directly: pool live and unfrozen, `sync=always`, 942 ZIL
records committed to the log device, then 100 % unconditional I/O errors
injected on that device, then more writes, then `zpool remove` of the log.

```
zinject -d /var/tmp/ziltest/slog -e io -T all ziltest
  ID  POOL     GUID              TYPE  ERROR  FREQ        MATCH  INJECT
   1  ziltest  15191fd0d42a4a2f  all   io     100.0000%       0       0

zpool remove ziltest /var/tmp/ziltest/slog
  remove exit=0
```

Result:

- The removal succeeded despite every log I/O failing.
- The hole was created: `hole_array[0]: 2`, `vdev_children: 3`, `is_hole: 1`.
- `errors: 180 data errors` were reported, so the ZIL contents were genuinely
  lost. `zpool status -v` lists the class of error but resolves no filenames.
- Every dataset's `zh_log` was nevertheless cleared. `zdb -i` printed no
  `ZIL header:` line for `ziltest`, `ziltest/ds1` or `mos`.

Hypothesis C is RULED OUT *for `zinject`-simulated errors.* Against a log
whose I/O is failed by `zinject -e io`, `spa_reset_logs()` completes: it loses
the data, reports the loss, and still leaves no dangling DVA. That is not a
general claim that the function is robust when it cannot commit. With a real
dm `error` target underneath the log (`07-path-h-yank-live-log.sh`) the same
function hangs forever in `zil_parse()` -> `arc_read()` -> `zio_wait()`
(finding 10, stacks on 2.2.2 and 2.4.3). `zinject` versus a real error target
is the distinguishing variable; see the split of route 2 in finding 12.

This narrows the search considerably and makes the affected pool's state more
anomalous rather than less. A simple failing log device does not produce it.

### Correction to the inspection method

The first version of the precondition gate used
`zdb -dddd <dataset> | grep -i 'zh_log|ZIL header'`. That is wrong: `-dddd`
never prints the ZIL header, so the check silently returned "(none reported)"
for every dataset regardless of the true state.

The correct probe is `zdb -i <pool>`. zdb's `dump_intent_log()` returns early
when `BP_IS_HOLE(&zh->zh_log)`, so a `ZIL header:` line appears only when
`zh_log` is non-zero. Presence of that line is exactly the bug condition;
absence is a clean negative. `lib.sh` now uses this.

`zdb -i` is also a far safer probe than a writable import, since it reads the
chain without taking the pool writable and without risking an unkillable hang.

---

## Remaining candidates

Neither a clean removal nor a failed-device removal produces the state. What
remains, both drawn from the affected pool's own `zpool history`:

```
2026-07-19.22:42:44  zpool import 211359596362856278 -R /mnt -m -N -f
2026-07-19.22:45:33  zfs set ... storage/.ix-virt
2026-07-19.22:48:05  zfs set mountpoint=legacy storage/.ix-virt/deleted
2026-07-19.22:57:28  py-libzfs: zpool remove storageNone
2026-07-19.22:57:28  zfs set mountpoint=legacy storage/.ix-virt/buckets
```

Candidate D: a dataset that could not be opened during the claim or reset.
Both `spa_reset_logs()` and the `SPA_LOG_CLEAR` path in `zil_claim()` reach
datasets via `dmu_objset_find()`. A dataset that cannot be held would be
skipped, and its header would survive. The cleanest way to force that condition
is an encrypted dataset with its key unloaded, where `dmu_objset_hold()`
fails. Note `zil_claim()` already carries an `os->os_encrypted` special case,
so encryption demonstrably interacts with this path. The affected pool had
`.ix-virt` container datasets and `.system` datasets being reconfigured to
`mountpoint=legacy` in the same minutes as the removal.

If an unopenable dataset does leave a permanently dangling ZIL header, that is
a reportable bug in its own right, independent of the hole.

Candidate "malformed-remove" (formerly "Candidate E"): the malformed removal
call. `py-libzfs: zpool remove storageNone` appears to be middleware passing a
null vdev argument, and it is timestamped to the same second as one of the
`zfs set` operations. Worth checking whether that form takes a different path
through `spa_vdev_remove()` than a well-formed removal, and whether concurrent
dataset property changes can race `spa_reset_logs()`.

---

## Finding 6: ZFS refuses log removal when an *encrypted* dataset's ZIL cannot be replayed

Hypothesis D: pool with an encrypted dataset, key unloaded so
`dmu_objset_hold()` cannot hold it, then remove the log vdev.

```
zpool remove ziltest /var/tmp/ziltest/slog
cannot remove /var/tmp/ziltest/slog: Mount encrypted datasets to replay logs.
  remove exit=1
```

The removal was refused, no hole was created, and the log vdev stayed
ONLINE. This is a purpose-built guard, not an accident.

Hypothesis D is RULED OUT for this trigger. Exactly one trigger was tested:
an encrypted dataset with its key unloaded, which hits a purpose-built
encryption pre-check ("Mount encrypted datasets to replay logs"). The general
"unholdable dataset" case is UNTESTED. Log removal therefore has at least two
independent protections on the paths tested: `spa_reset_logs()` (finding 1,
finding 5) and this replay guard. The affected pool defeated both, which makes
its state genuinely unusual rather than a routine consequence of losing a SLOG.

---

## Finding 7: `zpool import -m` does NOT create a hole

An important correction. `-m` leaves the log vdev in the config as UNAVAIL,
not as a hole:

```
config:
	NAME                   STATE     READ WRITE CKSUM
	ziltest                DEGRADED     0     0     0
	  /var/tmp/ziltest/d1  ONLINE       0     0     0
	  /var/tmp/ziltest/d2  ONLINE       0     0     0
	logs
	  1895311285411255773  UNAVAIL      0     0     0  was /var/tmp/ziltest/slog
```

The vdev tree still showed three `type: 'file'` children and no `is_hole`.

Consequence: among the routes tried, only `zpool remove` produced a hole
(`../CLAIMS.md` 3.10, PARTIALLY TESTED; 3.20). Any reproduction must go through
a removal, and every removal path tested so far either clears the headers or
refuses outright.

---

## Finding 8: the `SPA_LOG_CLEAR` path clears headers, including a dataset whose encryption key is unavailable

Hypothesis F, the synthesis of A and D: live ZIL chains on both a plaintext and
an encrypted dataset, key unloaded, log backing file deleted before export
(so the export could not flush), then `zpool import -m`.

Before the `-m` import, the gate passed. All three datasets had a non-zero
`zh_log`:

```
Dataset ziltest/plain ... ZIL header: claim_txg 0, ...
Dataset ziltest/enc   ... ZIL header: claim_txg 0, ...
Dataset ziltest       ... ZIL header: claim_txg 0, ...
```

After the `-m` import, every header was cleared, including
`ziltest/enc` whose key was unavailable:

```
Dataset ziltest/plain ...          (no ZIL header line)
Dataset ziltest/enc   ...          (no ZIL header line)
Dataset ziltest       ...          (no ZIL header line)
```

Hypothesis F is RULED OUT. The premise that a dataset whose encryption key
is unavailable is skipped by the `SPA_LOG_CLEAR` path in `zil_claim()` is
false, at least on 2.4.1.

### How to read `zdb -i`

The presence of a `ZIL header:` line is itself the signal that `zh_log` is
non-zero. `cmd/zdb/zdb_il.c`:

```c
dump_intent_log(zilog_t *zilog)
{
	const zil_header_t *zh = zilog->zl_header;
	int verbose = MAX(dump_opt['d'], dump_opt['i']);

	if (BP_IS_HOLE(&zh->zh_log) || verbose < 1)
		return;

	(void) printf("\n    ZIL header: claim_txg %llu, ...
```

The function returns early when `zh_log` is a hole, so the presence of the
`ZIL header:` line is itself the signal that `zh_log` is non-zero. The
`claim_txg` / `claim_blk_seq` / `claim_lr_seq` values printed on that line are
claim state, which is legitimately zero until `zil_claim()` runs at import.
Reading those zeros as "empty header" is the mistake. The gate in `lib.sh` is
correct as written.

> This is the repository's detection method, not an incidental note. It is
> recorded here because that is where it was found, but its importance is
> larger than finding 8. It gives a read-only, non-wedging probe for the bug
> state. That is what made ten hypotheses gradable without a forced power cycle
> for each attempt. Every "all headers cleared" negative in this repository
> depends on it. It is implemented as `inspect_precondition()` in
> [`lib.sh`](lib.sh) and exposed as [`inspect.sh`](inspect.sh). See
> `../CLAIMS.md` 3.15.
>
> One calibration run backs it, and that run has no artifact. A hard power
> cut with 19,112 ZIL records in flight was used to confirm the gate detects a
> genuine dirty header (`ATTEMPTS.md`, 2026-07-29). Nothing was saved but
> the log row. If that gate does not detect what the row says it detected, the
> negatives above are unsupported. Re-run it with output captured.

---

## Status at this point in the notebook: four paths ruled out, and a version hypothesis

*Chronological snapshot. Superseded by finding 12's full enumeration.*

| Path | Mechanism | Result |
|---|---|---|
| A / F | `import -m`, missing log | Clears all headers; leaves UNAVAIL, not a hole (f7, f8) |
| C | Log device returning 100 % I/O errors, then remove | Creates the hole, still clears all headers (f5) |
| D | Unholdable (encrypted, no key) dataset, then remove | Removal refused outright (f6) |

Only `zpool remove` creates a hole, and every removal path tested *so far at
this point in the notebook* either clears the headers or refuses. On ZFS 2.4.1
the state was not reached by the sequences tried up to here (`03`, `04`, `05`,
plus manual freeze and healthy-removal); `06`, `07`, offline and
import-without-`-m` were not yet run on 2.4.1. Bounded negative only. The
per-version matrix is under finding 12. The state was later produced
artificially via a test-only debug hook (finding 16), not by a natural
sequence.

### The version hypothesis, and why it is now the priority

*Written on 2026-07-29. The premise in this section is false, and the
correction is at the head of finding 13. Left in place because the hypothesis
drove the 2.3.4 work.*

All of this testing has been on 2.4.1. The affected pool was damaged while
running TrueNAS SCALE 25.10.4, which ships ZFS 2.3.4.

amotin's log-removal work (`1e1d64d`, adding the `BP_IS_HOLE(&zh->zh_log)` early
return in `zil_claim()` and the matching handling in `zil_destroy()`) first
ships in `zfs-2.4.3` (`../CLAIMS.md` 3.29). It is absent from 2.4.1 and from
2.3.4, so a 2.3.4-versus-2.4.1 comparison cannot test hardening by that
change. (The hypothesis that 2.4.x is already hardened is later DISPROVED on
`zfs-2.4.3` in finding 14.)

This reframes the remaining work: stop searching for a more elaborate sequence
on 2.4.1 and instead reproduce on 2.3.4, the version where the damage
actually occurred. Ubuntu 26.04 ships 2.4.1, so this means building
`zfs-2.3.4` from source in the VM, or finding a distro image that ships it.

### Remaining non-version candidate

The malformed `py-libzfs: zpool remove storageNone` call, timestamped
`2026-07-19.22:57:28`, the same second as a concurrent
`zfs set mountpoint=legacy` on a sibling dataset. Worth testing whether a
removal racing concurrent dataset property changes can slip past
`spa_reset_logs()`.

---

## Finding 9: the ZIL reset is conditional on `vs_alloc`

The gate exists and is confirmed from source and from three test runs. That it
produced the incident's state is INFERRED (`../CLAIMS.md` 4.1). The debug hook
in finding 16 forced the skip with the log at `vs_alloc 22.0M`; the real gate
fires only at zero, and every natural route to zero clears the headers first.
A `vs_alloc == 0` state with a header still left to strand has never been
produced.

Found by reading source rather than guessing, after five hypotheses had been
ruled out empirically. `module/zfs/vdev_removal.c`, `spa_vdev_remove_log()`:

```c
	/*
	 * Evacuate the device.  We don't hold the config lock as
	 * writer since we need to do I/O but we do keep the
	 * spa_namespace_lock held.  Once this completes the device
	 * should no longer have any blocks allocated on it.
	 */
	ASSERT(spa_namespace_held());
	if (vd->vdev_stat.vs_alloc != 0)
		error = spa_reset_logs(spa);

	*txg = spa_vdev_config_enter(spa);

	if (error != 0) {
		metaslab_group_activate(mg);
		ASSERT0P(vd->vdev_log_mg);
		return (error);
	}
```

`spa_reset_logs()`, the function that clears every dataset's ZIL header before
the log vdev becomes a hole, runs only if the log vdev reports allocated
space. When `vs_alloc == 0` the reset is skipped, `error` stays 0, and the
removal proceeds to create the hole. Any dataset holding a non-zero `zh_log`
keeps a dangling reference.

A wiped, absent or unreadable log device reports `vs_alloc == 0`. The affected
pool's SLOG SSDs were cleared with `labelclear` and `wipefs` before the
removal. Read that as a sequence, not as a demonstrated cause. No test run
reached `vs_alloc == 0` while a dataset still held a non-zero `zh_log`. See
`../CLAIMS.md` 4.1.

### Confirmed empirically

`06-path-g-vs-alloc-zero.sh` on ZFS 2.2.2. Before wiping:

```
        /var/tmp/ziltest/slog   512M  45.2M   435M   ...  ONLINE
```

After wiping and importing:

```
        14469244995311865264   512M      0   480M   ...  UNAVAIL
                                      ^^^^ vs_alloc == 0
```

`zpool remove` then returned exit 0 and created the hole
(`hole_array[0]: 2`, `is_hole: 1`), with no reset possible on an unreadable
device. The gate behaves exactly as the source says.

That run did not strand a dangling header, but only because reaching the
`vs_alloc == 0` state required an `import -m`, which clears every header via
`SPA_LOG_CLEAR` (finding 8). The removal skipping the reset is confirmed; the
combination needs the log to fail without an intervening import, which is what
finding 10 addresses.

---

## Finding 10: `zpool remove` of a failing log device hangs unkillably

A separately reportable defect, reproduced from scratch on stock ZFS 2.2.2.
No patched module, no unusual hardware. On novelty: no existing OpenZFS issue
describing the hang on the removal path was located, but the tracker search
behind that statement is not recorded here. Read "new" as "no prior report
found", not as established.

`07-path-h-yank-live-log.sh` backs the log with `file -> loop -> dm-linear`,
drives synchronous writes so the ZIL chain is live, unmounts the dataset so its
header cannot drain, then swaps the dm table to an `error` target so the device
fails without exporting the pool. The subsequent `zpool remove` never
returns:

```
$ sudo tr '\0' ' ' < /proc/10725/cmdline
zpool remove ziltest slogdev

$ sudo cat /proc/10725/stack
[<0>] zio_wait+0x124/0x278            [zfs]
[<0>] arc_read+0xc24/0x13a8           [zfs]
[<0>] zil_read_log_block+0xcc/0x318   [zfs]
[<0>] zil_parse+0x188/0x388           [zfs]
[<0>] zil_destroy_sync+0x3c/0x78      [zfs]
[<0>] zil_destroy+0x21c/0x270         [zfs]
[<0>] zil_suspend+0x184/0x3e0         [zfs]
[<0>] zil_reset+0x24/0xd8             [zfs]
[<0>] dmu_objset_find+0x84/0xf8       [zfs]
[<0>] spa_reset_logs+0x38/0xb0        [zfs]
[<0>] spa_vdev_remove_log+0x1b8/0x218 [zfs]
[<0>] spa_vdev_remove+0x1c0/0x528     [zfs]
```

`txg_quiesce` wedged alongside it, so the whole pool stalled, not just the
removal. The VM needed a forced power cycle.

This is the same defect class as the import-time hang that made the
affected pool unimportable, in a different code path:

| | path into `zil_parse` |
|---|---|
| import time | `zil_check_log_chain` -> `zil_parse` -> `arc_read` -> `zio_wait` |
| removal time | `zil_destroy_sync` -> `zil_parse` -> `arc_read` -> `zio_wait` |

In both cases `zil_parse()` issues reads for ZIL blocks that cannot be served
and blocks in `zio_wait()`.

### `zil_parse()` is not missing an error path

From `module/zfs/zil.c` (checked against `zfs-2.3.4` and `master`),
`zil_parse()` returns `int`, and inside the chain walk:

```c
error = zil_read_log_block(zilog, decrypt, &blk, &next_blk, &lrp, &end, &abuf);
if (error != 0) {
        if (abuf)
                arc_buf_destroy(abuf, &abuf);
        if (claimed) {
                char name[ZFS_MAX_DATASET_NAME_LEN];
                dmu_objset_name(zilog->zl_os, name);
                cmn_err(CE_WARN, "ZFS read log block error %d, "
                    "dataset %s, seq 0x%llx\n", error, name,
                    (u_longlong_t)blk_seq);
        }
        break;
}
```

The error path exists. It is never reached, because `zio_wait()` never returns
and so no error is ever produced.

Why the ZIO never completes: for the removal case in the test environment,
finding 15 settled it. Pool `failmode` is the lever: default `wait` suspends
I/O rather than returning `EIO`, and `spa_reset_logs()` holds
`spa_namespace_lock` throughout, so nothing can clear the suspension. Varied
one at a time on `zfs-2.4.3` with script `07`: `continue` removes the hang,
`panic` panics, `wait` hangs. ESTABLISHED for the removal case; UNKNOWN for
the incident import (`../CLAIMS.md` 2.6).

Two separate statements, and they must not be collapsed:

- On the incident hardware, `failmode` could not be reached during the
  load. `zpool set` needs an imported pool; `zpool import -o failmode=` is
  applied by `spa_prop_set()` at `spa.c:7432`, after `spa_load_best()` returns
  at `spa.c:7401`, while the hang is inside it; and the value in effect during
  load is the on-disk one (`spa.c:5421`). ZFS's automatic override, which
  forces `failmode=continue` when top-level vdevs are missing (`spa.c:5435`),
  does not fire either, because a hole opens HEALTHY and is never counted in
  `spa_missing_tvds` (`vdev_root.c:102`). Line numbers are against `zfs-2.4.3`;
  see `../CLAIMS.md` 3.23 to 3.26 and §7. The accompanying report that the
  setting was attempted on the hardware and refused is first-hand testimony
  with no captured artifact; the source reasoning stands without it.
- In the test environment the pool is created with
  `-o failmode="$FAILMODE"`, so the setting is under harness control from
  creation. Finding 15 is the experiment above.

The question is sharper than it looks. On a plain reading of the source
this read should not block at all:

| Step | Source | Consequence |
|---|---|---|
| `vdev_hole_ops` uses `vdev_missing_io_start()` | `vdev_missing.c:73`, ops table at `:132` | sets `io_error = ENOTSUP` and calls `zio_execute()` immediately; no blocking at the device |
| `zil_read_log_block()` passes `ZIO_FLAG_CANFAIL` | `zil.c:251` | disarms the catch-all suspend at `zio.c:5722-5724`, which is gated on `!CANFAIL` rather than unconditional |
| failmode-sensitive suspend needs `ENXIO` and `spa_load_state == SPA_LOAD_NONE` | `zio.c:5714-5720` | during an import neither holds: the error is `ENOTSUP` and the load state is not `NONE` |

(Line numbers against `zfs-2.4.3`, commit `83020cf`; `../CLAIMS.md` §7 gives
the `master` equivalents.)

That chain would end in `zil_parse()` receiving `ENOTSUP` and a clean import
failure, not a hang. The table names the wrong entry point: a read by DVA
dispatches to `vdev_mirror_ops`, not to the hole's own ops (finding 16). The
read does fail fast on the synthesised pool; finding 17 shows what happens
next for a claimed chain. See `../CLAIMS.md` 4.9.

This matters for what can be reported. The hang is reproducible. The mechanism
is established for the removal caller (finding 15) and is not
established for the import caller. Do not propose a fix that assumes one
mechanism covers both. The harness supports the experiment directly:

```bash
FAILMODE=continue sudo -E ./07-path-h-yank-live-log.sh
```

`lib.sh` defaults `FAILMODE` to `wait`. Finding 15 ran `continue` and `panic`
once each on `zfs-2.4.3` with script `07` only. No other script or version has
been run at any setting other than `wait`.

---

## The coherent bug report

Findings 9 and 10 together describe a single defect with two outcomes, and
neither has a clean error path:

```
if (vd->vdev_stat.vs_alloc != 0)
        error = spa_reset_logs(spa);
```

- `vs_alloc != 0` and the device is failing. `spa_reset_logs()` runs,
  reaches `zil_parse()`, and hangs forever. The machine needs a power cycle
  (finding 10, reproduced). State the version when you report this. On 2.2.2
  the whole pool stalls, because `txg_quiesce` is wedged too. On `zfs-2.4.3`
  only the `zpool` process is in D-state and `txg_quiesce` is not wedged
  (finding 14, `../CLAIMS.md` 2.2). Every `zpool` command blocks on both
  versions, because the wedged task holds `spa_namespace_lock`.
- `vs_alloc == 0`, because the device was wiped, replaced or is absent.
  The reset is skipped silently, the removal succeeds, and any dataset with a
  non-zero `zh_log` is left pointing into the hole the removal just created
  (finding 9). On stock `zfs-2.4.3` that state does not hang an import:
  unclaimed imports cleanly (finding 16); claimed fails fast with EIO at
  `spa_load_verify()` (finding 17). What hangs on that stack is the incident
  pool, OBSERVED once, on a build not tested here.

So losing a SLOG in the wrong way gives an unkillable hang on the removal path.
The synthesised dangling-header state is not a silently unimportable pool on
`zfs-2.4.3`.

What this work suggests a fix would have to cover. This list is the
author's reading. It is not a specification for anyone else.

1. Establish why the read never completes, so that `zil_parse()`'s existing
   error path is actually reached. Answered for the removal caller by finding
   15: the ZIO's disposition is `zio_suspend()` under the default
   `failmode=wait`. Still open for the import caller, where the synthesised
   state does not hang (findings 16 and 17). Note `../CLAIMS.md` 4.9,
   whose cited mechanism was wrong and whose conclusion, that the read fails
   fast, is now confirmed empirically.
2. Do not skip the reset merely because `vs_alloc` reads 0. Either the headers
   must be verified clear, or the removal must refuse. (Patch E.) Caveat,
   restated as a possibility rather than a prediction: on the runs recorded
   here a reset against a real failing log hangs (finding 10), so removing the
   `vs_alloc` gate could route some failing-log removals into that hang
   instead of past it. That interaction has not been built or measured. Asserting as fact that
   "doing this sends failing-log removals into the hang" would be unwarranted.
3. Guard `zil_check_log_chain()` against `vdev_ishole` (Patch A) so pools
   already in this state can be imported instead of hanging. The guard must
   set `valid = B_FALSE` directly. Extending the predicate and delegating to
   `vdev_log_state_valid()` does nothing, because that function returns
   `B_TRUE` for a hole, which is the mistake the incident patch made
   (`../CLAIMS.md` 1.12).
4. Once (1) is answered, propagate the resulting error out of
   `zil_destroy_sync()` so a removal can fail cleanly rather than proceeding.
   (Patch F.)

Item 3 is the only one of the four written as a complete diff. It is
source-only: the form that ran on the incident hardware was inert, and the
corrected form has never been built or run. Item 1 is the most important and
the least done.

---

## Finding 11: `zpool offline` on a log vdev drives `vs_alloc` to 0, and drains the ZIL doing it

The last plausible route to the `vs_alloc == 0` gate without an export.

`zpool offline` on a log device is permitted:

```
$ zpool offline ziltest /var/tmp/ziltest/slog
  offline rc=0

	logs
	  /var/tmp/ziltest/slog  OFFLINE      0     0     0
```

and it drops the log's allocation to zero:

```
before:  vs_alloc=35528704
after:   /var/tmp/ziltest/slog  536870912  0  503316480  ...  OFFLINE
                                           ^ vs_alloc == 0
```

`zpool remove` then returned 0 and created the hole, confirming the reset was
skipped:

```
hole_array[0]: 2
vdev_children: 3
    type: 'root'
        type: 'file'
        type: 'file'
        type: 'hole'
        is_hole: 1
```

But every `zh_log` was cleared. Offlining the log drains the ZIL as part of
taking the device out of service, so by the time `vs_alloc` reads 0 there is
nothing left to strand. Bounded to the single 2.2.2 run logged (prose only in
`ATTEMPTS.md`, no `evidence/` file); not re-run on 2.4.1, 2.3.4 or 2.4.3.
Whether the drain is guaranteed by design, or holds under a failing device,
was not established.

---

### Version bound: `520eeeaa6` on `master`

`520eeeaa6` ("Improve performance of `zpool offline` for log devices", Alan
Somers, 2026-06-24, closes #18664) changes the behaviour this finding describes.
It post-dates `zfs-2.4.3` and every other tree tested here, so nothing recorded
above is invalidated. What changes is that the finding must not be read forward
onto `master`.

Before, at `zfs-2.4.3` (`vdev.c:4583-4591`):

```c
if (tvd->vdev_islog && mg != NULL) {
	metaslab_group_passivate(mg);
	error = spa_reset_logs(spa);
```

After, on `master` (`vdev.c:4666-4675`):

```c
if (tvd->vdev_islog && mg != NULL && dtl_required) {
	metaslab_group_passivate(mg);
	error = spa_reset_logs(spa);
```

`dtl_required` is `vdev_dtl_required(vd)`, which is false when the vdev is
redundant. So on `master`, offlining one side of a mirrored log skips both
the passivate and the reset: `vs_alloc` is not driven to zero and the ZIL is
not drained.

This finding's own run is unaffected. It used a single log,
`/var/tmp/ziltest/slog`, a bare leaf under `logs` with no mirror. For that
topology `vd == tvd`, and `vdev_dtl_required()` returns `B_TRUE` on its first
line without evaluating any DTL, so the passivate and reset still run exactly as
recorded.

Two consequences are worth carrying forward.

1. Route 3 in finding 12's table ("`zpool remove` after `zpool offline`") is
   ruled out here because the offline drains the ZIL first. On a
   post-`520eeeaa6` build with a mirrored log, that reasoning no longer
   applies, and the route would need re-running before it could be called ruled
   out. It has never been run on any 2.4.x tree in any case (3.20).
2. The incident's SLOG was a mirror (claim 1.1). Anyone reasoning about that
   pool against current `master` rather than against the build it actually ran
   must account for this. It does not bear on what happened in 2026-07, because
   the incident's build long predates the commit.

`spa_vdev_remove_log()` is untouched by `520eeeaa6`, so findings 10, 13 and 14
and claims 2.1 and 3.8 are all unaffected.

## Finding 12: the hole-plus-dirty-header state was not reachable by any of the nine routes tried

> Forward pointer. Natural-route enumeration as of finding 11 is complete;
> testability of the state is not: finding 16 manufactured it with a test-only
> debug hook, and finding 17 tested its claimed-chain form. Read this finding
> as a bounded negative about routes, not as closure of the investigation.

With finding 11 the enumeration of the routes tried reaches its final form.
Every route in that enumeration was tested, but not every route on every
version. Do not read "complete" as "exhaustive": hypothesis E cannot be
expressed without TrueNAS middleware and was never tried, and hypothesis I has
no valid run. This is a bounded negative over the routes tried, not a
demonstration that no other route exists (`../CLAIMS.md` 3.20). Version coverage
is per route and is tabulated below. Several routes were run on only one
version, and the failing-log route was run on 2.4.1 in one of its two forms.

| Route | Outcome | Finding |
|---|---|---|
| 1. `zpool remove`, healthy log, `vs_alloc != 0` | reset runs, all headers cleared | 1, 3 |
| 2a. `zpool remove`, failing log, `vs_alloc != 0`, errors simulated with `zinject -e io` (script `03`) | `remove exit=0`, hole created, all headers cleared | 5 |
| 2b. `zpool remove`, failing log, `vs_alloc != 0`, backing device swapped to a real dm `error` target (script `07`) | reset hangs unkillably in `zil_parse` -> `arc_read` -> `zio_wait` | 10, 14 |
| 3. `zpool remove` after `zpool offline` | offline drains the ZIL first, headers cleared. Single log only; on `master` a redundant log skips the drain (`520eeeaa6`), and the route would need re-running there | 11 |
| 4. `zpool remove` after wipe plus `import -m` | `-m` clears headers, hole has clean headers | 8, 9 |
| 5. `zpool remove` with an encrypted, key-unloaded dataset | refused outright | 6 |
| 6. `zpool freeze` then `zpool remove` | deadlock, incompatible by construction | 4 |
| 7. `import` without `-m`, log wiped or missing | refused outright | 12 |
| 8. `import -m`, log wiped or missing | `SPA_LOG_CLEAR` clears every header | 8 |

Routes 2a and 2b look like the same failing-log remove; the distinguishing
variable is how the log is made to fail. `03` uses `zinject -d <dev> -e io
-T all` (errors at the ZIO layer; I/O completes with an error;
`spa_reset_logs()` finishes and clears headers). `07` swaps the dm table under
a live pool to a real `error` target (device inaccessible, ZIO `ENXIO`,
suspended under default `failmode=wait`, finding 15), so the reset hangs.
Simulated errors are survivable; a genuinely inaccessible device hangs. Claims
that rest on `03` are bounded to `zinject`. Coverage: `03` on all four
versions; `07` on 2.2.2, 2.3.4 and 2.4.3, never 2.4.1.

The refusal in route 7, for the record:

```
cannot import 'ziltest': one or more devices is currently unavailable
The devices below are missing or corrupted, use '-m' to import the pool anyway:
	    /var/tmp/ziltest/slog [log]
```

### The ten hypotheses, enumerated

Referenced by count throughout this repository, so listed here to be
auditable:

Note the count: ten hypotheses were enumerated, seven were validly
executed. Three were not:

- Hypothesis A (`02`) was never run (`ATTEMPTS.md` NOT RUN). Ruled out by
  inheritance from `05`, which drives the same `import -m` path.
- Hypothesis E cannot be run without TrueNAS middleware.
- Hypothesis I (`08`) ran only in an INVALID form: the probe used `zdb -i`
  against a live imported pool (emits nothing), so header count read 0 in all
  12 rounds. The probe was fixed afterwards; the fixed script was never
  re-run.

> Note on the lettering. E is a real hypothesis. The first commit in this
> repository (`e089c12`) carries, in the *Remaining candidates* section:
> "Candidate E: the malformed removal call. `py-libzfs: zpool remove
> storageNone` appears to be middleware passing a null vdev argument, and it
> is timestamped to the same second as one of the `zfs set` operations." It
> sits in the same lettered series as "Candidate D", which went on to become
> hypothesis D and script `04`. E never got a script because it cannot be
> expressed with plain `zpool`/`zfs`; it needs TrueNAS middleware. It was
> simply dropped from the table rather than recorded as untested. It is
> restored to the table below as UNTESTED, and it is why the enumerated
> count is ten, not nine.
>
> B is genuinely undefined. Searched: every file, in every commit in this
> repository as of 2026-07-31 (seven at that date, nine as of 2026-08-02; the
> two later commits are documentation corrections), for any use of "hypothesis
> B", "candidate B", "path B", "route B" or "option B". Zero matches. No script
> `0N-path-b-*.sh` was ever added or deleted. B was skipped at the outset or
> dropped before it was written down anywhere. It is a lettering gap, not a lost
> experiment, and nothing in this repository depends on it.
>
> The lettering is therefore non-contiguous by accident (A, C, D, E, F, G,
> H, I) and is kept only because other documents cite these hypotheses by
> letter. Two of the ten hypotheses (the `zpool freeze` route (f4) and the
> `zpool offline` route (f11)) were explored manually before the scripts
> existed and were never assigned letters at all.
>
> The letter E is still ambiguous across this repository, and context
> decides. "Patch E" in `patches/README.md` is a proposed change to the
> `vs_alloc` gate and is unrelated. Where this document means the hypothesis it
> says "hypothesis E" or "the malformed-remove candidate"; a bare "E"
> elsewhere means Patch E.

| # | Hypothesis | Script | Outcome |
|---|---|---|---|
| A | lose the log, `import -m` | `02` (never run; superseded by `05`) | RULED OUT via `05` (f7, f8) |
| C | log returning 100 % I/O errors injected with `zinject`, then remove | `03` | RULED OUT (f5) |
| D | unholdable-because-encrypted (key unloaded) dataset, then remove | `04` | RULED OUT, refused (f6) |
| E | the malformed removal call `py-libzfs: zpool remove storageNone`, and whether concurrent `zfs set` property changes can race `spa_reset_logs()` | none; cannot be expressed without TrueNAS middleware | UNTESTED (`../CLAIMS.md` 4.3) |
| F | `import -m` plus an unholdable dataset | `05` | RULED OUT (f7, f8) |
| G | wipe the log so `vs_alloc == 0`, then remove | `06` | Gate confirmed, no stranded header (f9) |
| H | fail the log under a live pool with a real dm `error` target, then remove | `07` | HANGS (f10). No prior OpenZFS report of this hang on the removal path was located; the tracker search is not recorded, so treat novelty as unestablished |
| I | race the `vs_alloc` window | `08` | INVALID (probe bug), never validly re-run (f12) |
| n/a | `zpool freeze` then remove | manual | RULED OUT, deadlock (f4) |
| n/a | `zpool offline` then remove | manual | RULED OUT (f11) |

Plus the cross-cutting version hypothesis (that 2.4.x was already hardened
and 2.3.4 was not). Findings 12 and 13 were taken at the time to disprove it;
finding 13's own correction shows they could not have, and it was finally
tested and DISPROVED by finding 14.

The routes tabulated above are the distinct code paths these
hypotheses exercise; several hypotheses converge on the same route.

To conclude, every one of the routes above either clears the ZIL headers,
refuses the operation, or hangs. None of them produces a hole vdev together with
a surviving non-zero `zh_log`. Stated at its true strength: this is a bounded
negative over the routes that were tried, on the versions each was tried on. It
does not establish that no sequence exists. See `../CLAIMS.md` 3.20.

Version coverage from `ATTEMPTS.md` (a route counts only with a dated row):

| Route | 2.2.2 | 2.4.1 | 2.3.4 | 2.4.3 |
|---|---|---|---|---|
| 1. remove, healthy log (manual, `01`) | no row | yes, 07-29 | yes, 07-30 | yes, 07-31 |
| 2a. remove, `zinject` errors (`03`) | yes, 07-29 | yes, 07-29 | yes, 07-30 | yes, 07-31 |
| 2b. remove, real dm `error` (`07`) | yes, 07-29 | no row | yes, 07-30 | yes, 07-31 |
| 3. remove after `offline` (manual) | yes, 07-29 | no row | no row | no row |
| 4. remove after wipe + `import -m` (`06`) | yes, 07-29 | no row | yes, 07-30 | yes, 07-31 |
| 5. remove, encrypted key-unloaded (`04`) | yes, 07-29 | yes, 07-29 | yes, 07-30 | yes, 07-31 |
| 6. freeze then remove (manual) | no row | yes, 07-29 | no row | no row |
| 7. import without `-m` (manual) | yes, 07-29 | no row | no row | no row |
| 8. `import -m` (`05`) | no row | yes, 07-29 | no row | no row |

No version has full route coverage. Totals: six on 2.2.2, five on 2.4.1, five
on 2.3.4, five on 2.4.3. The bounded negative holds per cell, not per version.

### What that means, stated carefully

Three separate statements, and they must not be collapsed:

1. The affected pool was genuinely in that state. `zdb -l` on a member
   partition and `zdb -e -p /dev/disk/by-id` both showed the hole (`zdb -C`
   never worked on that pool; see `../CLAIMS.md` 1.3), the SysRq-W stack showed
   `zil_check_log_chain` -> `zil_parse` -> `arc_read` -> `zio_wait`, and
   read-only import worked while writable import did not. That is observed
   fact, not inference.

2. How it got there is not reproducible and should be treated as an anomaly of
   that specific hardware incident. The plausible causes are all outside the
   documented paths: a partial `spa_reset_logs()` against SLOG SSDs that were
   flickering between available and unavailable, an operation interrupted by a
   crash or forced reboot, or the malformed
   `py-libzfs: zpool remove storageNone` call recorded in that pool's history at
   `2026-07-19.22:57:28`. None of these was reproduced, and no claim of
   causation should be made.

3. The guard gap in `zil_check_log_chain()` (no `vdev_ishole` check) is real
   and confirmed from source. The consequence "a pool that reaches this state
   hangs unkillably on import" does not follow on any release tested: finding
   16 imports the unclaimed form cleanly; finding 17's claimed form fails fast
   at `spa_load_verify()` while `zil_check_log_chain()` enters and returns.
   Finding 10 shows the same blocking site is reachable on a stock package
   through `zil_destroy_sync()` during log removal. Why the incident's import
   read never completed is not established; see finding 10 and claim 4.9.

Point 3 is the one with a source-level gap anyone can check. Point 1 is the
case study that motivated it. Point 2 is out of scope for any bug report.

### Testing is complete (as of finding 12, which it was not; see the forward pointer)

> Forward pointer, added 2026-07-31. This heading is false as a description
> of the repository and is kept only because this is a chronological notebook
> and it was written in good faith at the time. Testing did not stop here.
> Findings 13, 14, 15, 16 and 17 all came afterwards, adding two ZFS versions,
> the `failmode` variable, a synthesised precondition and a claimed-chain
> variant; and findings 14 and 16 each reversed a conclusion stated above.
> Read this section as "no further work was planned on 2026-07-29", not as
> closure.

*Written at the time finding 12 closed, before finding 13. Counts here are
as-of-then: nine hypotheses, two ZFS versions, twelve findings. Finding 13
below adds a third version, finding 14 a fourth, and findings 15 to 17 continue
past all of them.*

No further reproduction work is planned for the import-side precondition. The
case rests on finding 10, which is reproducible, plus the source-level gaps in
findings 3.1 and 3.6 of `../CLAIMS.md`, which are verifiable by reading the
tree.

Scope of the closure at that point, stated plainly: "two ZFS versions" means
stock OpenZFS 2.2.2 and 2.4.1 on Ubuntu aarch64. The VM named `zfs234` was
created to test 2.3.4 but ships 2.2.2, so every result from it is a 2.2.2
result. No TrueNAS-faithful environment (middleware, py-libzfs, x86-64) was ever
stood up. The full environment gap, what remains untested, and why the
classification still stands are in
[`../CONCLUSIONS.md`](../CONCLUSIONS.md#3-how-they-relate-the-gap-between-the-synthesis-and-the-incident)
and [`../CONCLUSIONS.md`](../CONCLUSIONS.md) §3.

---

## Finding 13: ZFS 2.3.4 behaves as 2.2.2 does on the four paths where both were run, and as 2.4.1 does on the three paths where both were run

> The version hypothesis this finding was designed to settle was mis-specified,
> and finding 13 therefore does not settle it. The hypothesis was "2.4.x carries amotin's `1e1d64d` and 2.3.4 does not".
> Checking the release tags directly shows `1e1d64d` first ships in `zfs-2.4.3`
> and is absent from 2.4.0, 2.4.1, 2.4.2 and every 2.3.x. All three versions the
> test environment ran (2.2.2, `zfs-2.3.4`, 2.4.1) lack it. Their agreeing with
> each other is therefore expected and says nothing about the hardening.
>
> The incident repair, by contrast, was built on `zfs-2.4.3`, which does carry
> `1e1d64d`. So the fix ran as `1e1d64d` + Patches A to D; the testing ran
> without `1e1d64d` at all. The two sides of this repository are not on the same
> tree in the one respect that matters most to the guard being discussed.
>
> None of which means `1e1d64d` would have prevented the incident. It would
> not. It tests `BP_IS_HOLE(&zh->zh_log)`, an all-zero DVA, and the incident
> pool held a valid non-zero DVA aimed at a hole (`../CLAIMS.md` 3.5, 3.2). The
> affected machine was a fresh install of the then-current TrueNAS release,
> fully updated, and hung regardless. The gap in `zil_check_log_chain()` is
> independent of which tree carries `1e1d64d`.
>
> What finding 13 does establish is unchanged and still useful: behaviour is
> stable across three releases spanning the incident's version range. What it
> does not establish is anything about `zfs-2.4.3`. See `../CLAIMS.md` 3.29 and
> 4.5. The experiment that was open at the time (running `03`, `04`, `06` and
> `07` on a source build of `zfs-2.4.3`) was carried out the same day and is
> finding 14.

The test environment was as follows.

| | |
|---|---|
| Host | Apple Silicon (arm64), macOS 26.5.2, Lima 2.2.0 with Apple Virtualization.framework |
| Guest | Debian 13.6 (Trixie), kernel `6.12.95+deb13-cloud-arm64`, aarch64 |
| ZFS | built from source, tag `zfs-2.3.4` |

ZFS 2.3.4 was built from source on Debian 13 (Trixie) to narrow the version gap
to the incident. The build used `--prefix=/usr` with kernel module support (the
same base OS that TrueNAS SCALE 25.10 uses).

This is not the incident's build.
TrueNAS describes the release as `2.3.4-1`, but the module running on the
affected system reported itself as `zfs-2.3.3-107-gec5aa9bfd`: a snapshot 107
commits past the `zfs-2.3.3` tag, which is a different tree from the `zfs-2.3.4`
release tag built here. See
`../incident/evidence/2026-07-30-post-repair-history.txt`. What this VM
establishes is that behaviour is stable across three releases spanning the
incident's version range, not that it matches the incident.

### Results

Four of the five tests produced the same results as ZFS 2.2.2. The fifth,
`01`, has no 2.2.2 run to compare against. Three of the five also match 2.4.1;
two (`06` and `07`) have no 2.4.1 result, because neither script was ever run
on 2.4.1:

| Test | Finding | Result on 2.3.4 | Same as 2.2.2? | Same as 2.4.1? |
|---|---|---|---|---|
| `01-verify-environment.sh` | 2, 3 | PASS | No comparison: `01` was never run on 2.2.2 | Yes (`ATTEMPTS.md`, 07-29) |
| `03-path-c-failed-log.sh` | 5 | RULED OUT (all zh_log cleared) | Yes | Yes (07-29) |
| `04-path-d-unopenable-dataset.sh` | 6 | RULED OUT (removal refused) | Yes | Yes (07-29) |
| `06-path-g-vs-alloc-zero.sh` | 9 | RULED OUT (all zh_log cleared) | Yes (07-29, recorded PARTIAL) | No comparison: `06` was never run on 2.4.1 |
| `07-path-h-yank-live-log.sh` | 10 | HUNG (120 s timeout; no stack captured) | Consistent with 2.2.2, but not verified at the same stack frame | No comparison: `07` was never run on 2.4.1 |

### Key finding

ZFS 2.3.4 did not return from `zpool remove` under
`07-path-h-yank-live-log.sh`. 2.4.1 was never tested on this path, so this
finding says nothing about it.

Evidence caveat. On 2.3.4 the run was recorded as a 120-second timeout.
No stack trace was captured, so the claim that this hang is at the same
site (`zil_destroy_sync()` -> `zil_parse()` -> `arc_read()` -> `zio_wait()`) is
an inference from the 2.2.2 behaviour, not an observation on 2.3.4. The 2.2.2
run is the one with a captured stack. Anyone rerunning this should capture
`/proc/<pid>/stack` before the VM is force-stopped.

### What this means

Nothing tested distinguishes 2.3.4 from 2.2.2 or 2.4.1, so a version-specific
explanation for the hole-plus-dirty-header state is less likely across those
three releases. It does not speak to `zfs-2.4.3`, which is the only release
carrying `1e1d64d` and was never run through any script here, nor to TrueNAS's
own build, which was never tested.

### What remains untested

`zfs-2.4.3`, the tree the incident repair was built on, and the only release
that contains amotin's `1e1d64d`. No script in this directory had been run
against it at the time this was written.

> Closed the same day, 2026-07-31. Scripts `01`, `03`, `04`, `06` and `07`
> were run on a source build of `zfs-2.4.3`; see finding 14. The sentence that
> stood here, "this is now the cheapest and highest-value gap in the version
> coverage", ranked future work in advance of doing it and is removed rather
> than updated.

A TrueNAS-faithful environment generally: TrueNAS's OpenZFS build (`2.3.3-107`,
which may carry additional patches, including, possibly, a backport of
`1e1d64d`, since that commit is authored by a TrueNAS engineer and TrueNAS
shipped NAS-140080 "Fixes issues with log VDEV removal" in 25.10.3), kernel
`6.12.91-production+truenas`, x86-64, and removal driven through `middlewared` /
`py-libzfs`. The malformed `py-libzfs: zpool remove storageNone` call recorded
in the incident's pool history cannot be expressed through CLI and requires the
middleware layer.

Also untested, and more important: a stack capture of the 2.3.4 hang, and
`failmode` on any version.

Evidence in `evidence/2026-07-30-zfs-2.3.4-1-test-results.txt` and
`evidence/2026-07-30-zil_parse-removal-hang-2.3.4.txt`.

---

## Finding 14: ZFS 2.4.3, the hardened tree, and the incident's own repair commit, behaves identically, and the hang survives into it with a captured stack

Run 2026-07-31 to close the version-coverage gap that finding 13's correction
exposed. This is the fourteenth finding and the first run on a tree containing
amotin's `1e1d64d`.

The test environment was as follows.

| | |
|---|---|
| Host | Apple Silicon (arm64), macOS 26.6, Lima 2.2.0 with Apple Virtualization.framework |
| Guest | Debian 13 (Trixie), kernel `6.12.95+deb13-cloud-arm64`, aarch64 |
| VM | `zfs243` |
| ZFS | built from source, tag `zfs-2.4.3`, commit `83020cf`, module string `zfs-2.4.3-0-g83020cf` |

Why this tree specifically. `zfs-2.4.3` is the only release containing
`1e1d64d`, and it is also the tree the incident repair was built on: the
recovery module reported `zfs-2.4.3-0-g83020cf-dirty-dist`, which is this
commit plus local edits. Running here does two things at once: it tests the
hardening hypothesis that finding 13 could not, and it puts the reproduction
work and the incident work on the same commit for the first time.

`1e1d64d`'s presence was confirmed three ways before any test ran: the
`zil_claim()` "If the log is empty" early return at `zil.c:1171`; two
occurrences of `memset(zh, 0, sizeof (zil_header_t))` in `zil.c` where every
earlier release has one; and one occurrence of
`ASSERT0(vd->vdev_stat.vs_alloc)` in `vdev_removal.c` where `zfs-2.4.2` has
two. Details in `evidence/2026-07-31-zfs-2.4.3-test-results.txt`.

### Results

| Test | Finding | Result on 2.4.3 | Same as 2.2.2 / 2.3.4? |
|---|---|---|---|
| `01-verify-environment.sh` | 2, 3 | PASS, all six checks | Yes |
| `03-path-c-failed-log.sh` | 5 | RULED OUT: hole created, 170 data errors, every `zh_log` cleared | Yes |
| `04-path-d-unopenable-dataset.sh` | 6 | RULED OUT: "Mount encrypted datasets to replay logs", `remove exit=1`, no hole | Yes |
| `06-path-g-vs-alloc-zero.sh` | 9 | RULED OUT: `ALLOC 0`, `remove exit=0`, hole created, reset skipped, headers clear | Yes |
| `07-path-h-yank-live-log.sh` | 10 | HUNG, with a captured stack | Yes, except `txg_quiesce`; see below |

### The hang, on the newest tested release, with a stack

`zpool remove ziltest slogdev` entered uninterruptible sleep and stayed there.
`vs_alloc` after the yank read 72K, non-zero, so `spa_reset_logs()` runs.

```
[<0>] zio_wait+0x14c/0x358            [zfs]
[<0>] arc_read+0xd78/0x1640           [zfs]
[<0>] zil_parse+0x1f0/0x6e8           [zfs]
[<0>] zil_destroy+0x210/0x280         [zfs]
[<0>] zil_suspend+0x520/0x680         [zfs]
[<0>] zil_reset+0x20/0xb0             [zfs]
[<0>] dmu_objset_find+0x80/0xd8       [zfs]
[<0>] spa_reset_logs+0x34/0x80        [zfs]
[<0>] spa_vdev_remove+0x6d4/0x958     [zfs]
```

Same blocking site as the 2.2.2 capture. `zil_read_log_block`,
`zil_destroy_sync` and `spa_vdev_remove_log` do not appear as frames here;
they are inlined at this build's optimisation level, not absent from the path.

#### This is the most heavily corroborated result in the repository

The hang here is not a single reading. Two independent observations agree, a
third establishes the lock, and a fourth makes the first two re-checkable.
Counted honestly, that is the strongest corroboration of any run in this
repository:

1. `/proc/<pid>/stack`, read directly from the D-state `zpool` process
   (PID 60246) while it was still wedged. Verbatim in
   `evidence/2026-07-31-zfs-2.4.3-raw-captures.txt` §1.
2. The kernel's own hung-task watchdog, which fired at 120 seconds and
   produced the same call trace with no involvement from me. This is
   generated by the kernel, not transcribed by hand.
3. `zpool list` in a second shell returning exit 124, the `timeout`
   expiry code. That is positive evidence that `spa_namespace_lock` was still
   held by the wedged task, not merely that the first command was slow. A
   `timeout 120` wrapped around the removal itself also expired without
   effect, because a D-state task cannot be signalled.
4. The systemd journal on `zfs243`, recovered later the same day. The journal is
   persistent across the forced power cycles, so the watchdog trace in (2)
   survives as a machine-generated artifact and can be diffed against the
   transcription. Recovered with `journalctl -b -5 -k`; verbatim in
   `evidence/2026-07-31-zfs-2.4.3-raw-captures.txt` §6.

Sources (1) and (2) are independent of each other: one is a userspace read of
kernel state, the other is the kernel volunteering the same trace. Source (4)
is the same kernel event as (2), retrieved a second way from persistent
storage, so it is durability rather than independence. Source (3) establishes
the lock, which neither stack alone does. The VM needed `limactl stop --force`.

This retires the caveat that has travelled with every statement of finding
10. The hang is no longer "seen on 2.2.2 and 2.3.4, with the newest available
release untested". It is seen on 2.2.2, 2.3.4 and 2.4.3, with verified stacks
on the oldest and the newest. 2.4.1 remains unrun and no longer matters much,
since the releases on either side of it both hang.

### One genuine behavioural difference, recorded against this repository's own interest: `txg_quiesce` is NOT wedged on 2.4.3

This is the single behavioural difference between versions found anywhere in
this work, and it weakens a claim this repository makes elsewhere. It is
therefore given its own heading rather than a footnote.

On 2.2.2 the capture recorded two D-state tasks:

```
10466 D    txg_quiesce
10725 D    zpool
```

On 2.4.3 there is one:

```
60246 D    zpool
```

and `txg_quiesce` never appears in `dmesg` at all. Confirmed twice, by two
different kinds of evidence: a live `ps` reading at the time, and, recovered
later the same day, the guest's persistent systemd journal for that boot,
in which `txg_quiesce` appears nowhere in the kernel log
(`evidence/2026-07-31-zfs-2.4.3-raw-captures.txt` §6). The second is
machine-generated and survived the forced power cycle, so the non-reproduction
is not resting on my `ps` output alone.

- `../CLAIMS.md` 2.2, "the hang also wedges `txg_quiesce`, stalling the entire
  pool", is REPRODUCED on 2.2.2 and NOT REPRODUCED on 2.4.3.
- `../CLAIMS.md` 2.1 and 2.3, the hang itself, unkillable, holding
  `spa_namespace_lock`, requiring a power cycle, hold on both.

The operational outcome is the same, but the blast radius is narrower on 2.4.3
than the 2.2.2 capture implies. Any statement of this hang that mentions a
pool-wide stall must name the version. Stated generally, it is wrong for the
newest release tested.

What is not determined is why: whether 2.4.3 genuinely improved this, or
whether the run simply ended too early. The run was observed for about 165
seconds and `txg_quiesce` could block later under sustained write load. That
uncertainty does not soften the result above; the non-reproduction is
observed, on the newest release, twice, from two sources. Only its
explanation is open.

### What this changes

- `../CLAIMS.md` 4.5 moves from UNTESTED to DISPROVED. 2.4.3 is not
  hardened against these paths relative to 2.3.4; it behaves identically on
  all four. The hypothesis is now tested rather than merely mis-specified.
- Claim 3.20's bounded negative spans four releases, including the
  hardened one. That is a materially stronger negative than three unhardened
  trees agreeing with each other.
- Finding 13's correction is discharged. The gap it flagged is closed.

### What it does not change

- `failmode` is still untested on every version. This run used the default
  `wait`, like every row in `ATTEMPTS.md`. Claims 2.6 and 4.9 are untouched,
  and 4.9 is still the sharpest open question. *(Both statements were overtaken
  within hours: `failmode` was varied in finding 15, and 4.9's cited mechanism
  was corrected in finding 16 and further refined in finding 17.)*
- Routes A/F (`05`), freeze and offline were not re-run on 2.4.3.
- Nothing here bears on TrueNAS's build, middleware, or x86-64.
- Nothing was patched in this VM, so the corrected form of Patch A
  (`../CLAIMS.md` 1.12) remains unbuilt and untested.
- `1e1d64d` still does not cover the incident state, and this run does not
  suggest otherwise. It tests `BP_IS_HOLE`, an all-zero DVA; the incident
  pool held a valid non-zero DVA aimed at a hole. Testing on a tree that
  contains it was about honest version coverage, not about whether it helps.

Evidence in `evidence/2026-07-31-zfs-2.4.3-test-results.txt`, with the raw
`/proc/<pid>/stack`, watchdog `dmesg` and recovered journal trace in
`evidence/2026-07-31-zfs-2.4.3-raw-captures.txt` §§1, 2 and 6.

---

## Finding 15: `failmode` is the mechanism of the hang in the test environment (two decisive ways; panic is suggestive only)

Run 2026-07-31 on `zfs243` (tag `zfs-2.4.3`). Full detail and captures in
`evidence/2026-07-31-failmode-and-spa-log-clear.txt`.

Every run before today used the default `failmode=wait`. Source analysis for
finding 14 produced a falsifiable prediction: `zio_vdev_io_start()` marks I/O to
an inaccessible leaf vdev `ENXIO` (`zio.c:4789-4792`, via `vdev_accessible()` ->
`vdev_is_dead()`), and the suspend at `zio.c:5714-5720` fires only when all
three of `ENXIO`, `spa_load_state == SPA_LOAD_NONE`, and `failmode != continue`
hold. In the removal case in the test environment all three do. Therefore
`failmode=continue` should remove the hang.

| `failmode` | Result of `07-path-h-yank-live-log.sh` on 2.4.3 |
|---|---|
| `wait` (default) | Hangs unkillably in `zil_parse` -> `arc_read` -> `zio_wait`; `zpool list` exits 124; forced power cycle (finding 14) |
| `continue` | No hang. `remove exit=0`, hole created, all `zh_log` cleared, script completes |
| `panic` | Kernel panic at `zio_suspend()`, trace captured. But see caveat 1: the panic fires before `zpool remove` is issued, so it does not isolate the `zil_parse()` read |

The `wait`-versus-`continue` contrast is decisive: one variable, opposite
outcomes, matching a prediction made in advance from source. The `panic` run
is suggestive only (caveat 1): it fires during the step-6 scrub provocation,
before removal, so it shows the disposition of uncorrectable I/O without
isolating the `zil_parse()` read.

Same script, same build, same reproduced device failure (`vs_alloc` 43.9M ->
72K, log FAULTED, pool DEGRADED). One variable.

The panic trace names the function directly:

```
Kernel panic - not syncing: Pool 'ziltest' has encountered an uncorrectable I/O
failure and the failure mode property for this pool is set to panic.
 panic+0x164/0x378
 zio_suspend+0x1b0/0x1b8   [zfs]      <- zio.c:2668
 zio_done+0xe84/0x1130     [zfs]
 vdev_mirror_io_start+0x11c/0x280 [zfs]
```

`CLAIMS.md` 2.6 can move from UNKNOWN to established for the removal case in the
test environment: the ZIO's disposition is `zio_suspend()`, and under the
default `failmode=wait` that call never returns while `spa_reset_logs()` holds
`spa_namespace_lock`, so nothing can ever clear the suspension.

Three caveats, all recorded in the evidence file:

1. The panic fires at step 6, not step 7. A persistent-log re-run shows the
   script dies during the `zpool scrub` provocation, before `zpool remove` is
   issued. So `failmode=panic` demonstrates the disposition of uncorrectable
   I/O on this pool; it does not isolate the `zil_parse()` read.
2. The precondition was not produced. It was speculated beforehand that
   `failmode=continue` might strand a header, since `spa_reset_logs()` can now
   fail partway without hanging and `zil_destroy_sync()` discards the error.
   Wrong: every `zh_log` was cleared, because `zil_sync()` zeroes the header at
   `zl_destroy_txg` regardless. Hypothesis retired.
3. This does not explain the incident. The suspend requires
   `spa_load_state == SPA_LOAD_NONE`, which is false during an import. See
   finding 16.

Patch F gains a reproducible test case. `patches/README.md`
states that no ZTS coverage is proposed because "a `zil_parse()` that returns an
error rather than hanging ... has not been produced in the lab". At
`failmode=continue` it now is: the read fails fast, `zil_parse()` returns an
error, `zil_destroy_sync()` discards it via the `(void)` cast, and `zpool
remove` reports exit 0. No `cmn_err` is emitted either, because `zil_parse()`
only warns when the chain is claimed. Silent. That is claim 3.21 on demand.

### Also settled: `SPA_LOG_CLEAR` does not persist (claim 1.13)

The leading explanation for why `spa_ld_verify_logs()` did not block on the
incident's repair import was that `spa_log_state` was still `SPA_LOG_CLEAR`
from the earlier `import -m`. Eliminated four ways: `spa_set_log_state()`
only assigns an in-core field (`spa_misc.c:2759`); `spa_log_state` appears zero
times in `spa_config.c` and `vdev.c`, so it is never serialised;
`spa_check_for_missing_logs()` recomputes it per-import from
`spa->spa_import_flags & ZFS_IMPORT_MISSING_LOG` (`spa.c:2781`); and
experimentally, a plain import after `import -m` + export is refused
byte-identically to before. A fourth reason is specific to the incident: by
repair time the log was a hole, and `spa.c:2825-2826` requires
`vdev_islog && vdev_state == VDEV_STATE_CANT_OPEN`, which a hole never
satisfies. Claim 1.13 stays UNKNOWN; this candidate is closed.

---

## Finding 16: the precondition, synthesised at last, and on 2.4.3 it does not hang

Two results, not one. This finding is usually cited for its negative, and
the negative is the more consequential of the two, but the affirmative came
first and stands on its own:

- Affirmative: the incident's precondition was manufactured for the first
  time, and verified at DVA level. That partly upgrades claim 4.1: skipping
  the reset is now shown to strand headers, though the `vs_alloc == 0` gate
  condition itself was not reproduced (the hook fired at `vs_alloc 22.0M`).
  See "The state, verified at DVA level" below.
- Negative: built exactly, that state does not hang a writable import on
  stock `zfs-2.4.3`. See "The decisive test".

Read `evidence/2026-07-31-precondition-synthesis.txt` before citing either.
Then read finding 17, which corrects three statements made here.

Ten hypotheses failed to reach the precondition naturally (seven of them by
being run; one not runnable, one never run, one run only in an invalid form),
and it was classified as an anomaly. That closure conflated two goals.
Reproducing causation needs a natural route, but testing what the state does
only needs the state. So it was manufactured.

### Method

A test-only debug hook in the local build forces the `vs_alloc == 0` skip that
`CLAIMS.md` 4.1 infers was the incident's cause:

```c
/* LAB DEBUG HOOK -- not upstream, not part of any patch here. */
if (vd->vdev_stat.vs_alloc != 0 && !zfs_lab_skip_reset_logs)
        error = spa_reset_logs(spa);
```

Steps:

1. Create the pool with a log vdev and write a live ZIL chain to the log.
2. Unmount `ds1`. The log reports `vs_alloc 22.0M` at this point.
3. Set the hook, run `zpool remove` of the log, clear the hook.
4. Export.

### The state, verified at DVA level

```
hole_array[0]: 2
        is_hole: 1

Dataset ziltest/ds1 ... ZIL header: claim_txg 0, ...
    Block seqno 341, won't claim, DVA[0]=<2:15e6000:11000> [L0 ZIL intent log]
Dataset ziltest     ... ZIL header: claim_txg 0, ...
    Block seqno 2,   won't claim, DVA[0]=<2:1000:1000>    [L0 ZIL intent log]
```

vdev index 2 is the hole and both headers point into it. Note this needed
`zdb -iiiii`: `zdb -i` alone only shows that `zh_log` is non-zero (3.15), not
which vdev the DVA names.

#### This is an affirmative result and should not be filed under a negative one

Stated at full weight:

The incident's precondition had never existed in the test environment, by any
route, on any version. It exists now, and it was verified at the level that
matters: the DVA, not merely the presence of a header line. Ten hypotheses
across four ZFS versions had failed to reach it naturally, and it had been
reclassified as an anomaly of the hardware incident. Forcing one gate produced
it in one step.

Claim 4.1 splits: skipping the reset strands headers (REPRODUCED). That the
`vs_alloc == 0` gate is what produces the skip on the incident is still
INFERRED. Given the skip, the headers survive and dangle into the hole, in
one step, every time it was run.

What is not shown is that the gate condition can produce this. Note the
`vs_alloc` reading at step 2 of the method above: 22.0M. The hook forces the
skip while the log still reports allocated space. The real gate at
`vdev_removal.c:2144` fires only when `vs_alloc == 0`, and a log reporting zero
allocated space should not have a live chain for a header to point at. Reaching
`vs_alloc == 0` while a live chain is still referenced is an accounting
inconsistency, it was not reproduced here, and every natural route to
`vs_alloc == 0` clears the headers on the way (findings 8, 9, 11). So the honest
split is:

- REPRODUCED: skip the reset, strand a header.
- UNTESTED: the `vs_alloc == 0` gate reaching a state where there is a
  header left to strand. UNTESTED rather than merely unproven: the experiment
  was run, but in a form that could not have settled it, because the hook
  forced the skip at `vs_alloc 22.0M` instead of at zero.
- INFERRED, as before: that the incident took that route.

These are `CLAIMS.md` 4.1's three scopes (a), (b) and (c).

This also unblocked everything after it. Findings 16's negative and 17's
claimed-chain test are both only possible because the state can now be built on
demand, archived, and restored from scratch for repeat runs.

### The decisive test

Pristine stock `zfs-2.4.3` module restored from a pre-patch backup, hook absent.
Writable import:

```
$ zpool import -d /var/tmp/ziltest -o cachefile=none -N ziltest
exit=0
$ zpool list -H -o name,health
ziltest ONLINE
$ ps -eo pid,stat,comm | awk '$2 ~ /D/'
(nothing)
```

No hang. Repeated from a pristine restore: same. `dbgmsg` shows a clean
`LOADED` with no `spa_check_logs failed`, no "dropping the logs", and no
`ZFS read log block error` anywhere.

### Why, from source

Two mechanisms absorb it, and both are deliberate:

- `zil.c:256-257`: when `zh_claim_txg == 0`, `zil_read_log_block()` adds
  `ZIO_FLAG_SPECULATIVE | ZIO_FLAG_SCRUB`. An unclaimed chain is read
  best-effort.
- `zil.c:1328`: `zil_check_log_chain()` returns 0 for `ECKSUM` and `ENOENT`.

An unclaimed chain whose first block is unreadable is indistinguishable from a
chain torn by a crash, which ZFS is designed to tolerate.

### The `vdev_mirror` path correction, and the `zdb -R` control experiment

*This section was three lines. It is written out in full here because the
result depends on how the probe was constructed.*

What was wrong. Claim 4.9 reasoned that a read to a hole vdev should fail
fast because `vdev_hole_ops` uses `vdev_missing_io_start()`, which sets
`ENOTSUP` and calls `zio_execute()` immediately. That reasoning cites the
wrong entry point. A read issued by DVA has `io_vd == NULL`, so it is
dispatched through `vdev_mirror_ops`; the hole's own ops table is never
reached. Every document in this repository that argued from
`vdev_missing_io_start()` was arguing about a function that does not run on
this path.

How it was caught, and why the probe is trustworthy. A direct read against
the hole, on the exported synthesised pool:

```
$ timeout 60 zdb -e -p /var/tmp/ziltest -R ziltest 2:20000:1000
Found vdev type: hole
ASSERT at module/zfs/vdev_mirror.c:616:vdev_mirror_io_start()
!spa_trust_config(zio->io_spa)
...
zdb -R exit=0        <-- returned immediately; NOT 124, so it did not block
```

Note the apparent contradiction, and read it correctly. `zdb` prints an
ASSERT and still exits 0. `zdb`'s userspace `ASSERT` in a non-debug build
prints and continues; it does not abort the process. The exit code matters
for the not-blocking inference, so the discrepancy is stated here
instead of being left for a reader to notice. What the exit code shows is that
the command returned. What the ASSERT shows is which function was entered.
Both are needed and neither substitutes for the other.

Three deliberate features of this experiment, each of which the result depends
on:

1. A `timeout 60` watchdog. The question under test was "does this read
   block?", so the probe was wrapped in a timeout whose expiry code (124)
   would have been the positive answer. Exit 0 is therefore evidence of
   not-blocking, not merely an absence of evidence of blocking. Without the
   watchdog the same output would prove nothing about latency.
2. A control read on a healthy vdev. The same command against vdev 0, a real
   file vdev, returned the block contents (`Found vdev: /var/tmp/ziltest/d1`, a
   hexdump, exit 0). This rules out the probe being broken, the pool being
   unreadable, or `zdb -R` failing for some reason unrelated to the hole. A
   probe with no control could not distinguish "the hole read returns fast" from
   "`zdb -R` always returns fast".
3. A second, independent sighting of the same frame. `vdev_mirror_io_start`
   also appears in the `failmode=panic` kernel trace from finding 15, in the
   kernel, not in userspace libzpool. That matters because of the stated
   caveat below.

The caveat, recorded by the experiment itself. `zdb` runs in userspace
libzpool with assertions enabled, so the ASSERT firing is a debug-build
artifact and is not the kernel's behaviour. What transfers is (a) the entry
point and (b) the fact that the read does not block. The kernel-side
confirmation is the successful import in the decisive test above. The
experiment states its own limits rather than being read for more than it
supports.

The real path, from source. `vdev_mirror_map_init()` (`vdev_mirror.c:266`)
looks up the top-level vdev, which for a hole is non-NULL, so the NULL check at
`:332` does not fire. `vdev_mirror_io_start()` (`:659`) calls
`vdev_mirror_child_select()`, which returns -1 (`:546-551`) because
`vdev_mirror_child_readable()` is false (`vdev_readable(hole)` is false by
design, `vdev.c:4754-4756`), setting `mc_error = ENXIO` and `mc_skipped = 1`.
Back in `io_start` at `:660`, `children` is 0, so the loop body never runs
and no child I/O is ever issued. `vdev_mirror_io_done()` (`:761-762`) then
sets `io_error` from `vdev_mirror_worst_error(mm)`.

Net: what 4.9 concluded, that the read fails fast and does not block, is
empirically confirmed. Only its cited mechanism was wrong. Both halves are
needed: the conclusion is why the unclaimed import succeeds, and the
corrected mechanism is why the reasoning can be trusted the next time it is
applied.

A second result falls out of the same source reading. The `!spa_writeable(spa)`
branch at `vdev_mirror.c:308` runs `zfs_dva_valid()` over the DVAs and drops
invalid ones; if none survive it sets `ENXIO` and returns NULL. On a writable
import that filter is skipped entirely. This is a second and independent reason
a read-only import survives the unclaimed form of this state, distinct from the
`spa_writeable()` gate on verify/claim recorded as claim 3.3. It does not extend
to the claimed form. Finding 17 imported the claimed form read-only and it
failed with `I/O error` (`../CLAIMS.md` 2.9). Read this paragraph as being about
the unclaimed variant only. Raw capture in
`evidence/2026-07-31-zfs-2.4.3-raw-captures.txt` §4.

> Qualified by finding 17, 2026-07-31. "The read fails fast" remains
> correct, but it is not the whole story for a claimed chain. With
> `claim_txg != 0` the block is additionally traversed by `spa_load_verify()`,
> where `zfs_blkptr_verify()` rejects the DVA outright for naming a hole vdev,
> before any read is issued. See finding 17.

### Not the incident's symptom: claimed-chain fail-fast on re-import

After import + clean export the synthesised pool will not import again:
`cannot import 'ziltest': I/O error`, with
`label discarded as txg is too large (51 > 42)` and
`FAILED: label config unavailable`. Reproduced twice from pristine state. Full
`dbgmsg` order: (1) `spa_load_verify()` fails with EIO on the hole-vdev blkptr
(`zio.c:1135: ... DVA 0 has hole VDEV 2`); (2) `spa_load_retry: rewind, max
txg: 50`; (3) rewind caps the acceptable uberblock at txg 42, below the
label's txg 51; (4) label discarded as "too large"; (5) "label config
unavailable". Steps 2–5 are ordinary rewind reacting to step 1; the debug hook
is not implicated. Still not the incident's symptom (that pool imported
read-only fine and hung on writable import). See finding 17 and
`evidence/2026-07-31-claimed-chain-variant.txt`.

### Claimed-chain variant (closed in finding 17)

Once `claim_txg != 0`, `zil.c:256-257` no longer sets `SPECULATIVE`. Import #1
claims the chain (`claim_txg 37`, `flags 0x2`). Import #2 is the test, not a
blocker: the claimed state can be archived and re-imported. It fails fast with
EIO at `spa_load_verify()`, exit 1, no D-state; `zil_check_log_chain` and
`zil_parse` both enter and return (ftrace). It also fails read-only, which the
incident pool did not, so it is not a model of the incident. Full write-up in
finding 17.

### What it means

A hole vdev plus a dangling non-zero `zh_log` DVA resolving to it is NOT
sufficient to hang a writable import on `zfs-2.4.3`.

That contradicts the mechanism this repository asserts for defect 1 in
`../README.md`, `../CONCLUSIONS.md` §1 and `../incident/recovery-breakdown.md`
§9. Those descriptions are incomplete.

Not overturned: the incident happened, and claim 1.2's SysRq-W stack is
OBSERVED. The guard gap (3.1) and the NULL deref (3.6) are source facts that do
not depend on this test. The removal-side hang (findings 10, 14) is untouched.

Changed:

- No bug report may claim "a ZIL header pointing at a hole vdev hangs your pool
  on import". Building exactly that does not hang it. The honest form is: this
  state was observed to hang one pool on one build; constructing the state alone
  on 2.4.3 does not reproduce the hang; at least one further ingredient is
  involved and has not been identified.
- Patch A weakens again. Already source-only after 1.12, the condition it
  guards is now shown not to hang on a current release. Defensible as hardening
  plus a NULL fix; not as a fix for a demonstrated hang.
- 4.9 moves from "sharpest open question" to partially answered.

Untested candidate differences: the incident's actual build; 140 T and many
datasets; encryption; TrueNAS middleware; a genuinely failing device rather
than a clean hole; and the space-map corruption present on the same pool. Both
chain states are tested and neither hangs (findings 16–17); none of the
remaining candidates is favoured over any other. The incident pool had two
defects; this synthesis reproduces only the first, which in isolation is
survivable.

### Two mechanisms, both true, one more precise (added 2026-07-31)

Finding 16 explains the clean unclaimed import by `ZIO_FLAG_SPECULATIVE`
(`zil.c:256-257`) plus the `ECKSUM`/`ENOENT` swallow (`zil.c:1328`). Both are
real. But finding 17 identifies an earlier and more precise reason the bad
blkptr causes no trouble on an unclaimed chain: `traverse_zil_block()`
(`module/zfs/dmu_traverse.c:93-98`) returns -1 for an unclaimed chain with a
recent birth txg, so `spa_load_verify()` never hands the block to the traversal
callback and never sees it at all. The speculative read explains why
`zil_check_log_chain()` tolerates it; the traversal skip explains why
`spa_load_verify()` never gets near it. It is the second that changes when the
chain is claimed.

---

## Finding 17: the claimed-chain variant, tested at last: it does not hang either, and it fails at `spa_load_verify()`, not in `zil_parse()`

Run 2026-07-31 on `zfs243`, tag `zfs-2.4.3`, commit `83020cf`. Full detail and
captures in `evidence/2026-07-31-claimed-chain-variant.txt`.

Module provenance, checked before any import: the loaded
`/lib/modules/6.12.95+deb13-cloud-arm64/extra/zfs.ko.xz` has md5
`20ca91a6a39fbe1a90cdea39feba95e5`, byte-identical to the archived
`/root/zfs.ko.xz.STOCK-2.4.3`. The debug hook was not loaded for any
import recorded in this finding. It was used only in the earlier session, to
manufacture the starting state.

### What this closes

Finding 16 recorded the claimed-chain variant as BLOCKED and as "the single
most promising open lead". It is neither. It has now been tested, three
times, and it does not hang.

### The state, and how it was produced

Take the finding-16 synthesised state (unclaimed, `claim_txg 0`), import it
once (that import succeeds and claims the chain), then export. Verified on
disk afterwards with `zdb -e -p /var/tmp/ziltest -iiiii ziltest`:

```
ZIL header: claim_txg 37, claim_blk_seq 341, claim_lr_seq 0 replay_seq 0, flags 0x2
    Block seqno 341, already claimed, DVA[0]=<2:15e6000:11000> [L0 ZIL intent log]
ZIL header: claim_txg 37, claim_blk_seq 2, ... flags 0x2
    Block seqno 2, already claimed, DVA[0]=<2:1000:1000> ...
```

and `zdb -l /var/tmp/ziltest/d1` giving `hole_array[0]: 2`, `vdev_children: 3`,
`txg: 51`. So: `claim_txg != 0`, `flags 0x2`, chain "already claimed", DVA vdev
index 2, and vdev 2 is the hole. That is the target state exactly. It was
archived as `/root/CLAIMED-CHAIN-state.tgz` inside the guest so the test can be
repeated without re-deriving it.

### The test

```
# zpool import -d /var/tmp/ziltest -N ziltest
cannot import 'ziltest': I/O error
        Destroy and re-create the pool from
        a backup source.
EXIT=1

# ps -eo pid,stat,comm | awk '$2 ~ /^D/'
(no output -- no task in uninterruptible sleep)
```

It fails fast. It does not hang. Reproduced three times: once in the
original session (recorded then only as an unexplained "label artifact"), and
twice more from the archived state restored from scratch.

### Result 1: `zil_check_log_chain()` did not block, confirmed by ftrace, not inferred

The progress notes reach "Verifying pool data", which is past
`spa_ld_verify_logs()`. That alone is suggestive, so it was checked directly:

```
# echo function > current_tracer
# echo "zil_check_log_chain zil_parse zil_claim spa_check_logs zfs_blkptr_verify" > set_ftrace_filter
# echo 1 > tracing_on
# zpool import -d /var/tmp/ziltest -N ziltest    (exit 1)
# echo 0 > tracing_on
# grep -oE 'zil_check_log_chain|zil_parse' trace | sort | uniq -c
      4 zil_check_log_chain
      3 zil_parse
```

`zil_check_log_chain()` was entered 4 times and `zil_parse()` 3 times
during the failing import, and the load proceeded past both. Neither blocked.
(`spa_check_logs` and `zfs_blkptr_verify` did not resolve as ftrace filter
symbols on this build (inlined or static-folded), so they are absent from
`set_ftrace_filter`. The two that matter did resolve.)

### Result 2: it fails in `spa_load_verify()`, on the hole-vdev blkptr check

From `dbgmsg`, verbatim and in order:

```
spa_misc.c:2485: 'ziltest' Verifying Log Devices
spa_misc.c:2485: 'ziltest' Verifying pool data
zio.c:1135:zfs_blkptr_verify_log(): ziltest: blkptr at ffff800088e8b518 DVA 0 has hole VDEV 2
spa_misc.c:431: spa_load(ziltest, config trusted): spa_load_verify found 1 metadata errors and 0 data errors
spa_misc.c:417: spa_load(ziltest, config trusted): FAILED: spa_load_verify failed [error=5]
```

Error 5 is EIO. Mechanism, source-confirmed at the `zfs-2.4.3` tag:

- `traverse_zil_block()`, `module/zfs/dmu_traverse.c:93-98`:

  ```c
  if (BP_IS_HOLE(bp))
          return (0);
  if (claim_txg == 0 &&
      get_birth_time(td, bp) >= spa_min_claim_txg(td->td_spa))
          return (-1);
  ```

  An unclaimed chain with a recent birth txg is skipped here and never
  handed to the traversal callback. That is why finding 16's unclaimed
  variant imported cleanly: `spa_load_verify()` never looked at the bad blkptr
  at all. This is a more precise mechanism than the `ZIO_FLAG_SPECULATIVE`
  explanation finding 16 gave. Both are true (the speculative flag is why
  `zil_check_log_chain()` tolerates the read), but the traversal skip is what
  keeps `spa_load_verify()` away from the block in the first place.

- With `claim_txg != 0` the guard does not fire, the block is traversed,
  and `zfs_blkptr_verify()` at `module/zfs/zio.c:1271` rejects it because the
  DVA's vdev index resolves to a hole. `spa_load_verify()` counts it as a
  metadata error and the load fails EIO.

### Result 3: finding 16's "unexplained label artifact" is explained, and the debug hook is exonerated

Finding 16 recorded `label discarded as txg is too large (51 > 42)` /
`FAILED: label config unavailable` as an artifact whose "cause [was] NOT
determined", and attributed it, tentatively, to the debug hook leaving the pool
inconsistent. That attribution was wrong. The full `dbgmsg` shows the label
messages are downstream of the real error:

1. `spa_load_verify` fails EIO on the hole-vdev blkptr, the primary failure
2. `spa_load_retry: rewind, max txg: 50`
3. the rewind caps the acceptable uberblock at txg 42, below the label's txg 51
4. the label is discarded as "too large (51 > 42)"
5. with no usable label, the retry reports "label config unavailable"

Steps 2 to 5 are ordinary rewind machinery reacting to step 1. The debug hook
is not implicated, and finding 16 has been corrected accordingly.

### Also tested: read-only import fails too, which is a divergence from the incident

```
# zpool import -d /var/tmp/ziltest -N -o readonly=on ziltest
cannot import 'ziltest': I/O error
EXIT=1
```

Note the divergence. The affected pool imported read-only without
complaint and hung only on writable import (`../CLAIMS.md` 1.1, OBSERVED).
This synthesised pool fails both ways. So the claimed-chain state is not a
model of the incident; it is a third, distinct behaviour, alongside the
incident's hang and finding 16's clean import.

A recovery import was also attempted:

```
# zpool import -d /var/tmp/ziltest -N -F ziltest
cannot import 'ziltest': one or more devices is currently unavailable
EXIT=1
```

### A tempting hypothesis, checked and DISPROVED

If the hole-vdev blkptr check in `zfs_blkptr_verify()` were newer than the
incident's build, its absence there would neatly explain why the incident hung
where this synthesis fails fast. It is not newer. Each release tag was fetched
from `github.com/openzfs/zfs` on 2026-07-31 and `module/zfs/zio.c` grepped for
the "has hole VDEV" format string:

| Tag | Present? | Line |
|---|---|---|
| `zfs-2.2.2` | yes | `zio.c:1113` |
| `zfs-2.3.3` | yes | `zio.c:1290`, the incident's lineage |
| `zfs-2.3.4` | yes | `zio.c:1290` |
| `zfs-2.4.1` | yes | `zio.c:1271` |
| `zfs-2.4.3` | yes | `zio.c:1271` |
| `master` | yes | `zio.c:1266` |

The check is present in every release checked, including the one the incident
ran. DISPROVED. The incident's divergence remains unexplained.

### What this establishes

Stated plainly: a hole vdev plus a dangling `zh_log` DVA resolving to it does
not hang a writable import on `zfs-2.4.3`, whether the chain is claimed or
unclaimed. Unclaimed, it imports cleanly, exit 0 (finding 16). Claimed, it
fails fast with EIO at `spa_load_verify()`, exit 1 (this finding). Neither
hangs, neither produces a D-state task, and in the claimed case
`zil_check_log_chain()` and `zil_parse()` are both entered and both return.

Tier: REPRODUCED (negative), on stock `zfs-2.4.3` only. Three runs, two of
them from an archived state restored from scratch. Not tested on 2.2.2,
2.3.4, 2.4.1, or on the incident's own build (`zfs-2.3.3-107-gec5aa9bfd`).
This is a bounded negative on one release, not a general statement.

Method, stated plainly because it is the most controlled run in this
notebook. The module was md5-verified byte-identical to the archived stock
build before any import, so the debug hook cannot account for the result. The
pool state was archived first, so two of the three runs started from a restored
copy rather than from the previous run's leftovers. `zil_check_log_chain()` and
`zil_parse()` were confirmed to enter and return by ftrace, which is a
measurement, not an inference from the absence of a hang. The negative control
is reported as well: `spa_check_logs` and `zfs_blkptr_verify` did not resolve
as ftrace symbols, so their absence from the trace proves nothing.

### What it does not overturn

- The incident happened. Claim 1.2's SysRq-W stack is OBSERVED.
- The guard gap in claim 3.1 and the NULL deref in 3.6 are source facts and do
  not depend on this test.
- The reproducible removal-side hang (findings 10 and 14) is untouched.

### What it changes

- Claim 4.9's "leading untested candidate" is no longer untested and no longer
  a candidate. Claim 2.7's closing sentence, "Untested and now the leading
  lead: the claimed-chain variant ... blocked by a label artifact", is
  superseded on both halves: it is tested, and the label artifact was a
  downstream symptom, not a blocker.
- Two "cause not determined" items in finding 16 are resolved: the label
  artifact (Result 3), and why the unclaimed chain was absorbed (Result 2).
- The gap between the synthesis and the incident WIDENS rather than closes.
  Neither chain state hangs on 2.4.3. The remaining untested candidate
  differences, none of them now favoured over any other, are: the
  incident's build (`zfs-2.3.3-107-gec5aa9bfd`); 140 T of data across many
  datasets; encrypted datasets; TrueNAS middleware and concurrent dataset
  operations; a genuinely failing device underneath rather than a clean hole;
  and the space-map corruption (defect 2) present on the same pool.

No candidate is nominated as the next thing to try. Two successive
"most promising leads" have now closed negatively, and there is no basis in the
evidence for ranking what is left.

---

## Finding 18: the removal hang was reported upstream in 2013 as #1585, acknowledged, and closed as stale

Date: 2026-08-04. Tier: SOURCE + OBSERVED (upstream). Claims: 3.33.

A search for previous reports was performed before filing upstream. Until this
point the repository cited only `#17427` and `#12980`, both of which are
import-path reports. Neither is on the removal path. No search for previous
reports on the removal path had been done. That was an oversight, and it turned
up the most relevant document in the upstream tracker.

### What #1585 is

`openzfs/zfs#1585`, "Kernel hang when removing faulted log device", opened
2013-07-11. A log device (the only one) faulted on I/O errors; `zpool remove`
of it hung. The reporter posted the `zpool` stack:

```
zio_wait
arc_read_nolock
dsl_read_nolock
zil_parse
zil_destroy_sync
zil_destroy
zil_suspend
zil_vdev_offline
dmu_objset_find_spa  (x2, recursive)
dmu_objset_find
spa_offline_log
spa_vdev_remove
zfs_ioc_vdev_remove
```

`txg_quiesce` and a `cp` writer were also in D-state.

### Why this is the same defect as finding 10 / 13 / 14

`a1d477c24` ("OpenZFS 7614, 9064 - zfs device evacuation/removal",
Matthew Ahrens, 2016-09-22) renamed two of those frames:

```
-spa_offline_log(spa_t *spa)          ->  +spa_reset_logs(spa_t *spa)
-zil_vdev_offline(const char *osname) ->  +zil_reset(const char *osname)
```

Substituting, #1585's 2013 stack is frame-for-frame the stack captured on
`zfs-2.4.3` in finding 14, modulo `arc_read_nolock`/`dsl_read_nolock`
(consolidated into `arc_read` long ago) and the inlining differences already
documented. Same trigger, same blocking site, same `spa_namespace_lock`
consequence, and `txg_quiesce` wedged exactly as observed on 2.2.2.

### The thread's own diagnosis

behlendorf, the same day it was filed:

> It appears that trying to remove the faulted log device causes zfs to try
> and read from it. This read basically hangs while holding an important lock
> which causes everything to block. Thanks for the bug report and stacks so
> we can fix this case.

Reconfirmed as still live by `FransUrbo` and `behlendorf` in 2014-06, and again
by `sempervictus` in 2014-10 with a fresh stack. Closed 2016-10-05:

> Closing as stale. If anyone still hitting this let us know and we'll reopen
> it.

### What this changes, and what it does not

Does not change any tier. Finding 10, 13 and 14 stand; 2.1 is still
REPRODUCED and 2.6 is still ESTABLISHED. Independent reproduction of a known
bug is still reproduction.

Does change the novelty claim. This repository must not present the removal
hang as a new defect. It is thirteen years old and a maintainer has already
agreed it is a bug. What is new is the reproducer, the current-release
coverage, and the mechanism (claim 3.33). #1585 has none of the three, and its
thread stops at a description of the symptom.

Changes how this must be reported. Any upstream report of the removal hang
has to cite #1585 and present itself as a follow-up to it, not as a new defect.
The invitation to reopen is on the record and has not expired.

### Also searched, 2026-08-04

- `#13273` "zpool remove of log device hangs" (2022-03-30, closed stale
  2023-08-12). Symptom matches; no stack was ever posted, so it cannot be
  confirmed as the same site. Cite as possible, not as confirmed.
- `#14775` "ZTS test slog_015_neg.ksh can trigger zfs deadlock" (2023-04-20,
  still open). Mentions `spa_reset_logs`, but it is a different bug: a
  three-thread deadlock on `zl_suspend_lock`, introduced by `#14514`. Recorded
  here so it is not mistakenly cited as related.
- Search terms used: `zil_parse hang`, `spa_reset_logs`, `"zpool remove" log
  hang in:title`, `vs_alloc spa_reset_logs`. Six, five, one and zero hits
  respectively.
