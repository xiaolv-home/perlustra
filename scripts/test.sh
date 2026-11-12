#!/bin/bash
# Runs the Swift Testing unit tests. Command Line Tools ship Testing.framework outside the
# default search path, so point the compiler and the runtime at it.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/duckdb.sh
source scripts/sdk.sh
F="$DEV/Library/Developer/Frameworks"
L="$DEV/Library/Developer/usr/lib"
if [[ -d "$DEV/Platforms" ]]; then exec swift test "$@"; fi   # full Xcode: nothing special needed
# Newer Command Line Tools no longer find the Testing macros on their own.
P="$DEV/usr/lib/swift/host/plugins/testing"
swift test -Xswiftc -F"$F" -Xswiftc -plugin-path -Xswiftc "$P" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
