# Patch candidates identified during reproduction testing

Two patch candidates, identified from findings 9 and 10 of the reproduction
work. They were not part of the incident recovery.

Neither has ever been built or run. They are specifications written as diffs
for readability. Both are written against `master`, not against the
`zfs-2.4.3` tree the incident patches target: Patch E's hunk header and Patch
F's caller line numbers are `master` numbers, re-verified against `023d44b9e`
on 2026-07-31. `../../CLAIMS.md` §7 indexes every cited line in both trees.
Patch F does not compile as written; see the note under "The change". Before
any submission each must be regenerated with `git format-patch` against current
`openzfs/zfs` master so that context lines, line numbers and hunk offsets match
the tree being patched.

Patches A to D, built and run on the affected hardware during the incident, are
in [`../../incident/patches/`](../../incident/patches/). Note that "run" is not
"validated": Patch A's applied form was a no-op
([`../../CLAIMS.md`](../../CLAIMS.md) 1.12).


There is also a third file in this directory which is NOT a patch candidate.
[`lab-only-skip-reset-logs.txt`](lab-only-skip-reset-logs.txt) is test
apparatus: a debug hook that forces `spa_vdev_remove_log()` to skip
`spa_reset_logs()`, used once to manufacture the incident's precondition so it
could be tested (finding 16). It deliberately breaks a pool. Do not submit it,
and do not confuse it with Patch E, which changes the same gate in the opposite
direction.

A note on naming: the "lab" in this filename, in the module parameter
`zfs_lab_skip_reset_logs`, and in the VM names `zfslab` and `truenas-lab` is
historical. Those names are recorded verbatim in the evidence files and in the
reproduction commands in `../ENVIRONMENT.md`, so they are kept as they are.
Everywhere else in this repository the reproduction environment is called the
test environment. One person built and ran all of it.

Patch F is not the fix for the reproducible hang in finding 10. See the scope
note under Patch F.

## Status at a glance

Neither candidate has been built or run. Tiers are the nine in
[`../../CLAIMS.md`](../../CLAIMS.md) §1 (lines 9-23).

| | Patch E | Patch F |
|---|---|---|
| Is there a diff? | One hunk, complete | No: fragments. Two of the five hunks (`zil_destroy()`, `zil_replay()`) use a bare `@@` with no line numbers and elide the body between them |
| Will it apply with `git apply` / `patch`? | Not as first written (bad hunk counts, one context line indented with spaces). Corrected below; still not verified against a checked-out tree | No. Bare `@@` markers are not valid hunk headers |
| Does it compile? | Not checked. Never compiled | No, as stated by the author. Out-of-`zil.c` callers are not updated; see "The change" |
| Was it built? | No | No |
| Was it run? | No | No |
| Is there a ZTS test? | No. A shape is suggested below; nothing written | No. Outstanding work; the prior blocker is gone (finding 15) |
| Does it fix the reproduced hang (2.1)? | No. It is coupled to that hang; see the caveat under E | No |
| Evidence backing | Gate: SOURCE + REPRODUCED (3.8). Stranding given the skip: REPRODUCED (4.1a, finding 16). Stranding via the gate condition: UNTESTED (4.1b; forced with a debug hook at `vs_alloc 22.0M`, not by the gate). That the incident took that route: INFERRED (4.1c) | Discarded return: SOURCE (3.21). Error path now producible in the test environment: REPRODUCED (finding 15) |

Both should be read as specifications, not as patches. Patch F in particular is
a sketch: it is illustrative fragments, and calling it a patch would overstate
it.

---

## Patch E: make log-vdev removal atomic

File: `module/zfs/vdev_removal.c`

`spa_vdev_remove()` can convert a log vdev into a `hole` even when
`spa_reset_logs()` has failed to clear every dataset's ZIL header. The
operation is not atomic with respect to ZIL cleanup. Any dataset left holding a
non-zero `zh_log` DVA then references a vdev that no longer exists: a dangling
on-disk reference that nothing in the normal course of operation removes
(`../../CLAIMS.md` 3.28: the DVA survives a mount, so the pool cannot
self-heal), and which the repository's own detection probe reports as a bug
state (3.15). That dangling reference is not by itself an unkillable import
hang on `zfs-2.4.3`: finding 16 synthesised it and imported writable on a
pristine stock module (exit 0, pool ONLINE, twice; claim 2.7), absorbed by
`ZIO_FLAG_SPECULATIVE`, the `ECKSUM`/`ENOENT` swallow, and
`traverse_zil_block()` skipping unclaimed chains (`../../CLAIMS.md` 3.30). The
claimed-chain variant fails fast with `EIO` at `spa_load_verify()` (finding 17,
claims 2.8, 2.9, 3.31). Patch E is motivated by the silent exit-0 removal that
leaves the dangling reference: a correctness and accounting defect on its own
terms. What the state costs on an arbitrary tree is not established; the
incident pool did hang (1.2) and the difference remains UNKNOWN (4.9).

The gate is confirmed from source and confirmed empirically: after wiping the
log, `zpool list -v` reported `ALLOC 0` on the log vdev and `zpool remove`
returned 0 and created the hole, so the reset was skipped. That specific run
did not strand a dangling header, but only because reaching the `vs_alloc == 0`
state required an `import -m`, which clears every header via `SPA_LOG_CLEAR`
(see `../FINDINGS.md` finding 8). Finding 16 later closed half of
that gap by forcing the skip with the debug hook: given the skip, the headers
survive and dangle, in one step, every time. The other half stays open, and it
is the half that concerns this gate: the hook fired at `vs_alloc 22.0M`, so a
`vs_alloc == 0` state with a header still left to strand has never been
produced (`../../CLAIMS.md` 4.1).

### Provenance of the gate, and one adjacent upstream commit message

Traced 2026-07-31. Both facts below are checkable in `git log` and neither was
known when finding 9 was written.

- The gate is old and was reviewed. `if (vd->vdev_stat.vs_alloc != 0)
  error = spa_reset_logs(spa);` was moved into `spa_vdev_remove_log()` by
  Serapheim Dimitropoulos in `6c926f426a26` ("Simplify log vdev removal code",
  2019-01-31, closes openzfs/zfs#8347), reviewed by Matt Ahrens and Brian
  Behlendorf. It is not an accident of recent churn. Any proposal to remove it
  is a proposal to revisit a deliberate 2019 decision, and should say so.
- An adjacent assertion on `vs_alloc` was deleted in 2026. The same
  function used to assert `ASSERT0(vd->vdev_stat.vs_alloc);` after the
  evacuation. `1e1d64d` (2026-03-04, closes openzfs/zfs#18277) removed that
  assertion. Its commit message reads, verbatim:

  > `spa_vdev_remove_log()` asserts that allocated space on removed log device
  > is zero. While it should be so in perfect world, it might be not if space
  > leaked at any point.

  That is the whole of the fact: one deleted assertion and the message that
  accompanied it, both in `git log`. Readers can weigh it themselves.


### A ZTS test for this already exists upstream

`1e1d64d` also added
`tests/zfs-tests/tests/functional/removal/removal_with_missing_log.ksh`
(Copyright 2026, TrueNAS). Its strategy is: create a pool with a SLOG, freeze,
write to the ZIL, export, `import -N` to claim without replay, export,
`zpool labelclear` the SLOG, `zpool import -m`, then `zpool remove` the missing
log and assert the pool is healthy with correct space accounting.

That is close to this repository's hypotheses A, F and G, and it independently
corroborates findings 8 and 9: the `labelclear` + `import -m` + `remove` route
is expected to succeed with clean headers, which is exactly what `05` and `06`
observed. The route that is not covered by it is the one in
`../07-path-h-yank-live-log.sh`, where the log fails under a live pool with no
intervening export, and which hangs. This author's suggestion, offered as a
suggestion and not as a requirement on anyone: extending
`removal_with_missing_log.ksh` with a sibling case looks cheaper than starting
from scratch, and a sibling rather than a replacement would leave the existing
coverage intact. Whoever writes such a test may reasonably structure it
differently.


Shape of the fix: remove the conditional so `spa_reset_logs()` is always called
and its error is propagated. If the reset fails the removal is aborted, leaving
the log vdev in place. Whoever runs the removal can retry, or force it having
been told the pool may become unimportable.

Caveat that must travel with this patch. Removing the gate means a removal
against a failing log now reaches `spa_reset_logs()` where it previously did
not. That is exactly the path that hangs unkillably (finding 10). Applying E
without first understanding the hang would convert a silent bad outcome into a
wedged machine for some users. E and the finding-10 hang are coupled and should
not be considered in isolation.

> Two hunk starts are in circulation for this one gate, and they do not
> conflict. Against `../../CLAIMS.md` §7 the `vs_alloc != 0` gate is
> `vdev_removal.c:2144` at `zfs-2.4.3` and `2148` at `master`. This file's hunk
> starts at `-2141` (2.4.3) / `-2145` (`master`) because three context lines
> precede the gate.
> [`lab-only-skip-reset-logs.txt`](lab-only-skip-reset-logs.txt):86 reads
> `@@ -2141,7 +2142,8 @@`: it is a different change (it adds two lines rather
> than removing one) and its hunk follows an earlier hunk in the same file that
> adds one line, which is why its new-side start is `2142`. That file is the
> only hunk here ever checked against a real built tree.
>
> The hunk below is not verified. It has been made internally consistent by
> counting; it has not been run through `git apply` against a checked-out tree.
> Treat it as a labelled code excerpt. Regenerate it with `git format-patch`
> before doing anything with it.

The hunk below is against `master`, where the gate is `vdev_removal.c:2148`. In
`zfs-2.4.3` the same gate is at `:2144` and the equivalent header reads
`@@ -2141,7 +2141,6 @@`. Indentation is tabs, as in the tree.

```diff
--- a/module/zfs/vdev_removal.c
+++ b/module/zfs/vdev_removal.c
@@ -2145,7 +2145,6 @@ spa_vdev_remove_log(vdev_t *vd, uint64_t *txg)
 	 * should no longer have any blocks allocated on it.
 	 */
 	ASSERT(spa_namespace_held());
-	if (vd->vdev_stat.vs_alloc != 0)
-		error = spa_reset_logs(spa);
+	error = spa_reset_logs(spa);
 
 	*txg = spa_vdev_config_enter(spa);
```

No ZTS test for this patch has been written; that is outstanding work. One
possible shape, offered as this author's suggestion only: a sibling of the
existing upstream
`tests/zfs-tests/tests/functional/removal/removal_with_missing_log.ksh` (see "A
ZTS test for this already exists upstream" above), deriving the
failing-log-under-a-live-pool sequence from
[`../07-path-h-yank-live-log.sh`](../07-path-h-yank-live-log.sh).

Relationship to the other patches (A and B are in
[`../../incident/patches/`](../../incident/patches/)):

- A closes the predicate gap in `zil_check_log_chain()`. It is hardening
  plus a NULL fix, not a fix for a demonstrated hang: on `zfs-2.4.3` the state
  it guards does not hang a writable import in either chain form
  (`../../CLAIMS.md` 2.7, 2.8).
- E would prevent the state being created. Split (`../../CLAIMS.md` 4.1):
  - Skipping the reset strands headers: REPRODUCED (4.1a). Forcing the
    skip strands a header dangling into the hole, in one step, every time. It
    is precisely that state E prevents.
  - The `vs_alloc == 0` gate reaching such a state: UNTESTED (4.1b). The
    finding-16 hook fired with the log at `vs_alloc 22.0M`; the real gate fires
    only at zero, and every natural route to zero clears the headers first.
  - Whether the incident took that route: INFERRED (4.1c). E's value does
    not rest on that question; it rests on the demonstrated half plus the
    silent-exit-0 defect below.
- B repairs the damage in place.


---

## Patch F: propagate the error `zil_destroy_sync()` currently discards

File: `module/zfs/zil.c`, `include/sys/zil.h`

### Status: this is a sketch, not a patch

Stated plainly and in one place because these disclosures were previously
scattered through the section:

- It is fragments, not a patch. Two of the hunks below, the one for
  `zil_destroy()` and the one for `zil_replay()`, use a bare `@@` with no line
  numbers, eliding the body in between. A bare `@@` is not a valid hunk header.
  Nothing here will apply with `git apply` or `patch`.
- It does not compile as written. The hunks cover the four call sites
  inside `module/zfs/zil.c` and nothing else, while `zil_destroy()` and
  `zil_destroy_sync()` have callers outside that file which the signature
  change breaks. Detail under "The change".
- The caller list was assembled by grep, against `master` at `023d44b9e`.
  A real submission has to enumerate callers with a tree-wide search instead.
- The suspend unwind is unchecked. Whether `zil_suspend()`'s state is
  correctly unwound on the new error path has not been verified. Detail under
  "Known open questions in this patch".
- Never built, never run. No ZTS test exists. The condition it handles
  can now be produced in the test environment (finding 15); the blocker that
  used to be cited for not writing a test is gone, and the test is outstanding
  work.

### Scope, and what this patch is not

Patch F does not fix the hang in finding 10. It never reaches the blocking
`zio_wait()`, and the premise that `zil_parse()` "has no error path" is false:

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

`zil_parse()` returns `int` and handles a failed read by warning and breaking
the loop. In the finding-10 hang that code is never reached because
`arc_read()` -> `zio_wait()` never returns. An error that is never produced
cannot be propagated, so no amount of caller-side plumbing fixes the hang.

Why the ZIO never completes was, when this section was written, not
established. That has since changed for the removal case in the test
environment and not for the incident (`../../CLAIMS.md` 2.6, 4.9; findings 15
and 16):

- Removal case in the test environment: settled. The ZIO's disposition is
  `zio_suspend()`. At `failmode=continue` the hang disappears (`remove exit=0`);
  at `failmode=panic` the kernel panics with `zio_suspend+0x1b0` in the trace;
  at the default `wait` it blocks forever while `spa_reset_logs()` holds
  `spa_namespace_lock`. Source gate at `zio.c:5714-5720`.
- Incident import: still UNKNOWN. That suspend cannot fire during an import
  (`spa_load_state != SPA_LOAD_NONE`), and finding 16 shows the synthesised
  precondition does not hang on `zfs-2.4.3`.
- 4.9's cited mechanism was wrong and is corrected: a read by DVA has
  `io_vd == NULL` and dispatches to `vdev_mirror_ops`, not to
  `vdev_missing_io_start()`/`ENOTSUP`. Its conclusion, that the read fails
  fast, is now empirically confirmed.

The experiment named here as "the cheapest",
`FAILMODE=continue sudo -E ../07-path-h-yank-live-log.sh`, has been run; it is
finding 15.


### What Patch F is actually for

Independently of the hang, there is a real gap. When `zil_parse()` does
return an error (a checksum failure, a short record, a read that fails fast),
`zil_destroy_sync()` throws it away with a `(void)` cast, and `zil_destroy()`
never reports it. `spa_reset_logs()` therefore cannot distinguish "every
dataset's ZIL was cleared" from "one dataset's ZIL could not be parsed", and
`spa_vdev_remove_log()` proceeds to create the hole either way.

Fix it on its own terms. Error-handling hygiene, not a fix for finding 10.
Propose it as such.

### The change

This patch does not compile as written. The hunks below cover the four call
sites inside `module/zfs/zil.c` and nothing else, but `zil_destroy()` and
`zil_destroy_sync()` are both exported through `include/sys/zil.h` and have
callers outside that file:

- `module/os/linux/zfs/zfs_vfsops.c:797`: `zil_destroy(zfsvfs->z_log, B_FALSE)`,
  which breaks against the new three-argument signature (`zfs-2.4.3`: `:768`)
- `module/zfs/dsl_destroy.c:868` and `:918`: `zil_destroy_sync(...)` called as a
  bare statement, which would need a `(void)` cast once it returns `int`
  (`zfs-2.4.3`: `:925` and `:975`)

Line numbers are against `master`, commit `023d44b9e`, re-verified 2026-07-31;
all three call sites confirmed present. Any real submission still has to
enumerate callers with a tree-wide search rather than trusting the list above
because this list was assembled by grep and `master` moves.

Three signature changes and four call sites *within `zil.c`*. The blocks below
are illustrative fragments. Two of them use a bare `@@` in place of a hunk
header to elide unchanged body; that is not valid diff syntax and those blocks
cannot be applied. They are shown in diff formatting for readability only.


`include/sys/zil.h`:

```diff
-extern boolean_t zil_destroy(zilog_t *zilog, boolean_t keep_first);
-extern void	zil_destroy_sync(zilog_t *zilog, dmu_tx_t *tx);
+extern boolean_t zil_destroy(zilog_t *zilog, boolean_t keep_first, int *errp);
+extern int	zil_destroy_sync(zilog_t *zilog, dmu_tx_t *tx);
```

`zil_destroy_sync()` returns the error instead of discarding it. Note the
return type changes from `void` to `int`:

```diff
-void
+int
 zil_destroy_sync(zilog_t *zilog, dmu_tx_t *tx)
 {
 	ASSERT(list_is_empty(&zilog->zl_lwb_list));
-	(void) zil_parse(zilog, zil_free_log_block,
-	    zil_free_log_record, tx, zilog->zl_header->zh_claim_txg, B_FALSE);
+	return (zil_parse(zilog, zil_free_log_block,
+	    zil_free_log_record, tx, zilog->zl_header->zh_claim_txg, B_FALSE));
 }
```

`zil_destroy()` keeps its `boolean_t` return, which means "there were entries
to replay", and reports the error through an optional out-parameter. `errp` is
set on every exit path and every dereference is NULL-guarded, so existing
callers can pass `NULL`:

```diff
 boolean_t
-zil_destroy(zilog_t *zilog, boolean_t keep_first)
+zil_destroy(zilog_t *zilog, boolean_t keep_first, int *errp)
 {
 	const zil_header_t *zh = zilog->zl_header;
 	lwb_t *lwb;
 	dmu_tx_t *tx;
 	uint64_t txg;
+	int error = 0;
+
+	if (errp != NULL)
+		*errp = 0;
 
 	/*
 	 * Wait for any previous destroy to complete.
 	 */
 	txg_wait_synced(zilog->zl_dmu_pool, zilog->zl_destroy_txg);
@@
 	} else if (!keep_first) {
-		zil_destroy_sync(zilog, tx);
+		error = zil_destroy_sync(zilog, tx);
 	}
 	mutex_exit(&zilog->zl_lock);
 
 	dmu_tx_commit(tx);
 
+	if (errp != NULL)
+		*errp = error;
+
 	return (B_TRUE);
 }
```

`zil_suspend()` is the only caller that acts on the error. It is on the
`spa_reset_logs()` -> `spa_vdev_remove_log()` path, which is what makes the
failure visible to the removal:

```diff
-	if (error == 0)
-		zil_destroy(zilog, B_FALSE);
+	if (error == 0) {
+		int destroy_error = 0;
+		(void) zil_destroy(zilog, B_FALSE, &destroy_error);
+		if (destroy_error != 0)
+			error = destroy_error;
+	}
```

`zil_replay()` has two call sites. Both pass `NULL`, preserving current
behaviour exactly, including the first one's return value:

```diff
 	if ((zh->zh_flags & ZIL_REPLAY_NEEDED) == 0) {
-		return (zil_destroy(zilog, B_TRUE));
+		return (zil_destroy(zilog, B_TRUE, NULL));
 	}
@@
-	zil_destroy(zilog, B_FALSE);
+	(void) zil_destroy(zilog, B_FALSE, NULL);
 	txg_wait_synced(zilog->zl_dmu_pool, zilog->zl_destroy_txg);
```

### Known open questions in this patch

- `zil_suspend()` returns the new error to `zil_reset()` and thence to
  `spa_reset_logs()`. Whether the suspend state is correctly unwound on that
  new error path has not been checked. The existing code already returns
  non-zero from this function for other reasons, so the path is not new, but
  the interaction has not been verified.
- ZTS coverage: none written, and it is now outstanding work. Finding 15
  produced the condition this patch handles (`../FINDINGS.md` finding 15): at
  `FAILMODE=continue` the read fails fast, `zil_parse()` returns an error,
  `zil_destroy_sync()` discards it via the `(void)` cast and `zpool remove`
  reports `exit=0` silently, with no `cmn_err` because `zil_parse()` only warns
  on a claimed chain. See
  [`../evidence/2026-07-31-failmode-and-spa-log-clear.txt`](../evidence/2026-07-31-failmode-and-spa-log-clear.txt):107-117.

  The harness invocation that produces the case is
  `FAILMODE=continue sudo -E ../07-path-h-yank-live-log.sh`. A ZTS test for
  Patch F can be built from it. No such test has been written. This is
  outstanding work, not a blocked item.
- The out-of-`zil.c` callers listed under "The change" are not covered by the
  hunks below, so the patch will not build until they are updated.

Writing the ZTS test described above is the next step for Patch F.
