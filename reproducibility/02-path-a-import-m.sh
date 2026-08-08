#!/usr/bin/env bash
# DANGER: ends at a decision point that may hang the machine. Read the
# 'Capturing a hang' section of README.md.
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root; require_no_pool

trap 'note "leaving state on disk for inspection; run ./teardown.sh when done"' EXIT
teardown
record_env

say "1. pool with a top-level log vdev"
make_pool

say "2. freeze so writes reach the ZIL but never the main pool"
zpool freeze "$POOL" || bail "zpool freeze failed"

say "3. synchronous writes, recoverable only from the log"
write_sync 40

say "4. drop the pool with the ZIL unclaimed, then destroy the log device"
zpool export -f "$POOL" 2>/dev/null || note "export refused while frozen"
rm -f "$SLOG"
note "log device deleted; it is now MISSING rather than a hole"

say "5. import with -m"
note "05 saw the -m import clear every header on 2.4.1 (finding 8); the same"
note "is expected here, but this script has never been run to check"
timeout 180 zpool import -d "$WORK" -o cachefile=none -m "$POOL"
note "exit=$?"
zpool export "$POOL" 2>/dev/null || true

inspect_precondition

say "verdict"
note "If every zh_log is zero: hypothesis A is RULED OUT on its own evidence"
note "rather than by inheritance from 05. Record it in ATTEMPTS.md against the"
note "row that currently reads NOT RUN. Do NOT attempt a writable import."
note "If any zh_log is NON-ZERO and a hole exists, that would contradict"
note "finding 8; see the 'Capturing a hang' section of README.md for how to trigger and capture the hang."
