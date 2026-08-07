# The incident

Side 1 of the repository covers the real-world event. A 12-disk, 2x raidz2 pool
(`storage`, 186 T raw and 140 T allocated as reported by `zpool list`) became
unimportable after its mirrored SLOG failed and was removed, and this directory
holds everything that belongs to that event and to the repair performed on the
affected hardware.

| Path | What it is |
|---|---|
| [`recovery-breakdown.md`](recovery-breakdown.md) | The three-day recovery, start to finish: four wrong diagnoses, the SysRq-W breakthrough, both on-disk repairs, and verification on stock ZFS. Self-contained: stack traces in Appendix A, the full patch set as applied in §15. |
| [`patches/`](patches/) | One `README.md` and nothing else. There are no `.patch` files in this repository and nothing here is `git am`-able. That file records Patches A to D as documented diffs and prose. B, C (incident form) and D were written, built, applied and ran on the affected hardware. Patch A was written, built and loaded, but on the source reading it was a no-op and cannot have changed the hole path ([`../CLAIMS.md`](../CLAIMS.md) 1.12); the repair is attributable to Patch B. The corrected form of A, and the recommended `zfs_panic_recover()` form of C, have never been written into a build or run; the latter exists only as a paragraph of prose. The runtime tunables used during the repair import are in [`recovery-breakdown.md`](recovery-breakdown.md) §15, not here. |
| [`evidence/2026-07-30-post-repair-history.txt`](evidence/2026-07-30-post-repair-history.txt) | Selected private `zpool history -il` excerpt documenting the completed post-repair scrub and repeated imports. This is the only file in `evidence/`. |

`recovery-breakdown.md` §9 explains the hang as "a hole vdev plus a dataset ZIL
header holding a non-zero DVA that resolves to it". That state is not sufficient
to cause the hang. It was synthesised in the test environment and imported
writable on stock `zfs-2.4.3`: exit 0, pool ONLINE, twice from pristine state
(`CLAIMS.md` 2.7, `../reproducibility/FINDINGS.md` finding 16). The claimed-chain
variant does not hang either; it fails fast with `I/O error` and also fails
read-only, which the affected pool did not (`CLAIMS.md` 2.8, 2.9, finding 17).

The incident happened, and its SysRq-W stack is OBSERVED (`CLAIMS.md` 1.2). What
is unknown is what the affected pool had that the synthesised pool did not. As
of finding 17 no candidate is favoured over any other. Details are inline in
`recovery-breakdown.md` §9.

## Evidence tiering, per artifact

Only the nine tiers in [`../CLAIMS.md`](../CLAIMS.md) §1 (lines 9-23) are used.

| Artifact | Tier | Note |
|---|---|---|
| The incident itself: the hang, its stack, the pool state, both repairs, the clean post-repair scrub | OBSERVED | `CLAIMS.md` 1.1-1.9. Read the limitation below before relying on it |
| The mechanism connecting the pool state to the hang | Incomplete; the missing ingredient is UNKNOWN | `CLAIMS.md` 2.7, 2.8, 2.9. The state alone does not hang a writable import on `zfs-2.4.3`, in either chain form |
| That a scrub validates Patch D's rewritten space maps | Partial only | A scrub checks checksums of reachable blocks. It does not audit space-map correctness. Strong evidence for Patch B, partial for Patch D. See `CLAIMS.md` 1.8-1.9 |
| Patch B, C (incident form), D, built, loaded and run on the affected pool | OBSERVED | `CLAIMS.md` 1.4-1.8 |
| Patch A's applied form being a no-op for the hole path | SOURCE (+ OBSERVED for the applied text itself) | `CLAIMS.md` 1.12 |
| Patch A's corrected form | UNTESTED | Written while writing this up; never built, never run |
| Patch C's recommended `zfs_panic_recover()` form | UNTESTED | No code exists; it is a paragraph in [`patches/README.md`](patches/README.md) |
| Why `spa_ld_verify_logs()` did not block on the repair import | UNKNOWN | `CLAIMS.md` 1.13 |
| The `failmode` attempts recorded in `recovery-breakdown.md` Appendix B | Unbacked testimony, no tier | `CLAIMS.md` 3.23: the source reasoning (3.23-3.26) is SOURCE, but the claim that the attempts were made is first-hand report only, with no captured output preserved. See Appendix B's own tier note |
| Everything on the other side of the repository | see [`../reproducibility/`](../reproducibility/) | REPRODUCED / SOURCE / DISPROVED, per claim |

## The evidence reality, stated plainly

`evidence/` contains exactly one file, the `zpool history -il` excerpt, and it
is the only captured artifact in this directory.

The stack traces, `zdb` captures, panic strings, dbgmsg lines and byte-level
verifications in the 1500-odd-line `recovery-breakdown.md` are all transcribed
prose with no accompanying artifact. The underlying debugging
session logs are private and unpublished because they contain credentials and
management addresses. The transcriptions are selectively abridged, and a
sceptical reader cannot diff any of them against a source.

This is disclosed at [`../CLAIMS.md`](../CLAIMS.md) §6b ("The honest limitation
on OBSERVED"). OBSERVED means "happened on the affected hardware, with captured
output"; for almost everything here, that captured output is a first-hand
transcription, not a published file. Read it as a first-hand report, not as
independently verifiable evidence.

This is a case study, not a reproducer. The hardware has been repaired and
returned to service, so the failure state no longer exists and nothing here can
be re-run. See [`../CLAIMS.md`](../CLAIMS.md) §1 and §6b for exactly what that
does and does not establish.

Everything that can be re-run from scratch on a stock system is on the other
side, in [`../reproducibility/`](../reproducibility/).
