#!/bin/bash
# Show coverage for a file without re-running tests
# Usage: ./scripts/show-coverage.sh <file> [lines]
# Examples:
#   ./scripts/show-coverage.sh Corpus.swift           # Show full file coverage
#   ./scripts/show-coverage.sh Corpus.swift 195-210   # Show specific lines

set -e

FILE="${1:?Usage: show-coverage.sh <file> [lines]}"
LINES="${2:-}"
CODECOV_DIR=".build/arm64-apple-macosx/debug/codecov"
BINARY=".build/debug/PropertyTestingKitPackageTests.xctest/Contents/MacOS/PropertyTestingKitPackageTests"
PROFDATA="$CODECOV_DIR/merged.profdata"

if [ ! -f "$PROFDATA" ]; then
    echo "No coverage data found. Run ./scripts/coverage.sh first."
    exit 1
fi

# Find the file
FILEPATH=$(find Sources Tests -name "*$FILE*" 2>/dev/null | head -1)
if [ -z "$FILEPATH" ]; then
    echo "File not found: $FILE"
    exit 1
fi

if [ -n "$LINES" ]; then
    # Show specific lines
    xcrun llvm-cov show "$BINARY" -instr-profile="$PROFDATA" "$FILEPATH" 2>/dev/null | sed -n "${LINES}p"
else
    # Show full file
    xcrun llvm-cov show "$BINARY" -instr-profile="$PROFDATA" "$FILEPATH" 2>/dev/null
fi
