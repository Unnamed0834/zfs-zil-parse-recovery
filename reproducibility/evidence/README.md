# Evidence

The raw captured artifacts, verbatim tool output rather than summaries.

| File | What it establishes |
|---|---|
| `2026-07-29-zil_parse-removal-hang-2.2.2.txt` | A separately reportable bug, with a verified stack. (No prior OpenZFS report of this hang on the removal path was located; the tracker search behind that is not recorded, so treat novelty as unestablished. The reproducer is not in doubt.) `zpool remove` of a log device with a failing backing device hangs unkillably in `zil_parse` -> `arc_read` -> `zio_wait`. Reproduced from scratch on stock ZFS 2.2.2. Note the in-file correction: `zil_parse()` does have an error path; it is never reached. See `../FINDINGS.md` finding 10. |
| `2026-07-29-spa_reset_logs-stack.txt` | Log-vdev removal calls `spa_reset_logs()` before creating the hole. Captured against a frozen pool, so it shows the call path is entered, not that the walk completes. The "non-atomic removal" conclusion recorded in the file is superseded by finding 9; the file preserves it verbatim with a supersession note. See `../FINDINGS.md` findings 1 and 9. |
| `2026-07-30-zfs-2.3.4-1-test-results.txt` | ZFS 2.3.4 behaves identically to 2.2.2 on all five tests, and to 2.4.1 on the three where both were run. `06` and `07` were never run on 2.4.1, so neither has a 2.4.1 comparison. Note: this is the `zfs-2.3.4` release tag, not the incident's build (`zfs-2.3.3-107-gec5aa9bfd`), and not the incident's repair tree (`zfs-2.4.3`); none of the test trees carries amotin's `1e1d64d`. See `../../CLAIMS.md` 3.29. |
| `2026-07-30-zil_parse-removal-hang-2.3.4.txt` | `zpool remove` hung on ZFS 2.3.4 as well. Weaker evidence than the 2.2.2 capture: a 120-second timeout with no stack trace. That the hang is at the same frame is inferred, not observed. `../ATTEMPTS.md` was downgraded on 2026-07-31 to match what this file actually says. See `../FINDINGS.md` finding 13. |
| `2026-07-31-zfs-2.4.3-test-results.txt` | The hardened tree, and the incident's own repair commit (`83020cf`). Four precondition paths behave identically to 2.2.2/2.3.4, and the removal hang reproduces with a captured stack, the second verified stack in this repository and the first outside 2.2.2. Also records the one behavioural difference found anywhere in this work: `txg_quiesce` is not wedged on 2.4.3. Includes the provenance checks proving `1e1d64d` is present. See `../FINDINGS.md` finding 14. |
| `2026-07-31-failmode-and-spa-log-clear.txt` | The `failmode` mechanism, settled for the removal case in the test environment. `07` at `continue` (no hang), at `panic` (kernel panic with `zio_suspend` in the trace), against `wait` (hangs). Establishes claim 2.6 for the removal case in the test environment. Note the file's own caveat that the `panic` run fires before `zpool remove` is issued and so does not isolate the `zil_parse()` read. Also eliminates `SPA_LOG_CLEAR` persistence as the explanation for claim 1.13, four ways. See `../FINDINGS.md` finding 15. |
| `2026-07-31-zfs-2.4.3-raw-captures.txt` | Unedited underlying output for the files above: the `/proc/<pid>/stack` capture of the removal hang, the kernel hung-task `dmesg`, both `failmode=panic` kernel panic traces from the guest serial console, and the `zdb -R` hole-vdev probe with its control read on a healthy vdev and a `timeout 60` watchdog. §6, appended 2026-07-31: the finding-14 hung-task trace recovered from the guest's persistent systemd journal (`journalctl -b -5 -k`). §5's statement that the logs "were not retained" is true of the serial logs only: the journal survived the forced power cycles, so finding 14's watchdog trace exists as a machine-generated artifact that can be diffed against the transcription, and `txg_quiesce`'s absence from that boot's kernel log is machine-generated confirmation of claim 2.2's "NOT REPRODUCED on 2.4.3", previously supported only by a live `ps` reading. |
| `2026-07-31-precondition-synthesis.txt` | Two results. Affirmative: the incident's precondition synthesised for the first time and verified at DVA level (`hole_array[0]: 2`, `DVA[0]=<2:15e6000:11000>`), which shows that skipping `spa_reset_logs()` strands headers. Note the limit, recorded in the file itself: the hook fired at `vs_alloc 22.0M`, so the `vs_alloc == 0` gate condition of claim 4.1 was not reproduced and that half stays INFERRED. Negative, and the more consequential: imported writable on stock `zfs-2.4.3`, it did not hang. Establishes claim 4.9's mechanism (`vdev_mirror_ops`, not `vdev_missing_io_start()`) while confirming its conclusion. Its "unexplained artifact" and "what could not be tested" sections are superseded by the claimed-chain file below. See `../FINDINGS.md` finding 16. |
| `2026-07-31-claimed-chain-variant.txt` | The last named lead, closed negatively. The claimed-chain variant, recorded in finding 16 as BLOCKED and as "the single most promising open lead", tested on stock `zfs-2.4.3` (module md5-verified byte-identical to the archived stock module; the debug hook was not loaded). It does not hang: `cannot import 'ziltest': I/O error`, exit 1, no D-state task, three runs. `zil_check_log_chain()` did not block, confirmed by ftrace, not inferred (entered 4 times, `zil_parse` 3 times, load proceeded past both). It fails at `spa_load_verify()` with EIO because `zfs_blkptr_verify()` rejects the ZIL blkptr for naming a hole vdev; `traverse_zil_block()` (`dmu_traverse.c:93-98`) is why the unclaimed chain never got that far. Also explains finding 16's "unexplained label artifact" and exonerates the debug hook. Read-only import fails too, which diverges from the incident (CLAIMS 1.1). One tempting hypothesis DISPROVED by release-tag grep: the hole-vdev check is present in every release from `zfs-2.2.2` to `master`. REPRODUCED (negative), `zfs-2.4.3` only. See `../FINDINGS.md` finding 17. |

Each file records the host, guest, ZFS version and the commands used, so the
result can be re-derived rather than taken on trust, for the results that have
a file here. Many do not. The coverage table below says which.

Three of these files carry in-file corrections to conclusions stated when they
were captured. The corrections are dated and marked, and the original text is
preserved. Read the whole file, not just the summary line above.

## Coverage: which findings have an artifact, and which do not

`../FINDINGS.md` has eighteen findings. Eleven of them have no evidence file
here and rest on prose alone. That matters most for the "RULED OUT" routes,
because seven of the nine routes underpinning the headline bounded negative
are in that group. The claim that these results "can be re-derived rather than
taken on trust" is true only of the rows marked with a file.

| Finding | Subject | Artifact |
|---|---|---|
| 1 | log removal resets every dataset ZIL | `2026-07-29-spa_reset_logs-stack.txt` (frozen pool; shows the call path entered, not the walk completing) |
| 2 | `zpool freeze` on the builds tested | no artifact: prose only. Three builds, not four: `01` was never run on 2.2.2 (`../ATTEMPTS.md`, corrected 2026-08-02) |
| 3 | removal produces the hole signature | no artifact: prose only (the DVA-level version is finding 16's file) |
| 4 | freeze + remove deadlocks | no artifact: prose only |
| 5 | `zinject`-failed log: headers still cleared | no artifact: prose only for 2.4.1 and 2.2.2; summarised for 2.3.4 in `2026-07-30-zfs-2.3.4-1-test-results.txt` and for 2.4.3 in `2026-07-31-zfs-2.4.3-test-results.txt` |
| 6 | encrypted-dataset replay guard refuses removal | no artifact: prose only for 2.4.1 and 2.2.2; summarised for 2.3.4 and 2.4.3 in the two files above |
| 7 | `import -m` leaves UNAVAIL, not a hole | no artifact: prose only |
| 8 | `SPA_LOG_CLEAR` clears headers, encrypted included | no artifact: prose only |
| 9 | the `vs_alloc` gate | no artifact: prose only for the source reading and the 2.2.2 run; summarised for 2.3.4 and 2.4.3 in the two version files |
| 10 | `zpool remove` of a failing log hangs unkillably | `2026-07-29-zil_parse-removal-hang-2.2.2.txt` (captured stack), and `2026-07-30-zil_parse-removal-hang-2.3.4.txt` (timeout only, no stack) |
| 11 | `zpool offline` drives `vs_alloc` to 0 and drains the ZIL (single log; not a redundant log on `master`, see 3.18) | no artifact: prose only. One run, one version (2.2.2). `CLAIMS.md` 3.18 is PARTIALLY TESTED for this reason |
| 12 | enumeration of the routes tried | no artifact: it is an enumeration, not a run |
| 13 | 2.3.4 behaves as 2.2.2 | `2026-07-30-zfs-2.3.4-1-test-results.txt`, `2026-07-30-zil_parse-removal-hang-2.3.4.txt` |
| 14 | 2.4.3: same behaviour, hang with a stack | `2026-07-31-zfs-2.4.3-test-results.txt`; raw stack, watchdog `dmesg` and recovered journal trace in `2026-07-31-zfs-2.4.3-raw-captures.txt` §§1, 2, 6 |
| 15 | `failmode` is the mechanism of the hang in the test environment | `2026-07-31-failmode-and-spa-log-clear.txt`; panic traces in `2026-07-31-zfs-2.4.3-raw-captures.txt` §3 |
| 16 | precondition synthesised; does not hang unclaimed | `2026-07-31-precondition-synthesis.txt`; `zdb -R` probe and control in `2026-07-31-zfs-2.4.3-raw-captures.txt` §4 |
| 17 | claimed-chain variant: does not hang either | `2026-07-31-claimed-chain-variant.txt` |
| 18 | the removal hang was reported upstream in 2013 as #1585 | no artifact: it is a tracker reading, not a run. The thread is public at `https://github.com/openzfs/zfs/issues/1585` |

Two further gaps worth naming, because they are not findings and so do not
appear above:

- The positive-control calibration of the detection method has no artifact and
  no finding number (`../ATTEMPTS.md`, 2026-07-29, "hard power cut with 19,112
  ZIL records in flight"). Every "all headers cleared" negative in this
  repository depends on `zdb -i` detecting a non-zero `zh_log`, and that is
  what this run calibrated. Nothing was saved but the log row.
- The source-review rows are reading, not capture. Of the eight
  source-review and commit-archaeology rows dated 2026-07-31, none has saved
  `grep` or `sed` output. In particular the row asserting which releases carry
  `1e1d64d` says each of eight tags was fetched and grepped, but only the
  `zfs-2.4.3` greps are preserved (in `../ENVIRONMENT.md`, as the `zfs243`
  pre-test verification commands). The release-tag grep in finding 17 is in the
  same position: the per-tag line numbers are transcribed into the
  claimed-chain file, the raw output is not saved. `../ATTEMPTS.md` marks each
  such row `[no artifact]` or `[partial artifact]`.
