#!/bin/bash
# inspect-corpus.sh — Print human-readable contents of a corpus file.
#
# The corpus format is a JSON array of arrays: [[input1], [input2], ...]
# Each inner array contains the input values for one test entry.
#
# Usage: ./scripts/inspect-corpus.sh path/to/corpus.json
#        ./scripts/inspect-corpus.sh path/to/Corpus/testName/
#
# Requires: jq (brew install jq)

set -euo pipefail

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    exit 1
fi

CORPUS_PATH="${1:?Usage: $0 <corpus.json or corpus directory>}"

# If given a directory, look for corpus.json inside it
if [ -d "$CORPUS_PATH" ]; then
    CORPUS_PATH="$CORPUS_PATH/corpus.json"
fi

if [ ! -f "$CORPUS_PATH" ]; then
    echo "Error: $CORPUS_PATH not found" >&2
    exit 1
fi

ENTRY_COUNT=$(jq 'length' "$CORPUS_PATH")
echo "Corpus: $ENTRY_COUNT entries"
echo "File: $CORPUS_PATH"
echo ""

jq -r '
to_entries[] |
"Entry \(.key + 1): \(.value | tojson)\n"
' "$CORPUS_PATH"
