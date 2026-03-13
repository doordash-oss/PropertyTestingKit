#!/bin/bash
# Run a test filter repeatedly until it fails or hits max runs.
# Usage: ./scripts/test-until-failure.sh <filter> [max_runs]
# Output: /tmp/test-failure-run{N}.log

set -e

FILTER="${1:?Usage: $0 <filter> [max_runs]}"
MAX_RUNS="${2:-100}"

echo "Running '$FILTER' up to $MAX_RUNS times until failure..."

for i in $(seq 1 "$MAX_RUNS"); do
    LOG="/tmp/test-failure-run${i}.log"
    echo -n "Run $i/$MAX_RUNS... "
    if ./scripts/build-local-toolchain.sh test --filter "$FILTER" > "$LOG" 2>&1; then
        echo "passed"
    else
        echo "FAILED — see $LOG"
        exit 1
    fi
done

echo "All $MAX_RUNS runs passed."
