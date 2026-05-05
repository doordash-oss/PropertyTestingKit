#!/bin/bash
# Run the test bundle directly, bypassing SwiftPM (`swift test --skip-build`)
# overhead. ~10x faster per iteration on stress runs.
#
# Usage:
#   ./scripts/runtests.sh [--filter X] [--list-tests] [other swift-testing args]
#
# Requires the test bundle to already be built (run swift-test once first).
# The shim binary is built lazily into .build/runtests if missing.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$HOME/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert}"
SWIFT_BUILD="$BUILD_ROOT/swift-macosx-arm64"
LOCAL_SWIFTC="$SWIFT_BUILD/bin/swiftc"
LOCAL_RUNTIME="$SWIFT_BUILD/lib/swift/macosx"

XCTEST_FW="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks"
XCTEST_USR_LIB="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib"
SHARED_FW="/Applications/Xcode.app/Contents/SharedFrameworks"

SHIM_SRC="$REPO_ROOT/scripts/runtests.swift"
SHIM_BIN="$REPO_ROOT/.build/runtests"
BUNDLE_BIN="$REPO_ROOT/.build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest/Contents/MacOS/PropertyTestingKitPackageTests"

if [ ! -f "$BUNDLE_BIN" ]; then
    echo "runtests.sh: test bundle not found at $BUNDLE_BIN" >&2
    echo "  build first: ./scripts/build-local-toolchain.sh test --filter <something>" >&2
    exit 5
fi

# Build the shim if missing or outdated.
if [ ! -f "$SHIM_BIN" ] || [ "$SHIM_SRC" -nt "$SHIM_BIN" ]; then
    SDK="$(xcrun --show-sdk-path)"
    "$LOCAL_SWIFTC" -O -sdk "$SDK" "$SHIM_SRC" -o "$SHIM_BIN"
fi

# Default: --testing-library swift-testing (required by SwiftPM's runner main
# to actually invoke the test entry point). Users can override.
HAS_TESTING_LIBRARY=0
for arg in "$@"; do
    if [ "$arg" = "--testing-library" ]; then HAS_TESTING_LIBRARY=1; break; fi
done

if [ "$HAS_TESTING_LIBRARY" -eq 0 ]; then
    set -- --testing-library swift-testing "$@"
fi

DYLD_FRAMEWORK_PATH="$XCTEST_FW:$SHARED_FW" \
DYLD_LIBRARY_PATH="$LOCAL_RUNTIME:$XCTEST_USR_LIB" \
BUNDLE_PATH="$BUNDLE_BIN" \
exec "$SHIM_BIN" "$@"
