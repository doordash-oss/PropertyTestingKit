#!/bin/bash
#
# open-instruments.sh
#
# Profiles a benchmark in Instruments and opens the resulting trace in the GUI.
#
# Usage:
#   ./scripts/open-instruments.sh [benchmark-name] [time-limit]
#
# Examples:
#   ./scripts/open-instruments.sh                         # ProfiledBenchmark, 20s
#   ./scripts/open-instruments.sh ProfiledBenchmark 30s
#   PROFILE_STRATEGY=newedge FUZZ_MS=400 ./scripts/open-instruments.sh
#
# Why this script does NOT just open Instruments and let you "Choose Target":
#   This project links against the PATCHED local toolchain's Swift runtime, but
#   the binary records an absolute dependency on /usr/lib/swift/libswiftCore.dylib
#   ("Swift in the OS"). The patched runtime ships a newer libswiftCore (with
#   symbols like _swift_coroFrameAlloc that the running OS's copy lacks), and the
#   ONLY lever that redirects the binary to it is DYLD_LIBRARY_PATH (it overrides
#   by leaf name even for an absolute-path dependency; an -rpath cannot). The
#   Instruments GUI "Choose Target" launch path does not set DYLD_LIBRARY_PATH, so
#   the binary aborts at launch with "Symbol not found: _swift_coroFrameAlloc".
#   We therefore launch the binary OURSELVES with the runtime on the path and
#   attach xctrace, then open the finished trace. (xctrace --launch is avoided: it
#   prematurely terminates the target when run from a shebang script.)
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BENCHMARK_NAME="${1:-ProfiledBenchmark}"
TIME_LIMIT="${2:-20s}"

cd "$PROJECT_ROOT"

# Local patched toolchain runtime (the libswiftCore with the symbols the binary
# needs). xctrace requires FULL Xcode, not the Command Line Tools.
: "${BUILD_ROOT:=/Users/fnord/Documents/OpenSourceDev/build/Ninja-RelWithDebInfoAssert}"
export BUILD_ROOT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
RT="$BUILD_ROOT/swift-macosx-arm64/lib/swift/macosx"

if [[ ! -f "$RT/libswiftCore.dylib" ]]; then
    echo "Error: local runtime not found at $RT" >&2
    echo "Set BUILD_ROOT to your patched-toolchain build dir." >&2
    exit 1
fi

echo "=== Building $BENCHMARK_NAME (debug, for symbols) ==="
./scripts/build-local-toolchain.sh build --product "$BENCHMARK_NAME"

EXECUTABLE="$PROJECT_ROOT/.build/debug/$BENCHMARK_NAME"
if [[ ! -f "$EXECUTABLE" ]]; then
    echo "Error: Executable not found at $EXECUTABLE" >&2
    exit 1
fi

echo "=== Generating dSYM ==="
dsymutil "$EXECUTABLE" -o "${EXECUTABLE}.dSYM" 2>/dev/null || true

mkdir -p traces
TRACE_FILE="traces/${BENCHMARK_NAME}.trace"
rm -rf "$TRACE_FILE"

echo "=== Recording (Time Profiler, limit $TIME_LIMIT) ==="
echo "Strategy: ${PROFILE_STRATEGY:-boundarystate}  FUZZ_MS=${FUZZ_MS:-100}  CMP_PER_INPUT=${CMP_PER_INPUT:-256}"
echo ""

# Launch the target ourselves WITH the patched runtime on the dyld path, then
# attach. This is the part the GUI cannot do.
DYLD_LIBRARY_PATH="$RT" BENCHMARK_DISABLE_JEMALLOC=true \
  "$EXECUTABLE" --quiet true >"/tmp/${BENCHMARK_NAME}-run.log" 2>&1 &
BENCH_PID=$!
sleep 1.0
if ! ps -p $BENCH_PID >/dev/null; then
    echo "Benchmark exited before profiling could attach; see /tmp/${BENCHMARK_NAME}-run.log" >&2
    cat "/tmp/${BENCHMARK_NAME}-run.log" >&2
    exit 1
fi

xcrun xctrace record --template "Time Profiler" --output "$TRACE_FILE" \
    --time-limit "$TIME_LIMIT" --attach "$BENCH_PID"
wait $BENCH_PID 2>/dev/null || true

echo ""
echo "=== Opening $TRACE_FILE in Instruments ==="
open "$TRACE_FILE"

echo ""
echo "Headless aggregation (no GUI needed):"
echo "  xcrun xctrace export --input '$TRACE_FILE' \\"
echo "    --xpath '/trace-toc/run[@number=\"1\"]/data/table[@schema=\"time-profile\"]' > /tmp/${BENCHMARK_NAME}-tp.xml"
echo "  ./scripts/aggregate-time-profile.py /tmp/${BENCHMARK_NAME}-tp.xml --top 30"
