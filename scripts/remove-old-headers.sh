#!/bin/bash
#
# Removes old-style file headers from Swift files.
# These are the comment blocks like:
#   //
#   //  Filename.swift
#   //  ModuleName
#   //
# that appear after the Apache license header (line 15+).
# Stops at the first blank line within the comment block to avoid
# eating doc comments that follow.
#
# Usage: ./scripts/remove-old-headers.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODIFIED=0
SKIPPED=0
TOTAL=0

while IFS= read -r file; do
    TOTAL=$((TOTAL + 1))

    # The license header is 14 lines. Line 15 should start the old header.
    # Old headers look like:
    #   //                          ← blank comment or empty line
    #   //  Filename.swift
    #   //  ModuleName  (or Copyright line)
    #   //
    #   //  Optional description.
    #   //                          ← ends here (blank comment = end of header)

    # Check if line 15 is a blank comment or empty (start of old header)
    LINE15=$(sed -n '15p' "$file")
    if [[ "$LINE15" != "//" && "$LINE15" != "" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Scan from line 15 to find the old header block.
    # The block ends at:
    #   - An empty line (not "//")
    #   - A line that doesn't start with "//"
    #   - A "//" line that comes after a blank "//" line (second blank = end)
    #     This handles: //\n// File.swift\n// Module\n//\n → 4 lines
    # Strategy: find the first "//" (blank comment) AFTER a non-blank "//" line.
    # That trailing "//" is the last line of the header.

    START=15
    END=15
    FOUND_CONTENT=false
    LINE_NUM=15

    while IFS= read -r line; do
        if [[ "$line" == "//" ]]; then
            if $FOUND_CONTENT; then
                # Blank comment after content = end of header block
                END=$LINE_NUM
                break
            fi
        elif [[ "$line" == "//"* ]]; then
            FOUND_CONTENT=true
        else
            # Non-comment line — header ended before this
            END=$((LINE_NUM - 1))
            break
        fi
        LINE_NUM=$((LINE_NUM + 1))
    done < <(sed -n '15,30p' "$file")

    # Must contain the filename to be an old header
    BASENAME=$(basename "$file")
    BLOCK=$(sed -n "${START},${END}p" "$file")
    if ! echo "$BLOCK" | grep -q "$BASENAME"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Also remove the blank line after the header block if present
    NEXT_LINE=$(sed -n "$((END + 1))p" "$file")
    if [[ "$NEXT_LINE" == "" ]]; then
        END=$((END + 1))
    fi

    if $DRY_RUN; then
        echo "[dry-run] ${file#$ROOT/}: remove lines $START-$END"
        echo "$BLOCK"
        echo "---"
    else
        sed -i '' "${START},${END}d" "$file"
        echo "Removed old header from: ${file#$ROOT/}"
    fi
    MODIFIED=$((MODIFIED + 1))
done < <(
    find "$ROOT/Sources" "$ROOT/Tests" \
        -name "*.swift" -type f \
        -not -path "*/.build/*" | sort
)

echo ""
echo "Total files: $TOTAL"
echo "Modified: $MODIFIED"
echo "Skipped: $SKIPPED"

if $DRY_RUN; then
    echo "(dry run — no files modified)"
fi
