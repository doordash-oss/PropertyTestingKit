#!/bin/bash
#
# record-cmp-profile.sh <name> [strategy] [cmp_per_input] [fuzz_ms] [time_limit]
#
# Headless CPU profile of the comparison-dispatch hot path (no Instruments GUI).
# Rebuilds ProfiledBenchmark, records a Time Profiler trace via xctrace --attach,
# exports the time-profile table, and aggregates self-time within the
# sancov_dispatch_cmp subtree. Reusable feedback loop for the onCompare rework.
#
# Outputs: traces/<name>.trace, /tmp/<name>-tp.xml, and the aggregated breakdown.
set -e

NAME="${1:-cmp}"
STRATEGY="${2:-boundarystate}"
CMP="${3:-256}"
FUZZ_MS="${4:-400}"
LIMIT="${5:-25s}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

: "${BUILD_ROOT:=/Users/fnord/Documents/OpenSourceDev/build/Ninja-RelWithDebInfoAssert}"
export BUILD_ROOT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
RT="$BUILD_ROOT/swift-macosx-arm64/lib/swift/macosx"
BIN=".build/debug/ProfiledBenchmark"

echo "=== build ==="
./scripts/build-local-toolchain.sh build --product ProfiledBenchmark >/tmp/$NAME-build.log 2>&1 \
  || { echo "build failed"; tail -20 /tmp/$NAME-build.log; exit 1; }
dsymutil "$BIN" -o "$BIN.dSYM" 2>/dev/null || true

mkdir -p traces
rm -rf "traces/$NAME.trace"
echo "=== record ($STRATEGY, cmp=$CMP, fuzz_ms=$FUZZ_MS, limit=$LIMIT) ==="
DYLD_LIBRARY_PATH="$RT" BENCHMARK_DISABLE_JEMALLOC=true \
  PROFILE_STRATEGY="$STRATEGY" CMP_PER_INPUT="$CMP" FUZZ_MS="$FUZZ_MS" \
  "$BIN" --quiet true >/tmp/$NAME-run.log 2>&1 &
P=$!
sleep 1.5
if ! ps -p $P >/dev/null; then echo "benchmark exited early; see /tmp/$NAME-run.log"; cat /tmp/$NAME-run.log; exit 1; fi
xcrun xctrace record --template "Time Profiler" --output "traces/$NAME.trace" \
  --time-limit "$LIMIT" --attach $P 2>/tmp/$NAME-rec.log
wait $P 2>/dev/null || true

echo "=== export + aggregate ==="
xcrun xctrace export --input "traces/$NAME.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' >"/tmp/$NAME-tp.xml" 2>/dev/null
echo "--- self-time within sancov_dispatch_cmp subtree ---"
./scripts/aggregate-time-profile.py "/tmp/$NAME-tp.xml" --under sancov_dispatch_cmp --top 20
