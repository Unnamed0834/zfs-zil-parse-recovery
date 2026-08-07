#!/usr/bin/env bash
# Destroy the scratch pool, clear fault injection, remove backing files.
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root
teardown
echo "torn down: $WORK removed, pool $POOL destroyed, zinject cleared"
