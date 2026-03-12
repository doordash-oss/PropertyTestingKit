#!/bin/bash
#
# Build and run benchmarks using the local toolchain and runtime.
#
# Usage:
#   ./scripts/run-benchmarks.sh                       # Run all benchmarks (release mode)
#   ./scripts/run-benchmarks.sh --debug-build         # Run all benchmarks (debug mode with coverage)
#   ./scripts/run-benchmarks.sh --filter "fuzz"       # Filter benchmarks by regex
#   ./scripts/run-benchmarks.sh baseline update v1    # Save baseline named "v1"
#   ./scripts/run-benchmarks.sh baseline compare v1   # Compare current run to "v1"
#   ./scripts/run-benchmarks.sh baseline list         # List saved baselines
#   ./scripts/run-benchmarks.sh --compare-last        # Compare to the most recent baseline
#   ./scripts/run-benchmarks.sh --compare-last 3      # Compare to the 3 most recent baselines
#
# All standard swift package benchmark options are supported.
# Use --debug-build to enable coverage instrumentation for fuzzing benchmarks.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration - adjust these paths as needed
BUILD_ROOT="${BUILD_ROOT:-$HOME/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert}"
SWIFT_BUILD="$BUILD_ROOT/swift-macosx-arm64"
SWIFTPM_BUILD="$BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/release"
SWIFTTESTING_BUILD="$BUILD_ROOT/swifttesting-macosx-arm64"

# Local compiler
LOCAL_SWIFTC="$SWIFT_BUILD/bin/swiftc"

# Local swift-package binary
LOCAL_SWIFT_PACKAGE="$SWIFTPM_BUILD/swift-package"

# Local runtime path (required for parameter pack support)
LOCAL_RUNTIME="$SWIFT_BUILD/lib/swift/macosx"

# Flags to use our Testing module instead of Xcode's
TESTING_FLAGS="-Xswiftc -I$SWIFTTESTING_BUILD/swift"

cd "$PROJECT_DIR"

# Handle --compare-last option
COMPARE_LAST=0
REMAINING_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compare-last)
            shift
            # Check if next arg is a number
            if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                COMPARE_LAST="$1"
                shift
            else
                COMPARE_LAST=1
            fi
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done

# Restore remaining args
set -- "${REMAINING_ARGS[@]}"

# Function to find and compare recent baselines (without re-running benchmarks)
compare_last_baselines() {
    local count="$1"
    shift

    BASELINES_DIR="$PROJECT_DIR/.benchmarkBaselines/CoverageBenchmarks"

    if [ ! -d "$BASELINES_DIR" ]; then
        echo "Error: No baselines directory found at $BASELINES_DIR"
        exit 1
    fi

    # Find all results.json files and sort by modification time
    # Get N most recent, then reverse to oldest-to-newest order
    BASELINE_NAMES=()
    while IFS= read -r line; do
        # Extract baseline name from path
        # Path format: .benchmarkBaselines/CoverageBenchmarks/baseline_name/results.json
        path="${line#* }"  # Remove timestamp prefix
        baseline_name=$(basename "$(dirname "$path")")
        BASELINE_NAMES+=("$baseline_name")
    done < <(find "$BASELINES_DIR" -name "results.json" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | \
        sort -rn | \
        head -n "$count" | \
        tail -r)

    if [ ${#BASELINE_NAMES[@]} -eq 0 ]; then
        echo "Error: No baselines found"
        exit 1
    fi

    echo "Comparing ${#BASELINE_NAMES[@]} baseline(s):"
    for b in "${BASELINE_NAMES[@]}"; do
        echo "  - $b"
    done
    echo ""

    # Pass all baseline names to a single compare command (no re-running)
    DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" \
    SWIFT_EXEC="$LOCAL_SWIFTC" \
    $LOCAL_SWIFT_PACKAGE \
        $TESTING_FLAGS \
        --allow-writing-to-package-directory benchmark \
        --target "CoverageBenchmarks" \
        baseline compare "${BASELINE_NAMES[@]}" \
        "$@"
}

# Verify local swift-package exists
if [ ! -f "$LOCAL_SWIFT_PACKAGE" ]; then
    echo "Error: Local swift-package not found at $LOCAL_SWIFT_PACKAGE"
    echo "Make sure SWIFTPM_BUILD points to your SwiftPM build directory"
    exit 1
fi

# Verify local runtime exists
if [ ! -f "$LOCAL_RUNTIME/libswiftCore.dylib" ]; then
    echo "Error: Local runtime not found at $LOCAL_RUNTIME"
    echo "Make sure SWIFT_BUILD points to your Swift build directory"
    exit 1
fi

# Clean build artifacts if they exist from a different toolchain
# This avoids "module compiled with Swift X cannot be imported by Swift Y" errors
BUILD_MARKER=".build/.toolchain-marker"
if [ -d ".build" ]; then
    if [ ! -f "$BUILD_MARKER" ] || [ "$(cat "$BUILD_MARKER" 2>/dev/null)" != "local-build" ]; then
        echo "Cleaning build cache (toolchain mismatch)..."
        rm -rf .build
    fi
fi

# Mark the build as using local toolchain (must match build-local-toolchain.sh)
mkdir -p .build
echo "local-build" > "$BUILD_MARKER"

echo "Running benchmarks with local Swift build..."
echo "Using: $LOCAL_SWIFT_PACKAGE"
echo ""

# Handle --compare-last mode
if [ "$COMPARE_LAST" -gt 0 ]; then
    compare_last_baselines "$COMPARE_LAST" "$@"
    exit 0
fi

# Symlink local Swift runtime libraries to build directory so benchmark subprocess can find them
# (DYLD_LIBRARY_PATH doesn't propagate to the benchmark subprocess due to SIP)
BUILD_OUTPUT_DIR="$PROJECT_DIR/.build/arm64-apple-macosx/debug"
mkdir -p "$BUILD_OUTPUT_DIR"
ln -sf "$LOCAL_RUNTIME/libTesting.dylib" "$BUILD_OUTPUT_DIR/libTesting.dylib"
ln -sf "$LOCAL_RUNTIME/libswift_Concurrency.dylib" "$BUILD_OUTPUT_DIR/libswift_Concurrency.dylib"
ln -sf "$LOCAL_RUNTIME/libswiftCore.dylib" "$BUILD_OUTPUT_DIR/libswiftCore.dylib"

# Run via swift package benchmark
# Use --debug-build for coverage instrumentation
# Optimization flags are set per-target in Package.swift's swiftSettings
exec env \
    DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" \
    SWIFT_EXEC="$LOCAL_SWIFTC" \
    $LOCAL_SWIFT_PACKAGE \
        $TESTING_FLAGS \
        --allow-writing-to-package-directory benchmark \
        --debug-build \
        "$@"
