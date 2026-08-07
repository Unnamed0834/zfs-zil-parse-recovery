#!/usr/bin/env bash
#
# HYPOTHESIS C: make the log device FAIL, then remove it while the pool is live.
#
# RATIONALE: spa_vdev_remove() calls spa_reset_logs(), which runs
# zil_reset -> zil_suspend -> zil_commit_impl on every dataset before the vdev
# becomes a hole (see evidence/2026-07-29-spa_reset_logs-stack.txt). That is
# what normally prevents this defect. The affected pool's log SSDs were
# flickering between available and unavailable, so those per-dataset commits
# would have FAILED rather than completed.
#
# The pool must NOT be frozen here. Freezing makes zil_commit_impl BLOCK
# forever instead of failing, which deadlocks the removal and teaches nothing
# (FINDINGS.md finding 4).
#
# The question this answers: when spa_reset_logs() cannot commit, does ZFS
# refuse the removal, or does it produce a hole anyway and leave a dangling
# header?
#
# ALREADY ANSWERED: outcome 2 below. This script has been run on 2.4.1, 2.2.2,
# 2.3.4 and 2.4.3 (FINDINGS.md finding 5). Every time: removal succeeded
# despite 100% injected I/O errors on the log, a hole was created, ~170 data
# errors were reported, and every zh_log was still cleared. Re-running it
# reconfirms that on a new version; it is not an open question on these four.
#
# DANGER: ends at a decision point that may hang the machine. Read step 6.
#
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool
command -v zinject >/dev/null || bail "zinject missing (apt install zfs-test)"

trap 'note "leaving state on disk for inspection; run ./teardown.sh when done"' EXIT
teardown
record_env

say "1. pool with a top-level log vdev, NOT frozen"
make_pool

say "2. synchronous writes so the ZIL holds live records"
write_sync 40

say "3. fail the log device: unconditional I/O errors on all operations"
zinject -d "$SLOG" -e io -T all "$POOL" || note "zinject rejected the handler"
zinject | sed 's/^/      /'

say "4. keep writing so records are queued against the failing log"
write_sync 10 || note "writes errored, which is expected"

say "5. attempt removal while spa_reset_logs() cannot commit"
note "watch for: does this fail cleanly, or produce a hole regardless?"
timeout 90 zpool remove "$POOL" "$SLOG"
RC=$?
note "remove exit=$RC"
[ "$RC" -eq 124 ] && note "TIMED OUT: likely blocked in zil_commit_impl; see finding 4"

say "6. clear injection and record the resulting config"
zinject -c all >/dev/null 2>&1 || true
timeout 60 zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /' \
    || note "status timed out"
rm -f "$SLOG"
timeout 120 zpool export -f "$POOL" 2>/dev/null || note "export refused"

inspect_precondition

say "verdict"
note "OUTCOME 1  removal refused, no hole        -> ZFS is correct here; the"
note "           affected pool reached its state another way."
note "OUTCOME 2  hole created, all zh_log zero   -> reset succeeded despite the"
note "           errors; path ruled out. THIS IS WHAT HAPPENED on 2.4.1,"
note "           2.2.2, 2.3.4 and 2.4.3 (finding 5)."
note "OUTCOME 3  hole created, a zh_log NON-ZERO -> REPRODUCED. This is the"
note "           defect. Proceed to the 'Capturing a hang' section of README.md to capture the hang."
note ""
note "Record whichever outcome occurred in ATTEMPTS.md with the ZFS version."
