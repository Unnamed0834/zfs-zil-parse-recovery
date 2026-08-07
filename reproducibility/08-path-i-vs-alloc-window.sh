#!/usr/bin/env bash
#
# HYPOTHESIS I: is there a window where vs_alloc == 0 while a dataset zh_log is
#               still non-zero, on a LIVE pool with no export/import?
#
# STATUS: NO VALID RESULT. Read this before quoting anything from this script.
#
#  1. The only run (2026-07-29, ZFS 2.2.2) was INVALID. It probed with
#     `zdb -i <pool>` against a live IMPORTED pool, which emits nothing, so
#     the header count read 0 in all 12 rounds and the "no window" conclusion
#     was an artifact of the measurement. ATTEMPTS.md records it as INVALID
#     and the conclusion was retracted. Read with the exported form, the same
#     state showed all three datasets dirty at vs_alloc 27 MB.
#  2. The probe was fixed (see step 4) to use `zdb -e -p "$WORK" -i "$POOL"`,
#     matching inspect_precondition() in lib.sh.
#  3. THE FIXED SCRIPT HAS NEVER BEEN RE-RUN, on any version. Hypothesis I
#     therefore has no valid result at all.
#
# An earlier version of this header claimed finding 12 had "conclusively
# shown" that no route produces this state, and that the result this script
# would produce was "already known with certainty". Both were overclaims.
# FINDINGS.md states finding 12 at its true strength: a BOUNDED NEGATIVE over
# the routes that were tried, on the versions each was tried on, which "does
# not establish that no sequence exists" (see also CLAIMS.md 3.20). This
# script probes a route the enumeration did not cover -- a live pool with no
# export/import -- so a valid run of it would add evidence, not confirm a
# foregone conclusion.
#
# The two established constraints (findings 9 and 10) box it in:
#
#   vs_alloc != 0  ->  spa_reset_logs() RUNS. It either clears every header
#                      (f5) or hangs forever on a failing device (f10).
#   vs_alloc == 0  ->  spa_reset_logs() is SKIPPED and the removal creates the
#                      hole (f9). But every route to vs_alloc == 0 tested so far
#                      required an export plus `import -m`, and that clears every
#                      header via SPA_LOG_CLEAR (f8).
#
# So the state needs vs_alloc == 0 AND a dirty header AND no intervening import.
# If no such window is found here, that is one more bounded negative: it bounds
# the routes tried, on the version tried, and nothing wider.
#
# Method: unmount a dataset so its header persists, then poll vs_alloc and the
# header together across many txgs looking for the window. Only if the window
# is found do we attempt the removal.
#
# SAFE until step 5. Nothing here fails a device, so nothing should hang.
#
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool

trap 'note "state left on disk; run ./teardown.sh when done"' EXIT
teardown
record_env

say "1. pool with a top-level log vdev, two datasets"
mkdir -p "$WORK"
truncate -s 2G "$D1" "$D2"; truncate -s 512M "$SLOG"
zpool create -o cachefile=none -o failmode="$FAILMODE" \
    -O sync=always -O compression=off \
    "$POOL" "$D1" "$D2" log "$SLOG" || bail "zpool create failed"
zfs create "$POOL/ds1" || bail "create ds1"
zfs create "$POOL/ds2" || bail "create ds2"

say "2. synchronous writes into ds1 so its ZIL chain is live on the log"
for i in $(seq 1 30); do
    dd if=/dev/urandom of="/$POOL/ds1/sync-$i" bs=128k count=8 \
        oflag=sync status=none 2>/dev/null
done
grep -E 'zil_itx_metaslab_slog_count' /proc/spl/kstat/zfs/zil | sed 's/^/      /'

say "3. unmount ds1 so its header cannot drain"
zfs unmount "$POOL/ds1" || note "unmount refused"

say "4. poll vs_alloc and the ds1 header together, across txgs"
note "looking for: log ALLOC 0 while a ZIL header line persists on disk"
note "driving txgs with writes into ds2 to keep the pool advancing"
FOUND=0
for round in $(seq 1 12); do
    dd if=/dev/urandom of="/$POOL/ds2/churn" bs=1M count=8 \
        oflag=sync status=none 2>/dev/null
    sync; sleep 3
    ALLOC=$(zpool list -vp "$POOL" 2>/dev/null | awk -v s="$SLOG" '$1==s {print $3}')
    # Use the same probe as inspect_precondition() in lib.sh:
    # dump_intent_log() returns early on BP_IS_HOLE(&zh->zh_log), so
    # a "ZIL header:" line appears only when zh_log is non-zero.
    # This reads on-disk state via the export scan path rather than
    # the live pool, avoiding the false negative that an earlier
    # version of this script produced.
    HDR=$(zdb -e -p "$WORK" -i "$POOL" 2>/dev/null | grep -c 'ZIL header:')
    printf '      round %-2s  log vs_alloc=%-10s  datasets with non-zero zh_log=%s\n' \
        "$round" "${ALLOC:-?}" "$HDR"
    if [ "${ALLOC:-1}" = "0" ] && [ "${HDR:-0}" -gt 0 ]; then
        ok "WINDOW FOUND at round $round: vs_alloc == 0 with a dirty header"
        FOUND=1; break
    fi
done

say "5. decision"
if [ "$FOUND" -eq 1 ]; then
    note "window exists. attempting the removal, which should SKIP the reset"
    timeout 120 zpool remove "$POOL" "$SLOG"; note "remove exit=$?"
    sleep 2
    zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
    timeout 180 zpool export "$POOL" 2>/dev/null || note "export refused"
    inspect_precondition
    note "REPRODUCED if is_hole: 1 AND a ZIL header line survives"
else
    bad "no window found in 12 rounds"
    note ""
    note "State that result at its true strength. It is a bounded negative:"
    note "12 rounds, one poll interval, one pool layout, one ZFS version, on"
    note "this run only. It does not show that no such window exists."
    note ""
    note "It is also the FIRST valid result for hypothesis I, if this is the"
    note "first run since the probe was fixed. The only earlier run was INVALID"
    note "(zdb -i against a live imported pool, 0 headers in all 12 rounds)."
    note "Record this run in ATTEMPTS.md with the ZFS version; do not let it"
    note "inherit the old INVALID row's conclusion."
    note ""
    note "Finding 12 is related but does not settle this: it is itself a"
    note "bounded negative over eight enumerated routes and does not establish"
    note "that no sequence exists (FINDINGS.md; CLAIMS.md 3.20)."
    note ""
    note "Final state for the record:"
    zpool list -v "$POOL" | sed 's/^/      /'
    zdb -e -p "$WORK" -i "$POOL" 2>/dev/null | grep -E '^Dataset|ZIL header:' | sed 's/^/      /'
fi
