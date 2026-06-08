#!/bin/bash
# Build, test, and (optionally) validate the ETNA workloads that exercise
# PropertyTestingKit as a coverage-guided testing strategy.
#
# The six workload repos live BESIDE this one (siblings of PropertyTestingKit):
#   etna-swift-{bst,rbt,stlc,fsub,luparser,ifc}
# Each is a standalone SwiftPM package depending on ../PropertyTestingKit, with a
# uniform scripts/swift-toolchain.sh (build/test) interface.
#
# Usage:
#   ./scripts/run-workloads.sh                 # build + test every workload found
#   ./scripts/run-workloads.sh bst ifc         # only the named workloads
#   ./scripts/run-workloads.sh --detect        # also run each workload's mutant-detection sanity check
#   ./scripts/run-workloads.sh --oracle        # also run each workload's oracle (needs Coq: etna-coq opam switch)
#   ./scripts/run-workloads.sh --no-test        # build only (skip the test suites)
#   ./scripts/run-workloads.sh --list          # list workloads and exit
#
# Notes:
#   * --detect / --oracle are opt-in: they need extra toolchains (Coq/QuickChick
#     via the etna-coq opam switch, or Haskell/stack) and take longer.
#   * Set BUILD_ROOT to your patched-toolchain build dir; it is passed through to
#     each workload's swift-toolchain.sh (which also has its own default).
#   * Full per-step output goes to scripts/.workload-logs/<workload>.<step>.log;
#     the console shows a PASS/FAIL summary. Exit code is non-zero if any step failed.
set -uo pipefail

WORKLOADS=(bst rbt stlc fsub luparser ifc)

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIBLINGS="$(cd "$REPO_ROOT/.." && pwd)"
LOG_DIR="$REPO_ROOT/scripts/.workload-logs"

DO_TEST=1
DO_DETECT=0
DO_ORACLE=0
SELECTED=()

for arg in "$@"; do
    case "$arg" in
        --no-test) DO_TEST=0 ;;
        --detect)  DO_DETECT=1 ;;
        --oracle)  DO_ORACLE=1 ;;
        --list)
            echo "workloads (siblings of $REPO_ROOT):"
            for w in "${WORKLOADS[@]}"; do
                d="$SIBLINGS/etna-swift-$w"
                printf "  %-10s %s\n" "$w" "$([ -d "$d" ] && echo "$d" || echo '(missing)')"
            done
            exit 0 ;;
        -h|--help)
            sed -n '2,33p' "$0"; exit 0 ;;
        --*)
            echo "unknown flag: $arg" >&2; exit 2 ;;
        *)
            SELECTED+=("$arg") ;;
    esac
done

# Default to all workloads when none named.
if [ "${#SELECTED[@]}" -eq 0 ]; then
    SELECTED=("${WORKLOADS[@]}")
fi

mkdir -p "$LOG_DIR"
declare -a RESULTS   # "workload step status" lines for the summary
OVERALL=0

# run <workload> <step-label> <dir> <command...>
run_step() {
    local w="$1" step="$2" dir="$3"; shift 3
    local log="$LOG_DIR/$w.$step.log"
    printf '  %-8s %-7s ... ' "$w" "$step"
    if ( cd "$dir" && "$@" ) >"$log" 2>&1; then
        echo "PASS"
        RESULTS+=("$w $step PASS")
    else
        echo "FAIL  (see $log)"
        RESULTS+=("$w $step FAIL")
        OVERALL=1
    fi
}

echo "== ETNA workloads =="
echo "siblings dir: $SIBLINGS"
echo "logs:         $LOG_DIR"
echo

for w in "${SELECTED[@]}"; do
    dir="$SIBLINGS/etna-swift-$w"
    if [ ! -d "$dir" ]; then
        echo "  $w: MISSING ($dir) — skipping"
        RESULTS+=("$w repo MISSING")
        OVERALL=1
        continue
    fi
    tc="$dir/scripts/swift-toolchain.sh"

    run_step "$w" "build" "$dir" "$tc" build
    [ "$DO_TEST" -eq 1 ]   && run_step "$w" "test"   "$dir" "$tc" test

    if [ "$DO_DETECT" -eq 1 ] && [ -x "$dir/scripts/detect.sh" ]; then
        run_step "$w" "detect" "$dir" "./scripts/detect.sh"
    fi

    if [ "$DO_ORACLE" -eq 1 ]; then
        # Coq oracles follow the oracle/<name>/run.sh convention.
        for orc in "$dir"/oracle/*/run.sh; do
            [ -f "$orc" ] || continue
            run_step "$w" "oracle" "$(dirname "$orc")" "./run.sh"
        done
    fi
done

echo
echo "== summary =="
printf '%-10s %-8s %s\n' "WORKLOAD" "STEP" "RESULT"
for line in "${RESULTS[@]}"; do
    # shellcheck disable=SC2086
    set -- $line
    printf '%-10s %-8s %s\n' "$1" "$2" "$3"
done

echo
if [ "$OVERALL" -eq 0 ]; then
    echo "All steps passed."
else
    echo "Some steps FAILED."
fi
exit "$OVERALL"
