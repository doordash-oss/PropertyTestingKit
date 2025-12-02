#!/bin/bash
# Run tests with coverage and show report
# Usage: ./scripts/coverage.sh [filter] [file]
# Examples:
#   ./scripts/coverage.sh                    # Run all tests, show summary
#   ./scripts/coverage.sh "Corpus|Schema"    # Run filtered tests, show summary
#   ./scripts/coverage.sh "" Corpus.swift    # Run all tests, show specific file

set -e

FILTER="${1:-}"
FILE="${2:-}"
CODECOV_DIR=".build/arm64-apple-macosx/debug/codecov"
BINARY=".build/debug/PropertyTestingKitPackageTests.xctest/Contents/MacOS/PropertyTestingKitPackageTests"

# Clean old coverage data
mkdir -p "$CODECOV_DIR"
find "$CODECOV_DIR" -name "*.profraw" -delete 2>/dev/null || true

# Run tests with coverage
echo "Running tests..."
if [ -n "$FILTER" ]; then
    LLVM_PROFILE_FILE="$CODECOV_DIR/test_%p.profraw" \
        swift test -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping \
        --filter "$FILTER" 2>&1 | tail -5
else
    LLVM_PROFILE_FILE="$CODECOV_DIR/test_%p.profraw" \
        swift test -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping \
        2>&1 | tail -5
fi

# Merge profile data
echo ""
echo "Merging profile data..."
xcrun llvm-profdata merge "$CODECOV_DIR"/*.profraw -o "$CODECOV_DIR/merged.profdata" 2>/dev/null

# Show coverage
echo ""
if [ -n "$FILE" ]; then
    # Find the file and show detailed coverage
    FILEPATH=$(find Sources Tests -name "*$FILE*" 2>/dev/null | head -1)
    if [ -n "$FILEPATH" ]; then
        echo "Coverage for $FILEPATH:"
        xcrun llvm-cov show "$BINARY" -instr-profile="$CODECOV_DIR/merged.profdata" "$FILEPATH" 2>/dev/null
    else
        echo "File not found: $FILE"
        exit 1
    fi
else
    # Show summary report
    echo "Coverage summary:"
    xcrun llvm-cov report "$BINARY" -instr-profile="$CODECOV_DIR/merged.profdata" 2>/dev/null | head -20
fi
