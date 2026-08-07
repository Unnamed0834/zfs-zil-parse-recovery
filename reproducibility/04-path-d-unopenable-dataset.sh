#!/usr/bin/env bash
#
# HYPOTHESIS D: a dataset that cannot be opened during ZIL reset or claim.
#
# RATIONALE (from FINDINGS.md finding 5): a failing log device is NOT enough.
# spa_reset_logs() clears every dataset's zh_log even when all log I/O returns
# errors. It loses the data, reports data errors, and still leaves no dangling
# DVA.
#
# But both spa_reset_logs() and the SPA_LOG_CLEAR path in zil_claim() reach
# datasets via dmu_objset_find(). A dataset that cannot be HELD is skipped, and
# a skipped dataset keeps its ZIL header. The cleanest way to force that is an
# encrypted dataset whose key is not loaded, where dmu_objset_hold() fails.
#
# Supporting detail: zil_claim() already carries an `os->os_encrypted` special
# case, so encryption demonstrably interacts with this code path.
#
# ALREADY ANSWERED. Run on 2.4.1, 2.2.2, 2.3.4 and 2.4.3 (FINDINGS.md finding
# 6): `zpool remove` was REFUSED outright with "Mount encrypted datasets to
# replay logs", exit 1, and no hole was created. A second, purpose-built guard
# on log removal. Note also finding 6's correction: the plain-vs-encrypted
# header difference seen in an earlier run was mounted-vs-unmounted draining,
# not encryption. Re-running this extends version coverage; it does not reopen
# the question on those four.
#
# DANGER: ends at a decision point that may hang the machine. Read step 8.
#
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool

KEYFILE=/var/tmp/ziltest.key
trap 'note "state left on disk for inspection; run ./teardown.sh when done"' EXIT
teardown
record_env

say "1. pool with a top-level log vdev"
mkdir -p "$WORK"
truncate -s 2G "$D1" "$D2"
truncate -s 512M "$SLOG"
zpool create -o cachefile=none -o failmode="$FAILMODE" \
    -O sync=always -O compression=off \
    "$POOL" "$D1" "$D2" log "$SLOG" || bail "zpool create failed"

say "2. one plaintext dataset and one ENCRYPTED dataset"
dd if=/dev/urandom of="$KEYFILE" bs=32 count=1 status=none
chmod 600 "$KEYFILE"
zfs create "$POOL/plain" || bail "zfs create plain"
zfs create -o encryption=aes-256-gcm -o keyformat=raw \
    -o keylocation="file://$KEYFILE" "$POOL/enc" \
    || bail "zfs create enc (is the encryption feature enabled?)"
zfs list -o name,encryption,keystatus -r "$POOL" | sed 's/^/      /'

say "3. synchronous writes into BOTH datasets so both ZILs hold live records"
for ds in plain enc; do
    for i in $(seq 1 20); do
        dd if=/dev/urandom of="/$POOL/$ds/sync-$i" bs=128k count=8 \
            oflag=sync status=none 2>/dev/null
    done
done
grep -E 'zil_itx_metaslab_slog_(count|bytes)' /proc/spl/kstat/zfs/zil \
    | sed 's/^/      /' || true

say "4. unload the encryption key so that dataset can no longer be held"
zfs unmount "$POOL/enc" 2>/dev/null || note "unmount refused"
zfs unload-key "$POOL/enc" || note "unload-key refused"
zfs list -o name,keystatus -r "$POOL" | sed 's/^/      /'
note "keystatus for $POOL/enc should now read 'unavailable'"

say "5. remove the log vdev while one dataset is unopenable"
note "spa_reset_logs() walks datasets via dmu_objset_find(); the encrypted"
note "dataset should fail to hold and be skipped, keeping its zh_log."
timeout 90 zpool remove "$POOL" "$SLOG"
note "remove exit=$?"
sleep 2
timeout 60 zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /' \
    || note "status timed out"

say "6. destroy the log backing file and export"
rm -f "$SLOG"
timeout 120 zpool export -f "$POOL" 2>/dev/null || note "export refused"

say "7. precondition check"
inspect_precondition

say "8. verdict"
note "REPRODUCED if a 'ZIL header:' line appears for $POOL/enc AND the vdev"
note "tree shows is_hole: 1. That is a non-zero zh_log pointing at a hole."
note ""
note "If so, capture the hang per the 'Capturing a hang' section of README.md, and note that the control"
note "still holds: 'zpool import -o readonly=on' must succeed on the same pool."
note ""
note "If every zh_log is still clear, hypothesis D is RULED OUT here too, which"
note "is what happened on all four versions tested (finding 6). Record the"
note "version. The enumeration of documented routes was closed by finding 12;"
note "read FINDINGS.md before opening a new path, and read its statement of"
note "how far that negative reaches, which is not as far as 'no sequence exists'."
note ""
note "Key file kept at $KEYFILE in case the pool needs reopening."
