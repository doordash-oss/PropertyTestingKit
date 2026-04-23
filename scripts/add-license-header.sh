#!/bin/bash
#
# Adds Apache 2.0 license header to all source files (.swift, .c, .h)
# in Sources/ and Tests/. Skips files that already have the header and
# third-party code (ck/ directory).
#
# Usage: ./scripts/add-license-header.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# License text — uses // comments (works for Swift, C, and header files)
read -r -d '' LICENSE_HEADER << 'EOF' || true
// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
EOF

ADDED=0
SKIPPED=0
TOTAL=0

# Find all source files, excluding .build/, ck/ (third-party), and Benchmarks boilerplate
while IFS= read -r file; do
    TOTAL=$((TOTAL + 1))

    # Skip if already has the license
    if head -3 "$file" | grep -q "Copyright 2026 DoorDash"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if $DRY_RUN; then
        echo "[dry-run] Would add header to: ${file#$ROOT/}"
    else
        # Create temp file with license header + blank line + original content
        {
            echo "$LICENSE_HEADER"
            echo ""
            cat "$file"
        } > "${file}.tmp"
        mv "${file}.tmp" "$file"
        echo "Added header to: ${file#$ROOT/}"
    fi
    ADDED=$((ADDED + 1))
done < <(
    find "$ROOT/Sources" "$ROOT/Tests" \
        -not -path "*/.build/*" \
        -not -path "*/ck/*" \
        -not -name "ck_ht.c" \
        -not -path "*/__BenchmarkBoilerplate.swift" \
        \( -name "*.swift" -o -name "*.c" -o -name "*.h" \) \
        -type f | sort
)

echo ""
echo "Total files: $TOTAL"
echo "Added: $ADDED"
echo "Already had header: $SKIPPED"

if $DRY_RUN; then
    echo "(dry run — no files modified)"
fi
