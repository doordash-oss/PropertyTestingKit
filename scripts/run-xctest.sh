#!/bin/bash
# Run PropertyTestingKitTests directly through xctest with the local runtime
# This avoids ABI mismatch issues with swift-test
#
# Note: FuzzerStressTests and RaceDetectionTests are included in the bundle
# but have expected failures (stress tests that push fuzzer limits)

set -e

SWIFT_BUILD="${SWIFT_BUILD:-/Users/alex.reilly/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert/swift-macosx-arm64}"
LOCAL_RUNTIME="$SWIFT_BUILD/lib/swift/macosx"
TEST_BUNDLE=".build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest"
XCTEST="/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xctest"

cd "$(dirname "$0")/.."

if [ ! -d "$TEST_BUNDLE" ]; then
    echo "Error: Test bundle not found at $TEST_BUNDLE"
    echo "Run './scripts/build-local-toolchain.sh build --build-tests' first"
    exit 1
fi

echo "=== Running PropertyTestingKitTests via xctest ==="
echo "Using runtime: $LOCAL_RUNTIME"
echo ""

DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" "$XCTEST" "$TEST_BUNDLE"
