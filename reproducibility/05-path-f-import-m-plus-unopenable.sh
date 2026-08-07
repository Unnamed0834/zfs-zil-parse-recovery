#!/usr/bin/env bash
#
# HYPOTHESIS F: `zpool import -m` with a MISSING log, plus a dataset that
#               cannot be held. Synthesis of A and D.
#
# WHY THIS ONE. Ruled out so far:
#   C  a failing log device: spa_reset_logs() still clears every header (f5)
#   D  an unopenable dataset + `zpool remove`: refused outright with
#      "Mount encrypted datasets to replay logs" (f6)
#
# Both of those go through `zpool remove`. This path does not.
#
# `zpool import -m` on a MISSING log sets SPA_LOG_CLEAR. That makes
# zil_claim() clear each header instead of parsing it, AND discards the log
# vdev, leaving a hole. But zil_claim() is reached per-dataset via
# dmu_objset_find(), so a dataset that cannot be held is skipped and keeps its
# non-zero zh_log. Result: a hole plus a surviving dangling reference.
#
# This matches the affected pool's history, which shows an `-m` import and no
# well-formed `zpool remove` of the log:
#   2026-07-19.22:42:44  zpool import <guid> -R /mnt -m -N -f
#   2026-07-19.22:57:28  py-libzfs: zpool remove storageNone
#
# KEY DETAIL from run D: delete the log backing file BEFORE exporting. The
# export then has no log to flush to, so zh_log survives non-zero.
#
# ALREADY ANSWERED, and the premise below is FALSE. Run on 2.4.1 (FINDINGS.md
# findings 7 and 8): `import -m` left the log UNAVAIL, not a hole, and the
# SPA_LOG_CLEAR path cleared EVERY header, including `ziltest/enc` whose key
# was unavailable. So an unholdable dataset is not skipped by zil_claim() on
# that version. Hypothesis F is RULED OUT, and hypothesis A inherits that
# result because `02` was never run.
#
# NOT re-run on 2.2.2, 2.3.4 or 2.4.3. Running it there is the remaining value
# in this file.
#
# DANGER: ends at a decision point that may hang the machine. Read step 8.
#
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool

KEYFILE=/var/tmp/ziltest.key
trap 'note "state left on disk; run ./teardown.sh when done"' EXIT
teardown
record_env

say "1. pool with a top-level log vdev"
mkdir -p "$WORK"
truncate -s 2G "$D1" "$D2"; truncate -s 512M "$SLOG"
zpool create -o cachefile=none -o failmode="$FAILMODE" \
    -O sync=always -O compression=off \
    "$POOL" "$D1" "$D2" log "$SLOG" || bail "zpool create failed"

say "2. a plaintext dataset and an encrypted dataset, key loaded"
dd if=/dev/urandom of="$KEYFILE" bs=32 count=1 status=none; chmod 600 "$KEYFILE"
zfs create "$POOL/plain" || bail "create plain"
zfs create -o encryption=aes-256-gcm -o keyformat=raw \
    -o keylocation="file://$KEYFILE" "$POOL/enc" || bail "create enc"

say "3. synchronous writes into both, so both ZIL chains are live"
for ds in plain enc; do
    for i in $(seq 1 20); do
        dd if=/dev/urandom of="/$POOL/$ds/sync-$i" bs=128k count=8 \
            oflag=sync status=none 2>/dev/null
    done
done
grep -E 'zil_itx_metaslab_slog_count' /proc/spl/kstat/zfs/zil | sed 's/^/      /'

say "4. unload the key so that dataset can no longer be held"
zfs unmount "$POOL/enc" 2>/dev/null || note "unmount refused"
zfs unload-key "$POOL/enc" || note "unload-key refused"
zfs list -o name,keystatus -r "$POOL" | sed 's/^/      /'

say "5. destroy the log device, THEN export"
note "order matters: with no log to flush to, zh_log survives non-zero"
rm -f "$SLOG"
timeout 120 zpool export -f "$POOL" 2>/dev/null || note "export refused"

say "6. confirm the SETUP state BEFORE the -m import"
note "expect: no hole yet, but non-zero zh_log on the datasets. A non-zero"
note "zh_log here is the starting condition this script arranges on purpose."
note "It is NOT a result: the result is the same check at step 8."
inspect_precondition setup

say "7. import -m: log is MISSING, so SPA_LOG_CLEAR applies"
note "on 2.4.1 this left the log UNAVAIL rather than a hole, and cleared EVERY"
note "header including the unholdable encrypted one (findings 7 and 8)"
timeout 300 zpool import -d "$WORK" -o cachefile=none -m "$POOL"
note "import -m exit=$?"
timeout 60 zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /' \
    || note "status timed out"
timeout 120 zpool export "$POOL" 2>/dev/null || note "export refused"

say "8. THE TEST: hole AND a surviving non-zero zh_log? (this reading IS a result)"
inspect_precondition result

say "verdict"
note "REPRODUCED if the vdev tree shows is_hole: 1 AND a 'ZIL header:' line"
note "still appears for $POOL/enc. That is a dangling DVA aimed at a hole."
note "That did NOT happen on 2.4.1: no hole, and every header cleared (f7, f8)."
note ""
note "Remember the correct reading: the presence of the 'ZIL header:' line is"
note "the signal, because dump_intent_log() returns early on"
note "BP_IS_HOLE(&zh->zh_log). The claim_txg/claim_blk_seq values being zero is"
note "expected on a pool that has not been claimed yet and means nothing here."
note ""
note "If reproduced, capture the hang per the 'Capturing a hang' section of README.md and verify the"
note "control: 'zpool import -o readonly=on' must still succeed."
