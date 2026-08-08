#!/usr/bin/env bash
set -u
cd "$(dirname "$0")" && . ./lib.sh
require_root
teardown
echo "torn down: $WORK removed, pool $POOL destroyed, zinject cleared"
