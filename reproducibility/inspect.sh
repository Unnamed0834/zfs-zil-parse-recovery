#!/usr/bin/env bash
# Standalone precondition check against whatever state is on disk. Read-only.
#
# Reads the EXPORTED on-disk state via `zdb -e -p $WORK`. The pool must not be
# imported: `zdb -i` against a live imported pool emits nothing, which reads as
# a false negative (that is the bug that invalidated 08's only run).
#
# Prints the reading as a RESULT (PASS/FAIL). If what you are looking at is a
# setup state rather than the outcome of an operation, that labelling is wrong
# for your purpose; call `inspect_precondition setup` instead.
set -u
cd "$(dirname "$0")" && . ./lib.sh
[ -d "$WORK" ] || bail "no $WORK; run a path script first"
record_env
inspect_precondition
