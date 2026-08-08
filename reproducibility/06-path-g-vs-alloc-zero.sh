#!/usr/bin/env bash
# DANGER: if this works, the final step hangs the machine. Read step 9.
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool

trap 'note "state left on disk; run ./teardown.sh when done"' EXIT
teardown
record_env

say "1. pool with a top-level log vdev"
mkdir -p "$WORK"
truncate -s 2G "$D1" "$D2"; truncate -s 512M "$SLOG"
zpool create -o cachefile=none -o failmode="$FAILMODE" \
    -O sync=always -O compression=off \
    "$POOL" "$D1" "$D2" log "$SLOG" || bail "zpool create failed"
zfs create "$POOL/ds1" || bail "create ds1"

say "2. synchronous writes so the ZIL chain is live on the log"
write_sync 40

say "3. unmount ds1 so its ZIL cannot drain and zh_log stays non-zero"
note "a mounted dataset drains its own ZIL and zeroes the header; that is why"
note "earlier runs kept losing the reference"
zfs unmount "$POOL/ds1" || note "unmount refused"

say "4. record vs_alloc on the log vdev BEFORE wiping"
zpool list -v "$POOL" | sed 's/^/      /'

say "5. wipe the log device so it reports vs_alloc == 0"
note "this is what labelclear + wipefs did on the affected pool"
zpool export -f "$POOL" 2>/dev/null || note "export refused"
dd if=/dev/zero of="$SLOG" bs=1M count=512 status=none 2>/dev/null
note "log device zeroed in place, size preserved"

say "6. import with -m: log present but unreadable, so UNAVAIL"
timeout 300 zpool import -d "$WORK" -o cachefile=none -m "$POOL"
note "import exit=$?"
zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
zpool list -v "$POOL" 2>/dev/null | sed 's/^/      /'

say "7. check what the -m import did to the header"
note "KNOWN RESULT (finding 8): the -m import CLEARS every zh_log via the"
note "SPA_LOG_CLEAR path in zil_claim(), including datasets that were unmounted"
note "and including datasets that cannot be held. Expect NO ZIL header line for"
note "$POOL/ds1. That is precisely why this route cannot strand a reference,"
note "and why 07 avoids the export/import entirely."

# THE LOAD-BEARING STEP: identify the log vdev to hand to `zpool remove`.
# Restricted to the config: table, requiring the STATE column (field 2) to
# hold the faulted state rather than matching the word anywhere on the line,
# and skipping the pool row and the column header. The older form
#     awk '/UNAVAIL|OFFLINE/ {print $1; exit}'
# could return the pool name, a section heading, or a line of the status prose
# printed above the table under other `zpool status` layouts.
LOGGUID=$(zpool status "$POOL" | awk -v pool="$POOL" '
    /^[[:space:]]*config:/ { in_cfg = 1; next }
    /^[[:space:]]*errors:/ { in_cfg = 0 }
    in_cfg && $1 != pool && $1 != "NAME" &&
        $2 ~ /^(UNAVAIL|OFFLINE|FAULTED|REMOVED)$/ { print $1; exit }')
# Guard: an empty result is legitimate (fall back to the path below), but a
# non-empty result that cannot be a vdev identifier means the scrape misfired
# and the removal would target the wrong thing. Stop rather than guess.
case "${LOGGUID:-}" in
    "") ;;
    "$POOL"|NAME|logs|cache|spares|*:*)
        bail "implausible vdev id '$LOGGUID' scraped from zpool status; refusing to run the removal. Inspect 'zpool status $POOL' by hand." ;;
esac
note "log vdev identifier: ${LOGGUID:-<not found, will fall back to $SLOG>}"

say "8. remove the log vdev, now that vs_alloc should be 0"
note "if vs_alloc == 0 the ZIL reset is SKIPPED and the removal proceeds"
if [ -n "${LOGGUID:-}" ]; then
    timeout 120 zpool remove "$POOL" "$LOGGUID"; note "remove exit=$?"
else
    timeout 120 zpool remove "$POOL" "$SLOG"; note "remove exit=$?"
fi
sleep 2
zpool status "$POOL" | sed -n '/config:/,$p' | sed 's/^/      /'
timeout 120 zpool export "$POOL" 2>/dev/null || note "export refused"

say "9. THE TEST"
inspect_precondition

say "verdict"
note "REPRODUCED if the vdev tree shows is_hole: 1 AND a 'ZIL header:' line"
note "still appears for $POOL/ds1."
note ""
note "That has NOT happened on any version run so far (2.2.2, 2.3.4, 2.4.3):"
note "the gate opens and the hole is created, but the -m import needed to get"
note "there has already cleared every header (finding 8). Expect a hole with"
note "no surviving header, and record the version in ATTEMPTS.md."
note ""
note "If it does reproduce, capture the hang:"
note "  timeout 300 zpool import -d $WORK -o cachefile=none $POOL"
note "and in another shell: echo w > /proc/sysrq-trigger; dmesg | tail -80"
note "Expect zil_check_log_chain -> zil_parse -> zil_read_log_block ->"
note "arc_read -> zio_wait, and readonly import must still SUCCEED."
