#!/usr/bin/env bash
#
# Shared helpers for the reproduction scripts. Sourced, not executed.
#
# Shared inspection (inspect_precondition), teardown and output helpers. These
# ARE common to every script, and the gate in inspect_precondition() is the one
# thing all of them agree on.
#
# Pool layout is NOT common. make_pool() below is used by 01, 02 and 03 only.
# Scripts 04, 05, 06, 07 and 08 each open-code their own `zpool create`, with
# different dataset layouts, because each hypothesis needs a different setup:
#
#   04, 05  plaintext + encrypted dataset, keyfile at /var/tmp/ziltest.key
#   06      single ds1, log wiped in place after export
#   07      log backed by file -> loop -> dm-linear so it can be yanked
#   08      ds1 + ds2, ds2 used to drive txgs
#
# Those five have recorded results in ATTEMPTS.md. Do NOT refactor them onto
# make_pool(): changing their setup would invalidate the results already
# recorded against them. If you change make_pool(), you have changed 01, 02 and
# 03 and nothing else.

POOL="${POOL:-ziltest}"
WORK="${WORK:-/var/tmp/ziltest}"
D1="$WORK/d1"
D2="$WORK/d2"
SLOG="$WORK/slog"

# Pool failmode for the scratch pool.
#
# WHAT VARYING THIS NOW DOES. failmode was varied at last on 2026-07-31
# (FINDINGS.md finding 15), on ZFS 2.4.3, using 07-path-h-yank-live-log.sh.
# Same script, same build, same reproduced device failure; one variable:
#
#   wait (default)  the removal hangs unkillably in
#                   zil_parse -> arc_read -> zio_wait, and holds
#                   spa_namespace_lock, so every later zpool command blocks
#   continue        NO hang. remove exit=0, hole created, every zh_log
#                   cleared, the script runs to completion
#   panic           kernel panic, with zio_suspend+0x1b0 in the trace
#
# So the ZIO's disposition is zio_suspend(), and CLAIMS.md 2.6 is ESTABLISHED
# for the removal case in the test environment. The suspend gate at
# zio.c:5714-5720 needs ENXIO + SPA_LOAD_NONE + failmode != continue, and all
# three hold for a live-pool removal.
#
# Two scope limits, both real:
#   - At failmode=panic the panic fires during the step-6 scrub provocation in
#     07, BEFORE `zpool remove`, so it does not isolate the zil_parse() read.
#   - None of this explains the INCIDENT. That suspend cannot fire during an
#     import (spa_load_state != SPA_LOAD_NONE). See finding 16 and CLAIMS 4.9.
#
# WHAT IS STILL UNVARIED. Every run on 2.2.2, 2.3.4 and 2.4.1 used the default
# `wait`; the three-way result above is from 2.4.3 alone, and from script 07
# alone. Every other script in this folder has only ever been run at `wait`.
#
#     FAILMODE=continue sudo -E ./07-path-h-yank-live-log.sh
#
# NOT AN OPEN QUESTION, despite earlier revisions of this comment saying so.
# This block used to end "Also unrun: a pool that already carries
# failmode=continue before its log begins failing." That was wrong when it was
# written. make_pool() below, and every open-coded `zpool create` in 02-08,
# pass -o failmode="$FAILMODE" AT CREATION, so the pool carries the setting
# before anything is yanked. The finding-15 continue run IS that experiment,
# and it did not hang.
#
# Record any run in ATTEMPTS.md with the ZFS version and the failmode used.
FAILMODE="${FAILMODE:-wait}"

say()  { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '    \033[31mFAIL\033[0m  %s\n' "$*"; }
bail() { printf '\n\033[31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || bail "must run as root (use sudo)"
}

require_no_pool() {
    zpool list -H -o name 2>/dev/null | grep -qx "$POOL" \
        && bail "pool '$POOL' is imported; run ./teardown first"
    return 0
}

record_env() {
    say "environment"
    note "kernel:  $(uname -srm)"
    note "zfs:     $(cat /sys/module/zfs/version 2>/dev/null || echo unknown)"
    note "userland: $(zfs version 2>/dev/null | head -1 || echo unknown)"
    note "failmode: $FAILMODE  (override with FAILMODE=continue|panic)"
}

# Create a pool with a separate TOP-LEVEL log vdev. It must be top-level for
# its removal to leave a hole in the vdev tree.
#
# USED BY 01, 02 AND 03 ONLY. 04-08 open-code their own create; see the note at
# the top of this file.
#
# failmode is set explicitly rather than left implicit, so that every run
# records which setting produced its result. See the FAILMODE note at the top
# of this file.
make_pool() {
    mkdir -p "$WORK"
    truncate -s 2G "$D1" "$D2"
    truncate -s 512M "$SLOG"
    zpool create -o cachefile=none -o failmode="$FAILMODE" \
        -O sync=always -O compression=off \
        "$POOL" "$D1" "$D2" log "$SLOG" || bail "zpool create failed"
    note "pool failmode=$(zpool get -H -o value failmode "$POOL" 2>/dev/null)"
    zfs create "$POOL/ds1" || bail "zfs create $POOL/ds1 failed"
}

# Drive synchronous writes so the ZIL holds live records.
write_sync() {
    local n="${1:-40}" i
    for i in $(seq 1 "$n"); do
        dd if=/dev/urandom of="/$POOL/ds1/sync-$i" bs=128k count=8 \
            oflag=sync status=none 2>/dev/null
    done
    note "slog ZIL counters:"
    grep -E 'zil_itx_metaslab_slog_(count|bytes)' /proc/spl/kstat/zfs/zil \
        | sed 's/^/      /' || true
}

# THE GATE. Both conditions must hold for the defect to be reachable:
#   (a) a top-level vdev with is_hole: 1
#   (b) at least one dataset whose zh_log DVA is NON-ZERO
# An all-zero DVA terminates zil_parse()'s loop safely via BP_IS_HOLE, so a
# hole alone is harmless. Never attempt the writable import unless both hold.
#
# Takes an optional mode argument:
#   result (default)  this reading is the OUTCOME of the path being tested;
#                     print PASS/FAIL
#   setup             this reading is the STARTING state, taken before the
#                     operation under test. A non-zero zh_log here is what we
#                     arranged on purpose; it is not a result. Print it as
#                     setup state, with no PASS/FAIL, so a transcript cannot be
#                     misread as the path having reproduced anything.
inspect_precondition() {
    local mode="${1:-result}"
    if [ "$mode" = setup ]; then
        say "on-disk state BEFORE the operation under test (setup, not a result)"
    else
        say "on-disk precondition"
    fi
    echo "--- (a) vdev tree: looking for is_hole: 1 ---"
    zdb -e -p "$WORK" -C "$POOL" 2>/dev/null \
        | grep -E 'vdev_children|hole_array|is_hole|type:' | sed 's/^/      /' \
        | head -30
    echo
    echo "--- (b) per-dataset ZIL headers: looking for a NON-ZERO zh_log ---"
    # zdb's dump_intent_log() returns early when BP_IS_HOLE(&zh->zh_log), so a
    # "ZIL header:" line is printed ONLY when zh_log is non-zero. Its presence
    # is therefore exactly the condition we need, and its absence is a clean
    # negative. Do not use `zdb -dddd`; that does not print the header at all.
    local zilout
    zilout=$(zdb -e -p "$WORK" -i "$POOL" 2>/dev/null)
    echo "$zilout" | grep -E '^Dataset |ZIL header:|^\s+(TX|first block)' \
        | sed 's/^/      /' | head -30
    echo
    if [ "$mode" = setup ]; then
        if echo "$zilout" | grep -q 'ZIL header:'; then
            note "SETUP STATE: a NON-ZERO zh_log is present, as this script"
            note "SETUP STATE: intended. This is the starting condition, NOT a"
            note "SETUP STATE: result. The result is the same check run again"
            note "SETUP STATE: after the operation under test."
            echo "$zilout" | grep -B2 'ZIL header:' | sed 's/^/      /'
        else
            note "SETUP STATE: every zh_log is already a hole, so the setup did"
            note "SETUP STATE: not produce the starting condition this script"
            note "SETUP STATE: needs. Whatever follows tests nothing."
        fi
        echo
        return 0
    fi
    if echo "$zilout" | grep -q 'ZIL header:'; then
        ok "NON-ZERO zh_log found: the defect is reachable from this state"
        echo "$zilout" | grep -B2 'ZIL header:' | sed 's/^/      /'
    else
        bad "every zh_log is a hole: this path is RULED OUT"
    fi
    echo
    note "If every zh_log is zero, this path is RULED OUT. Record it in"
    note "ATTEMPTS.md and try another path. Do not attempt the import."
}

teardown() {
    zpool destroy -f "$POOL" 2>/dev/null
    zpool export -f "$POOL" 2>/dev/null
    zinject -c all >/dev/null 2>&1
    rm -rf "$WORK"
    return 0
}
