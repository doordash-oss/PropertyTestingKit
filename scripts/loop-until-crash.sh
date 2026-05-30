#!/bin/bash
# Run a Swift Testing test under lldb in a loop until a crash is captured.
# Usage: ./scripts/loop-until-crash.sh <filter> [max_attempts]
# Env: BUILD_ROOT (default: $HOME/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert)
#      LOG_DIR    (default: /tmp/lldb-loop)
# Output: per-attempt logs in $LOG_DIR/run-NNN.log
#
# On signal (SIGSEGV/SIGBUS/SIGABRT) lldb stops, dumps `bt all`, and the
# loop bails out. See DEBUGGING.md for the recipe.

set -u

FILTER="${1:?usage: $0 <test-filter> [max-attempts]}"
MAX="${2:-100}"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert}"
LOG_DIR="${LOG_DIR:-/tmp/lldb-loop}"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/release/swiftpm-testing-helper"
BUNDLE="$PROJECT_ROOT/.build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest/Contents/MacOS/PropertyTestingKitPackageTests"
DYLD_LIB="$BUILD_ROOT/swift-macosx-arm64/lib/swift/macosx:/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib"
DYLD_FW="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks:/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"

if [ ! -x "$HELPER" ]; then
    echo "ERROR: swiftpm-testing-helper not found at $HELPER" >&2
    echo "Build the toolchain first: ./scripts/build-local-toolchain.sh build --build-tests" >&2
    exit 2
fi
if [ ! -x "$BUNDLE" ]; then
    echo "ERROR: test bundle not found at $BUNDLE" >&2
    echo "Build tests first: ./scripts/build-local-toolchain.sh build --build-tests" >&2
    exit 2
fi

LLDB_SCRIPT_FILE="$PROJECT_ROOT/scripts/lldb-loop.lldb"
if [ ! -f "$LLDB_SCRIPT_FILE" ]; then
    echo "ERROR: lldb script not found at $LLDB_SCRIPT_FILE" >&2
    exit 2
fi

mkdir -p "$LOG_DIR"

export PTK_BUNDLE="$BUNDLE"
export PTK_FILTER="$FILTER"
export PTK_DYLD_LIB="$DYLD_LIB"
export PTK_DYLD_FW="$DYLD_FW"

echo "Looping '$FILTER' up to $MAX times under lldb; logs in $LOG_DIR"
for i in $(seq 1 "$MAX"); do
    LOG="$LOG_DIR/run-$(printf '%03d' "$i").log"
    printf "attempt %d/%d ... " "$i" "$MAX"
    lldb -b -s "$LLDB_SCRIPT_FILE" "$HELPER" > "$LOG" 2>&1
    if grep -qE "stop reason = signal|EXC_BAD_ACCESS|EXC_BAD_INSTRUCTION|EXC_CRASH|stop reason = EXC_" "$LOG"; then
        echo "CRASH! see $LOG"
        exit 0
    fi
    if grep -q "exited with status = 0" "$LOG"; then
        echo "passed"
    else
        echo "ambiguous (no clean exit, no signal) — see $LOG"
    fi
done

echo "no crash in $MAX attempts"
