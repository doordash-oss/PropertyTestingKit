#!/bin/bash
# Build/test PropertyTestingKit using the locally compiled Swift toolchain
# with @_spi(ForToolsIntegrationOnly) APIs from swift-testing
#
# Usage:
#   ./scripts/build-local-toolchain.sh              # build
#   ./scripts/build-local-toolchain.sh test         # run tests with local runtime
#   ./scripts/build-local-toolchain.sh -c release   # release build
#
# Prerequisites (see LOCAL_TOOLCHAIN_TESTING_NOTES.md for details):
#   1. Build Swift toolchain: utils/build-script --swift-testing --install-swift ...
#   2. Build TestingMacros: utils/build-script --swift-testing-macros --install-swift-testing-macros ...
#   3. Copy Testing components to compiler directory (see notes)
#   4. Build SwiftPM with bootstrap

set -e

# Configuration - adjust these paths as needed
BUILD_ROOT="${BUILD_ROOT:-$HOME/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert}"
SWIFT_BUILD="$BUILD_ROOT/swift-macosx-arm64"
SWIFTPM_BUILD="$BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/release"
SWIFTTESTING_BUILD="$BUILD_ROOT/swifttesting-macosx-arm64"

# Local compiler and runtime
LOCAL_SWIFTC="$SWIFT_BUILD/bin/swiftc"
LOCAL_RUNTIME="$SWIFT_BUILD/lib/swift/macosx"

# Local SwiftPM binaries
LOCAL_SWIFT_BUILD="$SWIFTPM_BUILD/swift-build"
LOCAL_SWIFT_TEST="$SWIFTPM_BUILD/swift-test"

# Flags to use our Testing module instead of Xcode's
# -I flag makes our Testing.swiftmodule take precedence
TESTING_FLAGS="-Xswiftc -I$SWIFTTESTING_BUILD/swift"

# package-benchmark transitively depends on package-jemalloc, which requires
# system jemalloc headers. Skip it unless the user has jemalloc installed and
# explicitly opts in by setting BENCHMARK_DISABLE_JEMALLOC=0.
export BENCHMARK_DISABLE_JEMALLOC="${BENCHMARK_DISABLE_JEMALLOC:-1}"

cd "$(dirname "$0")/.."

# Clean build artifacts if they exist from a different toolchain
BUILD_MARKER=".build/.toolchain-marker"
if [ -d ".build" ]; then
    if [ ! -f "$BUILD_MARKER" ] || [ "$(cat "$BUILD_MARKER" 2>/dev/null)" != "local-build" ]; then
        echo "Cleaning build cache (toolchain mismatch)..."
        rm -rf .build
    fi
fi

# Mark the build as using local toolchain
mkdir -p .build
echo "local-build" > "$BUILD_MARKER"

# Verify local swiftc exists
if [ ! -f "$LOCAL_SWIFTC" ]; then
    echo "Error: Local swiftc not found at $LOCAL_SWIFTC"
    echo "Build the Swift toolchain first - see LOCAL_TOOLCHAIN_TESTING_NOTES.md"
    exit 1
fi

# Verify local runtime exists
if [ ! -f "$LOCAL_RUNTIME/libswiftCore.dylib" ]; then
    echo "Error: Local runtime not found at $LOCAL_RUNTIME"
    echo "Build the Swift toolchain first - see LOCAL_TOOLCHAIN_TESTING_NOTES.md"
    exit 1
fi

# Verify TestingMacros plugin exists
TESTING_MACROS="$SWIFT_BUILD/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ ! -f "$TESTING_MACROS" ]; then
    echo "Error: TestingMacros not found at $TESTING_MACROS"
    echo ""
    echo "Build and copy TestingMacros:"
    echo "  1. utils/build-script --swift-testing-macros --install-swift-testing-macros ..."
    echo "  2. mkdir -p $SWIFT_BUILD/lib/swift/host/plugins/testing"
    echo "  3. cp \$TOOLCHAIN/.../plugins/testing/libTestingMacros.dylib $TESTING_MACROS"
    echo ""
    echo "See LOCAL_TOOLCHAIN_TESTING_NOTES.md for full instructions."
    exit 1
fi

# Verify Testing module exists
if [ ! -f "$LOCAL_RUNTIME/Testing.swiftmodule" ]; then
    echo "Error: Testing.swiftmodule not found at $LOCAL_RUNTIME"
    echo ""
    echo "Copy Testing module from swift-testing build:"
    echo "  cp $SWIFTTESTING_BUILD/swift/Testing.swiftmodule $LOCAL_RUNTIME/"
    echo "  cp $SWIFTTESTING_BUILD/swift/Testing.private.swiftinterface $LOCAL_RUNTIME/"
    echo "  cp $SWIFTTESTING_BUILD/lib/libTesting.dylib $LOCAL_RUNTIME/"
    echo ""
    echo "See LOCAL_TOOLCHAIN_TESTING_NOTES.md for full instructions."
    exit 1
fi

# Check if Testing libraries are code signed (required on macOS)
if ! codesign -v "$LOCAL_RUNTIME/libTesting.dylib" 2>/dev/null; then
    echo "Ad-hoc signing Testing libraries (required for macOS)..."
    codesign -s - "$LOCAL_RUNTIME/libTesting.dylib"
    codesign -s - "$LOCAL_RUNTIME/lib_Testing_Foundation.dylib" 2>/dev/null
    codesign -s - "$SWIFT_BUILD/lib/swift/host/plugins/testing/libTestingMacros.dylib" 2>/dev/null
fi

# First argument determines the command (build or test)
CMD="${1:-build}"

if [[ "$CMD" == "test" ]]; then
    shift

    # Verify local swift-test exists
    if [ ! -f "$LOCAL_SWIFT_TEST" ]; then
        echo "Error: Local swift-test not found at $LOCAL_SWIFT_TEST"
        echo "Build SwiftPM first - see LOCAL_TOOLCHAIN_TESTING_NOTES.md"
        echo ""
        echo "Falling back to xctest runner..."
        ./scripts/run-xctest.sh "$@"
        exit $?
    fi

    echo "=== Running tests with local toolchain ==="
    echo "Using compiler: $LOCAL_SWIFTC"
    echo "Using swift-test: $LOCAL_SWIFT_TEST"
    echo "Using runtime: $LOCAL_RUNTIME"
    echo "Using Testing: $SWIFTTESTING_BUILD/swift"
    echo ""

    DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" \
    SWIFT_EXEC="$LOCAL_SWIFTC" \
    "$LOCAL_SWIFT_TEST" $TESTING_FLAGS "$@"

elif [[ "$CMD" == "build" ]]; then
    # Only shift if there was an actual argument (not default)
    [[ $# -gt 0 ]] && shift

    # For build, we can use either local or system swift-build
    if [ -f "$LOCAL_SWIFT_BUILD" ]; then
        echo "=== Building with local toolchain ==="
        echo "Using compiler: $LOCAL_SWIFTC"
        echo "Using swift-build: $LOCAL_SWIFT_BUILD"
        echo "Using runtime: $LOCAL_RUNTIME"
        echo "Using Testing: $SWIFTTESTING_BUILD/swift"
        echo ""

        DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" \
        SWIFT_EXEC="$LOCAL_SWIFTC" \
        "$LOCAL_SWIFT_BUILD" $TESTING_FLAGS "$@"
    else
        echo "=== Building with local compiler (system SwiftPM) ==="
        echo "Using compiler: $LOCAL_SWIFTC"
        echo ""

        SWIFT_EXEC="$LOCAL_SWIFTC" \
        swift build $TESTING_FLAGS "$@"
    fi
else
    # Unknown command, pass everything through as build args
    echo "Using compiler: $LOCAL_SWIFTC"
    SWIFT_EXEC="$LOCAL_SWIFTC" \
    swift build $TESTING_FLAGS "$@"
fi
