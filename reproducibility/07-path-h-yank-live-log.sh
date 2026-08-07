#!/usr/bin/env bash
# HYPOTHESIS H (as written): yank the log device from a LIVE pool, then remove
# it. This is hypothesis G with the export/`import -m` step removed, so that
# nothing clears the ZIL headers before the removal (finding 8).
#
# WHAT THIS SCRIPT ACTUALLY DEMONSTRATES -- READ THIS BEFORE THE RATIONALE.
#
# The hypothesis below is NOT what happened, and the script's original header
# said otherwise for two versions' worth of runs. The premise was:
#
#   log holding ZIL records -> device disappears -> vs_alloc drops to 0
#     -> zpool remove SKIPS spa_reset_logs() -> hole with dangling headers
#
# That never occurred. In EVERY recorded run vs_alloc did not reach zero:
#
#   2.3.4  43.9M -> 72K   evidence/2026-07-30-zil_parse-removal-hang-2.3.4.txt:21
#   2.4.3  40.4M -> 72K   evidence/2026-07-31-zfs-2.4.3-test-results.txt:138
#
# 72K is non-zero, so the finding-9 gate stayed CLOSED and spa_reset_logs()
# RAN -- the exact opposite of the premise. What the script found instead, by
# accident, is a different and more serious bug: spa_reset_logs() itself hangs
# unkillably when it tries to commit a dataset ZIL to a log device that is
# failing under a live pool. Findings 10, 13 and 14. Stack captured on 2.2.2
# and 2.4.3:
#
#     zio_wait <- arc_read <- zil_parse <- zil_destroy <- zil_suspend
#       <- dmu_objset_find_impl <- spa_reset_logs <- spa_vdev_remove
#
# spa_namespace_lock is held throughout, so every later zpool command blocks
# and the machine needs a forced power cycle. Reproduced on 2.2.2, 2.3.4 and
# 2.4.3; never run on 2.4.1.
#
# So: this script reproduces the removal hang. It does NOT produce the
# incident's precondition (a hole plus a surviving non-zero zh_log) and never
# has. That state was first produced only via a test-only debug hook, and when
# produced it did NOT hang a writable import on 2.4.3 (finding 16).
#
# DANGER: this script wedges the machine at step 7 under the default failmode.
# Read the capture instructions below BEFORE running it.
#
# ---------------------------------------------------------------------------
# FAILMODE
#
# This script reproduces the hang. Since 2026-07-31 it also explains it
# (finding 15). failmode was varied on 2.4.3, same script, same build, same
# reproduced device failure, one variable:
#
#   wait (default)  hangs unkillably in zil_parse -> arc_read -> zio_wait
#   continue        NO hang: remove exit=0, hole created, every zh_log
#                   cleared, the script runs to completion
#   panic           kernel panic, zio_suspend+0x1b0 in the trace
#
#     FAILMODE=continue sudo -E ./07-path-h-yank-live-log.sh
#
#   (if your sudoers config strips the environment, use instead:
#        sudo FAILMODE=continue ./07-path-h-yank-live-log.sh)
#
# The ZIO's disposition is therefore zio_suspend(), and CLAIMS.md 2.6 is
# ESTABLISHED for the removal case in the test environment. The suspend gate at
# zio.c:5714-5720 needs ENXIO + SPA_LOAD_NONE + failmode != continue, and all
# three hold here.
#
# THREE LIMITS ON THAT, all real:
#
#  1. *** AT FAILMODE=panic THIS SCRIPT PANICS AT STEP 6, NOT STEP 7. ***
#     A persistent-log re-run showed the panic fires during the `zpool scrub`
#     provocation, BEFORE `zpool remove` is ever issued (FINDINGS.md finding
#     15, caveat 1). So failmode=panic shows the disposition of uncorrectable
#     I/O on this pool; it does NOT isolate the zil_parse() read. To attempt
#     that isolation, set SKIP_PROVOKE=1 to skip the step-6 scrub -- see the
#     comment at step 6. That variant has NOT been run.
#  2. It says nothing about the INCIDENT. The suspend cannot fire during an
#     import (spa_load_state != SPA_LOAD_NONE). See finding 16 and CLAIMS 4.9.
#  3. Only 2.4.3 has been run at anything other than the default. 2.2.2 and
#     2.3.4 were both `wait` only.
#
# Read CLAIMS.md 4.9 before assuming failmode is the whole answer: a read
# whose DVA resolves to a hole fails fast rather than blocking, which is not
# the same situation as the failing leaf vdev this script creates.
#
# What a fix should look like is still a design question for the people who
# maintain this code.
# ---------------------------------------------------------------------------
#
# ---------------------------------------------------------------------------
# BEFORE YOU RUN THIS: HOW TO CAPTURE THE HANG
#
# The `timeout 120` at step 7 will NOT save you. The task goes into
# uninterruptible D-state, which no signal can interrupt, so the timeout
# expires with no effect and the process is still wedged minutes later
# (evidence/2026-07-31-zfs-2.4.3-test-results.txt:194-196). Recovery needs a
# forced power cycle of the VM.
#
# Every stack in this repository was captured by hand from a second shell.
# The 2.3.4 run LOST its stack because nobody was watching -- that run is
# recorded with "NO STACK TRACE WAS CAPTURED ON THIS RUN". Do not repeat it.
#
# OPEN A SECOND SHELL NOW, before starting this script. When step 7 stops
# producing output, run there, as root:
#
#     PID=$(pgrep -f "zpool remove")
#     tr '\0' ' ' < /proc/$PID/cmdline; echo        # confirm the right pid
#     cat /proc/$PID/stack                          # THE ARTIFACT
#     cat /proc/$PID/status | grep -E 'State|Name'
#     echo w > /proc/sysrq-trigger                  # all blocked tasks
#     dmesg | tail -120                             # hung-task watchdog at 120s
#     cat /proc/spl/kstat/zfs/dbgmsg | tail -80
#
# Save all of that verbatim into evidence/ before force-stopping the VM. Note
# that a plain `zpool status` from the second shell will ALSO block, because
# spa_namespace_lock is held; do not rely on it, and do not assume the machine
# is healthy because one command returned.
# ---------------------------------------------------------------------------
#
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool
command -v dmsetup >/dev/null || bail "dmsetup missing"
command -v losetup >/dev/null || bail "losetup missing"

DM=slogdev
cleanup_h() {
    zpool destroy -f "$POOL" 2>/dev/null
    dmsetup remove --force "$DM" 2>/dev/null
    for l in $(losetup -j "$SLOG" 2>/dev/null | cut -d: -f1); do
        losetup -d "$l" 2>/dev/null
    done
    return 0
}
trap 'note "state left on disk; run ./teardown.sh and dmsetup remove $DM"' EXIT
cleanup_h; teardown
record_env

say "1. back the log with file -> loop -> dm-linear so it can be yanked"
mkdir -p "$WORK"
truncate -s 2G "$D1" "$D2"; truncate -s 512M "$SLOG"
LOOP=$(losetup --find --show "$SLOG") || bail "losetup failed"
SECTORS=$(blockdev --getsz "$LOOP")
dmsetup create "$DM" --table "0 $SECTORS linear $LOOP 0" || bail "dmsetup create failed"
note "log device: /dev/mapper/$DM ($SECTORS sectors) over $LOOP"

say "2. pool with /dev/mapper/$DM as a top-level log vdev"
zpool create -o cachefile=none -o failmode="$FAILMODE" \
    -O sync=always -O compression=off \
    "$POOL" "$D1" "$D2" log "/dev/mapper/$DM" || bail "zpool create failed"
zfs create "$POOL/ds1" || bail "create ds1"

say "3. synchronous writes so the ZIL chain is live ON THE LOG"
write_sync 40

say "4. unmount ds1 so its ZIL cannot drain and zh_log stays non-zero"
zfs unmount "$POOL/ds1" || note "unmount refused"

say "5. vs_alloc BEFORE the yank (must be non-zero)"
zpool list -v "$POOL" | sed 's/^/      /'

say "6. yank the log device out from under the live pool"
note "swap the dm table to an error target: the device stays present but every"
note "I/O fails, which is what a flickering SSD looks like to ZFS"
dmsetup suspend "$DM" || note "suspend failed"
dmsetup load "$DM" --table "0 $SECTORS error" || note "load failed"
dmsetup resume "$DM" || note "resume failed"
# *** THE SCRUB BELOW IS WHERE FAILMODE=panic PANICS. ***
# It provokes uncorrectable I/O on a pool whose failmode says to panic, and it
# runs BEFORE the removal at step 7, so a panic here tells you nothing about
# the zil_parse() read (FINDINGS.md finding 15, caveat 1).
#
# SKIP_PROVOKE=1 skips it, so that a FAILMODE=panic run can reach step 7 and
# a panic there WOULD isolate the removal. Untried: without the scrub, ZFS may
# not mark the vdev FAULTED before step 7, the removal may take a different
# route, and the whole run may prove nothing. Default is 0, i.e. exactly the
# behaviour of every recorded run; change it only deliberately.
if [ "${SKIP_PROVOKE:-0}" = "1" ]; then
    note "SKIP_PROVOKE=1: skipping the scrub provocation (UNTESTED variant)."
    note "ZFS may not have noticed the failure yet; record that in ATTEMPTS.md."
else
    note "provoking ZFS into noticing the failure"
    zpool scrub "$POOL" 2>/dev/null; sleep 3; zpool scrub -s "$POOL" 2>/dev/null
fi
sync; sleep 2
zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
say "6b. vs_alloc AFTER the yank"
note "recorded runs land on 72K here, NOT 0 (2.3.4 from 43.9M, 2.4.3 from"
note "40.4M). Non-zero means the finding-9 gate stays CLOSED and"
note "spa_reset_logs() RUNS at step 7 -- which is what hangs."
zpool list -v "$POOL" | sed 's/^/      /'

say "7. remove the log vdev"
note "EXPECT A HANG HERE under the default failmode=wait. spa_reset_logs()"
note "runs, reaches zil_parse -> arc_read -> zio_wait against a dead leaf vdev,"
note "and never returns, holding spa_namespace_lock. Findings 10, 13, 14."
note "GO TO YOUR SECOND SHELL NOW and capture /proc/<pid>/stack -- see the"
note "instructions in this script's header. The timeout below will NOT kill it."
GUID=$(zpool status "$POOL" | awk '/UNAVAIL|FAULTED|REMOVED|OFFLINE/ {print $1; exit}')
note "log identifier: ${GUID:-/dev/mapper/$DM}"
# The `timeout 120` is documentation, not protection: the task is in
# uninterruptible D-state, so SIGTERM is never delivered and the process is
# still wedged long after this returns
# (evidence/2026-07-31-zfs-2.4.3-test-results.txt:194-196). Nothing below this
# line has ever executed on a hanging run.
timeout 120 zpool remove "$POOL" "${GUID:-/dev/mapper/$DM}"; note "remove exit=$?"
sleep 2
zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
timeout 180 zpool export -f "$POOL" 2>/dev/null || note "export refused"

say "8. THE TEST"
# UNREACHABLE ON A HANGING RUN. Under failmode=wait the process wedges at
# step 7 and steps 8 and 9 never execute; the only recorded runs that got here
# are the FAILMODE=continue run (finding 15), which found a hole and every
# zh_log CLEARED, and the FAILMODE=panic run, which died even earlier at
# step 6. Treat the verdict text below as describing a state this script has
# never actually produced.
dmsetup remove --force "$DM" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null
inspect_precondition

say "verdict"
note "If you are reading this, the removal did NOT hang, so the run is not a"
note "reproduction of findings 10/13/14. Record which failmode produced it."
note ""
note "The state to look for is is_hole: 1 AND a 'ZIL header:' line for"
note "$POOL/ds1. No run of this script has produced it: at"
note "FAILMODE=continue the hole appears but every header is cleared by"
note "zil_sync() at zl_destroy_txg (finding 15, caveat 2)."
note ""
note "If it ever does appear, confirm both halves of the control:"
note "  timeout 300 zpool import -d $WORK -o cachefile=none $POOL"
note "  timeout 300 zpool import -d $WORK -o readonly=on $POOL"
note "and capture with: echo w > /proc/sysrq-trigger; dmesg | tail -80"
note "Note that on 2.4.3 a synthesised hole-plus-dangling-DVA pool did NOT"
note "hang a writable import (finding 16), so do not assume the first will."
