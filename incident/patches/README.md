# Patches applied during the incident

Four logical patches, developed against the CachyOS `/usr/src/zfs-2.4.3`
source. A, B, C (incident form) and D were built into a module that was loaded
and run on the affected pool during the recovery. Only B, C and D changed
behaviour there: Patch A, on the source reading, was a no-op
([`../../CLAIMS.md`](../../CLAIMS.md) 1.12). They are presented here as
documented diffs and prose.

Scope note. "Run" is not the same as "worked": see the correction under Patch A,
which was built and loaded but, on the source reading, cannot have changed the
behaviour it was written to change. The `zfs_panic_recover()` form of C
recommended elsewhere in this repository is not in this file and has never been
written or run; only the unconditional skip below was executed.

## Status at a glance

Tiers are the nine in [`../../CLAIMS.md`](../../CLAIMS.md) §1 (lines 9-23).
"Code exists" means source text exists somewhere in this repository; it does
not mean an applicable `.patch` file exists; see the note below the table.

| Patch / form | Code exists? | Built? | Loaded and run? | Changed behaviour on the pool? | Tier |
|---|---|---|---|---|---|
| A, as applied | Yes, quoted below | Yes | Yes | No; no-op for the hole path (1.12) | SOURCE (the no-op analysis) + OBSERVED (the applied text) |
| A, corrected form | Yes, quoted below | No | No | n/a | UNTESTED |
| B | Yes, quoted below | Yes | Yes | Yes; this is the patch that repaired the pool (1.12) | OBSERVED |
| C, incident form (unconditional skip) | Yes, quoted below | Yes | Yes | Yes | OBSERVED. Must never be reused |
| C, recommended `zfs_panic_recover()` form | NO CODE AT ALL. It exists only as one paragraph of prose in this file. | No | No | n/a | UNTESTED |
| D | Yes, quoted below | Yes | Yes | Yes | OBSERVED |

The two rows that matter most for anyone reading this as a patch set:

- Patch A's corrected form was written, never built and never run. It is
  the only form of A that would do anything, and no compiler has seen it.
- Patch C's recommended form does not exist. It is the only form of C this
  repository considers fit to propose upstream, and there is no code for it,
  only the paragraph under "Patch C" below. Anyone taking C forward has to
  write it first.

Line numbers and context are against the `zfs-2.4.3` release tag, commit
`83020cf`. That tag is independently confirmed as the incident's lineage: the
recovery module reported itself as `zfs-2.4.3-0-g83020cf-dirty-dist`. Every
source line cited in this repository is indexed against both `zfs-2.4.3` and
`master` in [`../../CLAIMS.md`](../../CLAIMS.md) §7.

There are no `.patch` files in this directory, and nothing here is
`git am`-able. The patches are recorded as documented diffs with surrounding
context, which is enough to review the logic but not to apply mechanically.
Before submission each must be regenerated with `git format-patch` against
current `openzfs/zfs` master, so that context lines, line numbers and hunk
offsets match the tree being patched.

Patch C / Patch D boundary: this file is authoritative.
[`../recovery-breakdown.md`](../recovery-breakdown.md) §15 draws the C/D line
in a different place, so the same code carries two different labels depending
on which document you read. To be unambiguous:

| Code | Labelled here | Labelled in `recovery-breakdown.md` §15 |
|---|---|---|
| `space_map_load_callback()`: `VERIFY3U` replaced by a warn-and-skip | C | C |
| `smla_ncorrupt` field in `space_map_load_arg_t` | D | C |
| `space_map_load_length()` signature widened with `uint64_t *ncorruptp` | D | C |
| `space_map_load()` passing `NULL` | D | C |
| `include/sys/space_map.h` declaration change | D | C |
| `metaslab_load_impl()`: forced condense on `ncorrupt > 0` | D | D |

Use the grouping in this file. It matches the functional split recorded in
[`../../CLAIMS.md`](../../CLAIMS.md) §5 (C is "space-map assertion made
recoverable", D is "force metaslab condense to rewrite a corrupt space map,
depends on C"), and the counter plumbing exists solely to carry the count from
the loader to the condense trigger, which is D's job.

What actually ran does not decide this, and it is important to say so. All of C
and D were compiled into a single module and loaded together on the affected
pool; there was never a build with one and not the other. The split is
editorial, not historical. Note also that the two are not independently
applicable in either grouping: C's callback body increments
`smla->smla_ncorrupt`, which does not compile without D's struct field. Anyone
reconstructing "Patch C" from this file alone gets code that will not build
until D's struct change is applied as well.

---

## Patch A

`module/zfs/zil.c`, `zil_check_log_chain()`.

Two facts about the applied form, before the diffs:

1. The NULL check was never applied. The recovery machine's source, read back
   verbatim from `/usr/src/zfs-2.4.3/module/zfs/zil.c:1322`, contains no NULL
   check. The NULL check in the corrected form below is a later, untested
   addition made while writing this up. It is still worth having (see "The
   latent NULL dereference" below) but it must not be described as validated.
2. The guard extension, as applied, does not change behaviour for a hole. It
   routes the hole case into `vdev_log_state_valid()`, which returns `B_TRUE`
   for a hole, so `valid` stays true and the early return never fires. See "Why
   the applied form is a no-op". The repair of the affected pool is attributable
   to Patch B, not to Patch A.

### What was actually applied

Read back from the recovery machine on 2026-07-22, `zil.c:1300-1320`:

```c
	if (!BP_IS_HOLE(bp)) {
		vdev_t *vd;
		boolean_t valid = B_TRUE;

		spa_config_enter(os->os_spa, SCL_STATE, FTAG, RW_READER);
		vd = vdev_lookup_top(os->os_spa, DVA_GET_VDEV(&bp->blk_dva[0]));
		if ((vd->vdev_islog && vdev_is_dead(vd)) || vd->vdev_ishole)
			valid = vdev_log_state_valid(vd);
		spa_config_exit(os->os_spa, SCL_STATE, FTAG);

		if (!valid)
			return (0);
```

as a diff against stock:

```diff
  vd = vdev_lookup_top(os->os_spa, DVA_GET_VDEV(&bp->blk_dva[0]));
- if (vd->vdev_islog && vdev_is_dead(vd))
+ if ((vd->vdev_islog && vdev_is_dead(vd)) || vd->vdev_ishole)
          valid = vdev_log_state_valid(vd);
```

The `vdev_lookup_top()` call is `zil.c:1296` and the replaced line is
`zil.c:1297`, in both `zfs-2.4.3` and `master`. (The recovery tree's `1322` is
the same line; that tree also carried the Patch B insertion above it, which
shifts everything below by 25 lines. The documented Patch B accounts for only
19 of those 25; see the note below.)

> Note on the 25-line offset, 2026-07-31. The offset is a useful integrity
> check on the record, and it does not fully close. 1322 - 1297 = 25 lines
> inserted above the guard. The Patch B block documented below is 18 lines,
> plus a `vdev_t *vd;` declaration = 19. Six are unaccounted for.
>
> They can be located. The applied Patch B condition was read back at
> `zil.c:1191` and is the 9th line of the documented block, so 25 - 18 = 7
> lines sit above the block, and 1191 - 7 - 8 puts the insertion point at
> pristine `zil.c:1176/1177`, the closing brace of the
> `if (BP_IS_HOLE(&zh->zh_log))` early return and the blank line after it,
> which is exactly where Patch B belongs. So the block is in the right place
> and is the right size; the six unrecorded lines sit above it. One of the
> seven is the `vd` declaration; the other six are not recorded anywhere here.
> Most plausibly debug output added during the live recovery and never
> transcribed, consistent with the module reporting itself
> `zfs-2.4.3-0-g83020cf-dirty-dist`. That is an inference. The tree no longer
> exists, so those lines are unrecoverable.
>
> Consequence for a reader: the Patch B below is a faithful reconstruction of
> the logic that repaired the pool, not a byte-exact copy of the tree that
> ran. Neither 1.12 (Patch A was a no-op) nor 1.8/1.9 (the repair worked and
> the scrub was clean) depends on this arithmetic; those rest on the patch
> text read back at `:1322` and `:1191` and on the observed outcome.

`vdev_ishole` is a struct field (`include/sys/vdev_impl.h:284`; `master`:
`:276`), not a macro.

### Why the applied form is a no-op

`valid = B_FALSE` is the state that makes `zil_check_log_chain()` return 0 and
skip the chain. The applied guard does not produce it. For a hole vdev, at
`zfs-2.4.3`:

| Step | Value | Source |
|---|---|---|
| `vdev_hole_ops.vdev_op_leaf` | `B_TRUE` | `vdev_missing.c:132` |
| a hole is opened by `vdev_missing_open()`, which returns 0 | success | `vdev_missing.c:46-62`, `vdev_hole_ops.vdev_op_open` at `:112` |
| `vdev_open()` sets `vd->vdev_removed = B_FALSE` on every successful open | `B_FALSE` | `vdev.c:2228`, before the hole early-return at `:2254` |
| `vd->vdev_faulted` | `B_FALSE`: a faulted vdev would have returned `ENXIO` at `vdev.c:2234-2240`; a hole reaches `VDEV_STATE_HEALTHY` at `:2248` | `vdev.c` |
| `vdev_log_state_valid(vd)` = `vdev_op_leaf && !vdev_faulted && !vdev_removed` | `B_TRUE` | `vdev.c:5726` (definition), return expression at `:5728-5730` |

Citation note, 2026-07-31. [`../../CLAIMS.md`](../../CLAIMS.md) §7 indexes
`vdev_log_state_valid()` by its definition line only, `vdev.c:5726` at
`zfs-2.4.3`, `5810` at `master`. The argument above rests on the body, the
three-term return expression at `:5728-5730`, which §7 does not carry a row
for; `CLAIMS.md` 1.12 cites that body range directly. Both numbers are against
`zfs-2.4.3`, commit `83020cf`. Citing `5728-5730` alone does not resolve against
§7.

So `valid` remains `B_TRUE`, `if (!valid) return (0)` at `zil.c:1301-1302` does
not fire, and control reaches the `zil_parse()` call below it. The blocking
path is unchanged.

Note also that `vdev_is_dead()` already returns true for a hole by explicit
design (`vdev.c:4754-4756`: *"Holes and missing devices are always considered
dead"*). The only thing the stock guard fails on is `vdev_islog`, exactly as
`../../CLAIMS.md` 3.1 says. Adding `|| vd->vdev_ishole` fixes the predicate and
then hands the result to a helper that says "valid".

### The corrected form

Written, never built, never run; no compiler has seen this. Tier: UNTESTED. It
sets `valid` directly rather than delegating, and folds in the NULL case:

```diff
  vd = vdev_lookup_top(os->os_spa, DVA_GET_VDEV(&bp->blk_dva[0]));
- if (vd->vdev_islog && vdev_is_dead(vd))
-         valid = vdev_log_state_valid(vd);
+ if (vd == NULL || vd->vdev_ishole)
+         valid = B_FALSE;
+ else if (vd->vdev_islog && vdev_is_dead(vd))
+         valid = vdev_log_state_valid(vd);
```

`vd == NULL` is treated as "not valid" rather than skipped, because an
out-of-range vdev index in a ZIL header DVA is itself a reason not to walk the
chain.

### The latent NULL dereference

Independent of the above, and independent of holes: `zil.c:1297` dereferences
`vd` with no NULL check, and `vdev_lookup_top()` returns NULL for an
out-of-range vdev index. That is a real defect, it is SOURCE-confirmed
(`../../CLAIMS.md` 3.6), and it is a one-line fix. It was not exercised by the
incident and is not validated by anything here.

### Status

Patch A is now a source-only proposal: the guard gap is real (`../../CLAIMS.md`
3.1), the NULL deref is real (3.6), and the corrected form above addresses
both. It is no longer backed by the incident, because the form that ran on the
incident hardware did not affect the hole path.

---

## Patch B

`module/zfs/zil.c`, `zil_claim()`.

Clear the ZIL header when its DVA resolves to a hole vdev, then dirty the
dataset so the correction is committed to disk.

This is the patch that repaired the pool. With Patch A shown to be a no-op for
the hole path (see above), B is the only change in the set that acts on the
dangling header. Read back verbatim from the recovery machine at `zil.c:1191`,
the applied condition was `if (vd != NULL && vd->vdev_ishole) {`, identical to
the code below.

Open question this correction raises. If Patch A did not skip the chain, then
`spa_ld_verify_logs()` -> `spa_check_logs()` -> `zil_check_log_chain()` ran
ahead of `zil_claim()` (`spa.c:6106` before `spa.c:6175`) and should have
blocked before B ever executed. It did not: the repair import completed and the
space-map skip warnings fired. Why verify was survivable on the recovery
environment is not established, and it is the same shape of question as
`../../CLAIMS.md` 4.9. Claim 1.13 remains UNKNOWN.

Closed candidate: `spa_log_state` surviving as `SPA_LOG_CLEAR` from the earlier
`import -m`. This was the leading explanation: a persisted `SPA_LOG_CLEAR`
would make `spa_check_logs()` return early (`../../CLAIMS.md` 3.4) and never
reach `zil_check_log_chain()`. It is eliminated, four ways plus one specific to
the incident (`../../reproducibility/FINDINGS.md` finding 15):

1. `spa_set_log_state()` assigns an in-core field only (`spa_misc.c:2759`).
2. `spa_log_state` appears zero times in `spa_config.c` and `vdev.c`, so it is
   never serialised to the label or the config.
3. It is recomputed per-import from
   `spa->spa_import_flags & ZFS_IMPORT_MISSING_LOG` in
   `spa_check_for_missing_logs()` (`spa.c:2781`).
4. Experimentally, a plain import after `import -m` + export is refused
   byte-identically to before, i.e. the earlier `-m` left nothing behind.
5. Incident-specific: by repair time the log was a hole, and `spa.c:2825-2826`
   requires `vdev_islog && vdev_state == VDEV_STATE_CANT_OPEN`, which a hole
   never satisfies.

Still open. The remaining candidate is unchanged: the header having been
drained by an earlier writable import under the NOP'd module, which
`../../CLAIMS.md` 4.10 rules out only for the `-N` repair import, not for the
earlier one. Closing one candidate does not answer 1.13; the claim stays
UNKNOWN.

Precedent. The `memset` + `os_encrypted` + `dsl_dataset_dirty()` sequence below
is not new. It is pre-existing upstream code in the `SPA_LOG_CLEAR` path of the
same function, a few lines further down (`zil.c:1217-1220`):

```c
	memset(zh, 0, sizeof (zil_header_t));
	if (os->os_encrypted)
		os->os_next_write_raw[tx->tx_txg & TXG_MASK] = B_TRUE;
	dsl_dataset_dirty(dmu_objset_ds(os), tx);
```

What Patch B adds is the `vdev_ishole` condition that reaches it, and the
decision to omit `zio_free`. Reusing an established in-tree pattern is a point
in the patch's favour, not against it.

Attribution ([`../../CLAIMS.md`](../../CLAIMS.md) 3.22): amotin's `1e1d64d`
changes one line, `BP_ZERO(&zh->zh_log);` to
`memset(zh, 0, sizeof (zil_header_t));`. The
`if (os->os_encrypted) ... os_next_write_raw` and `dsl_dataset_dirty()` lines
are unchanged context and predate that commit. amotin widened the zeroing from
the DVA to the whole header; he did not create the sequence. The pattern Patch B
reuses is older than `1e1d64d`, so it does not depend on a 2026 commit.

Inserted in `zil_claim()` after the existing `BP_IS_HOLE(&zh->zh_log)` early
return (`zil.c:1173`), before `first_txg = spa_min_claim_txg(...)`.
`vdev_t *vd;` must be added to the function's locals; omitting it is what
produced the `use of undeclared identifier 'vd'` compile errors recorded in
`../recovery-breakdown.md` §11.

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

Design decisions:

- `memset` plus `dsl_dataset_dirty` is deliberate, and follows the existing
  `SPA_LOG_CLEAR` precedent above. Skipping the chain would leave the dangling
  reference on disk and the pool non-portable. Committing the cleared header is
  what makes the repair permanent.
- `zio_free` is deliberately omitted. The blocks reside on a vdev that no
  longer exists, so freeing them is not possible and attempting it is the
  hazardous option.
- Lock safety: `spa_ld_claim_log_blocks()` (`spa.c:5646`; `master`: `5703`)
  performs only `dmu_tx_create_assigned` plus
  `dmu_objset_find_dp(..., zil_claim, tx, DS_FIND_CHILDREN)` and does not hold
  `SCL_STATE`, so acquiring it as a reader here is safe.

---

## Patch C (incident form only)

`module/zfs/space_map.c`, `space_map_load_callback()`. The replaced `VERIFY3U`
statement spans `space_map.c:406-407` in pristine `zfs-2.4.3` (`master`:
`405-406`); the incident's panic text reports `:407`.

Shown in situ, so that what was deleted and what surrounds it are both visible.
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

`smla->smla_ncorrupt++` above needs the `smla_ncorrupt` field, which this file
groups under Patch D; see the C/D boundary table near the top. C does not
compile on its own.

This downgrades a data-integrity assertion unconditionally, for every pool. It
was correct for one-off recovery with no backup and no alternative. It is not
acceptable as a default and must never be reused.

The form that would be appropriate for general use replaces the `VERIFY3U` with
`zfs_panic_recover()`, so behaviour is unchanged at `zfs_recover=0` and the
condition becomes survivable only when the pool's administrator has explicitly
opted in. That form has not been written and has never been run. There is no
code for it anywhere in this repository; it exists only as this paragraph. It
is at the same time the only form of C this repository considers fit to propose
upstream (`../../CLAIMS.md` §5, Patch C row). Anyone proposing C upstream has
to write it first. Tier: UNTESTED.

---

## Patch D

Forced metaslab condense when the space-map loader reports corrupt entries,
plus the plumbing that carries the corruption count out of the loader.

Grouping note. [`../recovery-breakdown.md`](../recovery-breakdown.md) §15 puts
the three plumbing changes below (the `smla_ncorrupt` field, the
`space_map_load_length()` signature widening and the `space_map.h` declaration)
under Patch C instead. This file's grouping is the authoritative one; see the
C/D boundary table near the top.

Requires the corruption count to be plumbed out of the space-map loader.

`space_map.c`, adding a counter to the load argument struct:

```diff
  typedef struct space_map_load_arg {
  	space_map_t	*smla_sm;
  	zfs_range_tree_t	*smla_rt;
  	maptype_t	smla_type;
+ 	uint64_t	smla_ncorrupt;
  } space_map_load_arg_t;
```

`space_map.c`, widening the signature and reporting the count:

```diff
  int
  space_map_load_length(space_map_t *sm, zfs_range_tree_t *rt, maptype_t maptype,
-     uint64_t length)
+     uint64_t length, uint64_t *ncorruptp)
  {
  	...
+ 	smla.smla_ncorrupt = 0;
  	int err = space_map_iterate(sm, length, space_map_load_callback, &smla);
+ 	if (ncorruptp != NULL)
+ 		*ncorruptp = smla.smla_ncorrupt;
```

`space_map_load()` passes `NULL`, preserving its signature and every other
caller:

```c
int
space_map_load(space_map_t *sm, zfs_range_tree_t *rt, maptype_t maptype)
{
	return (space_map_load_length(sm, rt, maptype,
	    space_map_length(sm), NULL));
}
```

`include/sys/space_map.h`:

```diff
  int space_map_load_length(space_map_t *sm, zfs_range_tree_t *rt,
-     maptype_t maptype, uint64_t length);
+     maptype_t maptype, uint64_t length,
+     uint64_t *ncorruptp);
```

`metaslab.c`, in `metaslab_load_impl()`:

```c
if (msp->ms_sm != NULL) {
        uint64_t ncorrupt = 0;
        error = space_map_load_length(msp->ms_sm, msp->ms_allocatable,
            SM_FREE, length, &ncorrupt);

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
}
```

`ms_condense_wanted` is an existing universal override, not an invention.
`metaslab_condense()` discards the entire on-disk space map and re-emits it
from the in-memory `ms_allocatable` range tree produced by the recovery load.
Patch C prevents the corrupt entries from being added to that tree.
