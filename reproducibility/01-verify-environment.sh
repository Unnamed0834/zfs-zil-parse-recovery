#!/usr/bin/env bash
#
# SAFEST script here, and the one to run first. It verifies the factual claims
# in FINDINGS.md. It does not fail a device and does not attempt a writable
# import of a suspect pool, so it has never hung a machine in any recorded run
# (2.3.4, 2.4.1, 2.4.3; all six checks pass on all three). Never run on
# 2.2.2 -- availability there is UNTESTED. See CLAIMS.md 3.16.
#
# It is NOT proved incapable of hanging. Step 3 exports a FROZEN pool, and step
# 4 removes a log vdev from a pool that is only thawed if step 3's reimport
# succeeded. Per FINDINGS.md finding 4 a frozen pool cannot sync a txg, so a
# removal against one blocks forever. Both commands are therefore wrapped in
# `timeout 60` and both report loudly on expiry. A `timeout` cannot kill a task
# already in uninterruptible D-state, so treat a 124 exit as a warning to stop
# and inspect, not as a recovery.
#
# Run this first, and run it before trusting anything else in this folder.
#
# Proves:
#   finding 2  `zpool freeze` is available on a stock distro build
#   finding 3  removing a top-level log vdev produces type:'hole', is_hole:1
#
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root

trap teardown EXIT
teardown
record_env

say "1. create a pool with a separate top-level log vdev"
make_pool
zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
grep -q 'logs' <(zpool status "$POOL") && ok "log vdev present" || bad "no log vdev"

say "2. finding 2: is zpool freeze available on this build?"
if zpool freeze "$POOL" 2>/dev/null; then
    ok "zpool freeze accepted (no debug build required)"
    FROZE=1
else
    bad "zpool freeze rejected on this build"
    FROZE=0
fi

say "3. thaw so the pool is usable again"
# There is no `zpool unfreeze`. Export/import clears the frozen state.
# The pool is FROZEN at this point and a frozen pool cannot sync a txg
# (finding 4), so this export can block. 60 s is generous for a file-backed
# scratch pool of this size.
timeout 60 zpool export -f "$POOL" 2>/dev/null
XRC=$?
if [ "$XRC" -eq 124 ]; then
    bad "EXPORT TIMED OUT after 60s on a FROZEN pool (finding 4)."
    note "timeout cannot kill a task already in uninterruptible D-state."
    note "Stop here and inspect: cat /proc/\$(pgrep -x zpool)/stack"
elif [ "$XRC" -ne 0 ]; then
    note "export refused (exit=$XRC)"
fi
zpool import -d "$WORK" -o cachefile=none "$POOL" 2>/dev/null \
    && ok "reimported after freeze" || bad "could not reimport"

say "4. finding 3: does removing the log vdev create a hole?"
# Also timed out: if step 3 did not thaw the pool, this removal would block
# forever waiting for a txg that a frozen pool can never sync (finding 4).
timeout 60 zpool remove "$POOL" "$SLOG"
RRC=$?
if [ "$RRC" -eq 0 ]; then
    ok "removal accepted"
elif [ "$RRC" -eq 124 ]; then
    bad "REMOVAL TIMED OUT after 60s: the pool is probably still frozen."
    note "timeout cannot kill a task already in uninterruptible D-state."
    note "Stop here and inspect: cat /proc/\$(pgrep -x zpool)/stack"
else
    bad "removal rejected (exit=$RRC)"
fi
sleep 2
zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
zpool export "$POOL" 2>/dev/null || true

say "5. inspect the resulting vdev tree"
TREE=$(zdb -e -p "$WORK" -C "$POOL" 2>/dev/null)
echo "$TREE" | grep -E 'vdev_children|hole_array|is_hole|type:' | sed 's/^/      /'
echo
echo "$TREE" | grep -q "is_hole: 1" \
    && ok "finding 3 CONFIRMED: removed log vdev became a hole" \
    || bad "finding 3 NOT confirmed on this build"

say "6. control: is the pool still importable read-write?"
if timeout 120 zpool import -d "$WORK" -o cachefile=none "$POOL"; then
    ok "clean removal leaves an importable pool, as designed"
    zpool export "$POOL" 2>/dev/null
else
    bad "unexpected: import failed after a clean removal"
fi

say "summary"
note "A cleanly removed log vdev becomes a hole AND the pool stays importable,"
note "because spa_vdev_remove() resets every dataset ZIL first. That is the"
note "mechanism the defect must defeat. See FINDINGS.md finding 1 and"
note "evidence/2026-07-29-spa_reset_logs-stack.txt."
