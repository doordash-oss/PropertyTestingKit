#!/bin/bash
# Run TSan tests with the ThreadSanitizer runtime loaded early
#
# TSan requires being loaded before any other libraries via DYLD_INSERT_LIBRARIES.
# This script sets up the environment and runs the tests with TSan race detection.
#
# Usage:
#   ./scripts/run-tsan-tests.sh           # Run all tests with TSan
#   ./scripts/run-tsan-tests.sh 120       # Run for max 120 seconds
#
# HOW THIS WORKS:
# macOS SIP (System Integrity Protection) strips DYLD_INSERT_LIBRARIES from
# binaries in protected paths like /usr/bin and /Applications. To work around
# this, we copy xctest to /tmp (not SIP-protected) and run from there.
#
# Reference: https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html
# "Any dynamic linker (dyld) environment variables, such as DYLD_LIBRARY_PATH,
# are purged when launching protected processes."
#
# NOTE: TSan adds significant overhead. A full test run may take 10+ minutes.
# Use the timeout parameter to limit runtime for quick checks.

set -e

# Optional timeout in seconds (first argument)
TIMEOUT_SECS="${1:-0}"

# Configuration - adjust these paths as needed
SWIFT_BUILD="${SWIFT_BUILD:-/Users/alex.reilly/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64}"
LOCAL_TOOLCHAIN="${LOCAL_TOOLCHAIN:-/Users/alex.reilly/Library/Developer/Toolchains/swift-local-complete.xctoolchain}"
SNAPSHOT_SWIFT="${SNAPSHOT_SWIFT:-/Users/alex.reilly/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2025-12-01-a.xctoolchain/usr/bin/swift}"

# Local runtime path (required for parameter pack support)
LOCAL_RUNTIME="$SWIFT_BUILD/lib/swift/macosx"

# TSan runtime library location
TSAN_LIB="/Users/alex.reilly/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2025-12-01-a.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.tsan_osx_dynamic.dylib"

# Verify TSan library exists
if [[ ! -f "$TSAN_LIB" ]]; then
    echo "Error: TSan runtime library not found at: $TSAN_LIB"
    exit 1
fi

# Verify local runtime exists
if [[ ! -f "$LOCAL_RUNTIME/libswiftCore.dylib" ]]; then
    echo "Error: Local runtime not found at $LOCAL_RUNTIME"
    echo "Make sure SWIFT_BUILD points to your Swift build directory"
    exit 1
fi

# Debug flag for parameter pack issue
DEBUG_FLAG="-Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types"

echo "Building TSan tests..."
"$SNAPSHOT_SWIFT" build \
    --toolchain "$LOCAL_TOOLCHAIN" \
    $DEBUG_FLAG \
    --build-tests

# Find the test bundle
TEST_BUNDLE=".build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest"

if [[ ! -d "$TEST_BUNDLE" ]]; then
    echo "Error: Test bundle not found at: $TEST_BUNDLE"
    exit 1
fi

# Find xctest from Xcode
XCTEST_SRC=$(xcrun --find xctest)
if [[ ! -f "$XCTEST_SRC" ]]; then
    echo "Error: xctest not found"
    exit 1
fi

# Copy xctest to a non-SIP location so DYLD_INSERT_LIBRARIES works
XCTEST_DST="/tmp/xctest-tsan"
cp "$XCTEST_SRC" "$XCTEST_DST"
chmod +x "$XCTEST_DST"

# XCTest framework paths needed by xctest
XCODE_PLATFORMS="/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform"
FRAMEWORK_PATH="$XCODE_PLATFORMS/Developer/Library/Frameworks"
LIBRARY_PATH="$XCODE_PLATFORMS/Developer/usr/lib"

echo ""
echo "Running TSan tests..."
if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
    echo "Timeout: ${TIMEOUT_SECS}s"
fi
echo ""

# Function to run tests
run_tests() {
    env \
        DYLD_INSERT_LIBRARIES="$TSAN_LIB" \
        DYLD_FRAMEWORK_PATH="$FRAMEWORK_PATH" \
        DYLD_LIBRARY_PATH="$LOCAL_RUNTIME:$LIBRARY_PATH" \
        "$XCTEST_DST" "$TEST_BUNDLE"
}

# Run with TSan. The copied xctest in /tmp is not SIP-protected,
# so DYLD_INSERT_LIBRARIES will work.
if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
    # Run with timeout
    run_tests &
    PID=$!
    sleep "$TIMEOUT_SECS"
    if kill -0 "$PID" 2>/dev/null; then
        echo ""
        echo "Timeout reached after ${TIMEOUT_SECS}s, stopping tests..."
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    else
        wait "$PID"
    fi
else
    # Run without timeout
    run_tests
fi

# Clean up
rm -f "$XCTEST_DST"

echo ""
echo "TSan test run complete. Check output for 'ThreadSanitizer' warnings."
