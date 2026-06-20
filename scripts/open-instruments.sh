#!/bin/bash
#
# open-instruments.sh
#
# Builds a benchmark for profiling and opens Instruments.
#
# Usage:
#   ./scripts/open-instruments.sh [benchmark-name]
#
# Examples:
#   ./scripts/open-instruments.sh ProfiledBenchmark
#   ./scripts/open-instruments.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BENCHMARK_NAME="${1:-ProfiledBenchmark}"

cd "$PROJECT_ROOT"

echo "=== Building $BENCHMARK_NAME (debug mode for symbols) ==="
./scripts/build-local-toolchain.sh build --product "$BENCHMARK_NAME"

EXECUTABLE="$PROJECT_ROOT/.build/debug/$BENCHMARK_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

echo "=== Generating dSYM ==="
dsymutil "$EXECUTABLE" -o "${EXECUTABLE}.dSYM" 2>/dev/null || true

echo ""
echo "=== Opening Instruments ==="
echo "Executable: $EXECUTABLE"
echo ""
open -a Instruments

echo ""
echo "In Instruments:"
echo "  1. Choose 'Time Profiler' template"
echo "  2. Click the target dropdown (top left) and select 'Choose Target...'"
echo "  3. Navigate to: $EXECUTABLE"
echo "  4. Click Record to start profiling"
