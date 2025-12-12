#!/bin/bash
# Build/test PropertyTestingKit using the locally compiled Swift toolchain
#
# Usage:
#   ./Scripts/build-local-toolchain.sh              # build
#   ./Scripts/build-local-toolchain.sh test         # run tests
#   ./Scripts/build-local-toolchain.sh -c release   # release build

set -e

# The local toolchain doesn't include SwiftPM, so we use the snapshot's SwiftPM
# with --toolchain flag to use the local toolchain's compiler
SNAPSHOT_SWIFT="/Users/alex.reilly/Library/Developer/Toolchains/swift-DEVELOPMENT-SNAPSHOT-2025-12-01-a.xctoolchain/usr/bin/swift"
LOCAL_TOOLCHAIN="/Users/alex.reilly/Library/Developer/Toolchains/swift-local-complete.xctoolchain"

# Required workaround for parameter pack IRGen bug
# See: https://github.com/apple/swift/issues/... (parameter pack debug info crash)
DEBUG_FLAG="-Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types"

# First argument determines the command (build or test)
CMD="${1:-build}"

if [[ "$CMD" == "test" ]]; then
    shift
    "$SNAPSHOT_SWIFT" test --toolchain "$LOCAL_TOOLCHAIN" --enable-code-coverage $DEBUG_FLAG "$@"
else
    "$SNAPSHOT_SWIFT" build --toolchain "$LOCAL_TOOLCHAIN" $DEBUG_FLAG "$@"
fi
