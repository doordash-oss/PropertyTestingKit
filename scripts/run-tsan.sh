#!/bin/bash
# Run the concurrency tests under ThreadSanitizer and FAIL on any data race.
#
# This is the regression guard for the SanCovHooks lock-free registries and the
# coverage-inheritance routing. It builds the package with `--sanitize=thread`,
# which instruments EVERY module — including the SanCovHooks C code and
# PropertyTestingKit — where the races live. (A per-target `-sanitize=thread`
# unsafeFlag only instruments that one target, NOT its dependencies, so it would
# miss races in the code under test. The build-level flag is required.)
#
# Usage:
#   ./scripts/run-tsan.sh                 # default: the concurrency/race tests
#   ./scripts/run-tsan.sh '<regex>'       # custom swift-testing name filter
#   ./scripts/run-tsan.sh '.'             # everything (slow: TSan is ~5-10x)
#
# Requires the same environment as build-local-toolchain.sh:
#   export BUILD_ROOT=.../OpenSourceDev/build/Ninja-RelWithDebInfoAssert
#   export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
#
# Exit codes: 0 = no races; 1 = race(s) detected; 2 = build/run error.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# Default workload: the dedicated concurrency stress + the straggler/inheritance
# gate test. Override with a regex argument to widen coverage.
FILTER="${1:-concurrentBeginRouteEndStress|stragglerAfterEndMeasurementDoesNotRouteToFreedContext}"
LOG="${TSAN_LOG:-/tmp/ptk-run-tsan.log}"

echo "=== ThreadSanitizer regression run ==="
echo "filter: $FILTER"
echo "log:    $LOG"
echo ""

./scripts/build-local-toolchain.sh test --sanitize=thread --filter "$FILTER" > "$LOG" 2>&1
status=$?

# grep -c prints the count (0 when none) and may exit 1; the assignment keeps
# the printed "0". Do NOT add `|| echo 0` — that yields a two-line "0\n0".
races=$(grep -cE 'WARNING: ThreadSanitizer' "$LOG")
ran=$(grep -cE 'Test run with' "$LOG")

if [ "$races" -gt 0 ]; then
    echo "FAIL: ThreadSanitizer detected $races warning(s):"
    grep -oE 'SUMMARY: ThreadSanitizer: [a-z ]+ [^ ]+ in [A-Za-z_:]+' "$LOG" | sort | uniq -c | sort -rn | head -30
    echo ""
    echo "Full report: $LOG"
    exit 1
fi

if [ "$ran" -eq 0 ]; then
    echo "FAIL: tests did not run (build or harness error, exit $status). Tail:"
    tail -25 "$LOG"
    exit 2
fi

echo "PASS: no data races detected."
grep -E 'Test run with' "$LOG" | tail -1
exit 0
