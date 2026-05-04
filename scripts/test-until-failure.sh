#!/bin/bash
# Run a test filter repeatedly until it fails or hits max runs.
# Usage: ./scripts/test-until-failure.sh <filter> [max_runs]
# Output: /tmp/test-failure-run{N}.log
#
# First run uses `swift test` to ensure the bundle is built. Subsequent runs
# use ./scripts/runtests.sh which dlopens the bundle directly, bypassing
# SwiftPM's per-invocation overhead (~4.4s -> ~0.3s per iteration).

set -e

FILTER="${1:?Usage: $0 <filter> [max_runs]}"
MAX_RUNS="${2:-100}"

echo "Running '$FILTER' up to $MAX_RUNS times until failure..."

# First run: build + test via swift-test (ensures bundle is up-to-date).
LOG="/tmp/test-failure-run1.log"
echo -n "Run 1/$MAX_RUNS (build + test)... "
if ./scripts/build-local-toolchain.sh test --filter "$FILTER" > "$LOG" 2>&1; then
    echo "passed"
else
    echo "FAILED — see $LOG"
    exit 1
fi

# Subsequent runs: dlopen the bundle directly via runtests.sh shim.
for i in $(seq 2 "$MAX_RUNS"); do
    LOG="/tmp/test-failure-run${i}.log"
    echo -n "Run $i/$MAX_RUNS... "
    if ./scripts/runtests.sh --filter "$FILTER" > "$LOG" 2>&1; then
        echo "passed"
    else
        echo "FAILED — see $LOG"
        exit 1
    fi
done

echo "All $MAX_RUNS runs passed."
