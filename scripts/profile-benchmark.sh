#!/bin/bash
#
# profile-benchmark.sh
#
# Records a benchmark with Instruments, extracts call tree, and analyzes it.
# NOTE: Uses /bin/bash directly instead of /usr/bin/env bash because xctrace
# has issues with the env indirection when profiling processes.
#
# Usage:
#   ./scripts/profile-benchmark.sh [benchmark-name] [options]
#
# Options:
#   --template <name>     Instruments template (default: SimpleTime)
#   --time-limit <dur>    Recording duration (default: 60s)
#   --output <name>       Output file base name (default: benchmark name)
#   --open                Open trace in Instruments after recording
#   --skip-build          Skip building the benchmark
#   --release             Build in release mode (default: debug for symbols)
#   --analyze-only        Only analyze existing call tree, don't record
#
# Examples:
#   ./scripts/profile-benchmark.sh ProfiledBenchmark
#   ./scripts/profile-benchmark.sh ProfiledBenchmark --time-limit 30s --open
#   ./scripts/profile-benchmark.sh --analyze-only   # Analyze call_trees/tree.txt
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default values
BENCHMARK_NAME="ProfiledBenchmark"
TEMPLATE="SimpleTime"
TIME_LIMIT="60s"
OUTPUT_NAME=""
OPEN_TRACE=false
SKIP_BUILD=false
BUILD_MODE="debug"
ANALYZE_ONLY=false

# Parse first positional argument as benchmark name
if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
    BENCHMARK_NAME="$1"
    shift
fi

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --template)
            TEMPLATE="$2"
            shift 2
            ;;
        --time-limit)
            TIME_LIMIT="$2"
            shift 2
            ;;
        --output)
            OUTPUT_NAME="$2"
            shift 2
            ;;
        --open)
            OPEN_TRACE=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --analyze-only)
            ANALYZE_ONLY=true
            shift
            ;;
        -h|--help)
            head -25 "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Set output name if not specified
OUTPUT_NAME="${OUTPUT_NAME:-$BENCHMARK_NAME}"

cd "$PROJECT_ROOT"

# Create output directories
mkdir -p traces
mkdir -p call_trees

TRACE_FILE="traces/${OUTPUT_NAME}.trace"
CALLTREE_FILE="call_trees/${OUTPUT_NAME}.txt"

# If analyze-only, just run analysis
if [[ "$ANALYZE_ONLY" == true ]]; then
    if [[ -f "call_trees/tree.txt" ]]; then
        CALLTREE_FILE="call_trees/tree.txt"
    fi
    if [[ ! -f "$CALLTREE_FILE" ]]; then
        echo "Error: No call tree file found at $CALLTREE_FILE"
        exit 1
    fi
    echo "=== Analyzing $CALLTREE_FILE ==="
    python3 "$SCRIPT_DIR/parse-call-tree.py" "$CALLTREE_FILE" --top 30
    exit 0
fi

# Build the benchmark
if [[ "$SKIP_BUILD" == false ]]; then
    echo "=== Building $BENCHMARK_NAME ($BUILD_MODE mode) ==="
    if [[ "$BUILD_MODE" == "release" ]]; then
        ./scripts/build-local-toolchain.sh build -c release --product "$BENCHMARK_NAME"
        EXECUTABLE=".build/release/$BENCHMARK_NAME"
    else
        ./scripts/build-local-toolchain.sh build --product "$BENCHMARK_NAME"
        EXECUTABLE=".build/debug/$BENCHMARK_NAME"
    fi
else
    if [[ "$BUILD_MODE" == "release" ]]; then
        EXECUTABLE=".build/release/$BENCHMARK_NAME"
    else
        EXECUTABLE=".build/debug/$BENCHMARK_NAME"
    fi
fi

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "Error: Executable not found at $EXECUTABLE"
    echo "Run without --skip-build to build it first."
    exit 1
fi

# Generate dSYM for better symbols
echo "=== Generating dSYM ==="
dsymutil "$EXECUTABLE" -o "${EXECUTABLE}.dSYM" 2>/dev/null || true

# Check if custom template exists, fall back to Time Profiler
if ! xcrun xctrace list templates 2>/dev/null | grep -q "^$TEMPLATE$"; then
    echo "Warning: Template '$TEMPLATE' not found."
    if xcrun xctrace list templates 2>/dev/null | grep -q "^SimpleTime$"; then
        TEMPLATE="SimpleTime"
    else
        echo "Using 'Time Profiler' instead."
        echo ""
        echo "To create SimpleTime template:"
        echo "  1. Open Instruments"
        echo "  2. Choose 'Time Profiler'"
        echo "  3. File > Save As Template... > 'SimpleTime'"
        echo ""
        TEMPLATE="Time Profiler"
    fi
fi

# Remove old trace
rm -rf "$TRACE_FILE"

echo "=== Recording with Instruments ==="
echo "Template:   $TEMPLATE"
echo "Executable: $EXECUTABLE"
echo "Time limit: $TIME_LIMIT"
echo "Output:     $TRACE_FILE"
echo ""

# Record with xctrace
# NOTE: We use --attach instead of --launch due to a bug where xctrace --launch
# causes premature process termination when invoked from shebang scripts (./script.sh)
# but works fine with explicit bash invocation (bash script.sh).
# Workaround: Start the benchmark in background, then attach xctrace to it.

"$EXECUTABLE" --quiet true &
BENCH_PID=$!
echo "Started benchmark with PID: $BENCH_PID"

# Give the process a moment to start up
sleep 0.1

# Attach xctrace to the running process
xcrun xctrace record \
    --template "$TEMPLATE" \
    --output "$TRACE_FILE" \
    --time-limit "$TIME_LIMIT" \
    --attach "$BENCH_PID"

# Wait for benchmark to finish (in case xctrace detaches early)
wait $BENCH_PID 2>/dev/null || true

echo ""
echo "=== Recording complete ==="

# Open trace if requested
if [[ "$OPEN_TRACE" == true ]]; then
    echo "Opening trace in Instruments..."
    open "$TRACE_FILE"
fi

echo ""
echo "=== Results ==="
echo "Trace file: $TRACE_FILE"
echo ""
echo "To extract call tree:"
echo "  1. Open trace: open '$TRACE_FILE'"
echo "  2. Select Time Profiler > Call Tree view"
echo "  3. Cmd+A to select all, then Edit > Deep Copy"
echo "  4. Paste into: $CALLTREE_FILE"
echo ""
echo "Then analyze with:"
echo "  ./scripts/parse-call-tree.py $CALLTREE_FILE"
echo ""
echo "Or analyze existing call tree:"
echo "  ./scripts/parse-call-tree.py call_trees/tree.txt"
