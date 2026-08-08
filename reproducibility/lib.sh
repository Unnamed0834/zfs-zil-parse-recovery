#!/usr/bin/env bash
# Those five have recorded results in ATTEMPTS.md. Do NOT refactor them onto
# make_pool(): changing their setup would invalidate the results already
# recorded against them. If you change make_pool(), you have changed 01, 02 and
# 03 and nothing else.

POOL="${POOL:-ziltest}"
WORK="${WORK:-/var/tmp/ziltest}"
D1="$WORK/d1"
D2="$WORK/d2"
SLOG="$WORK/slog"

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
