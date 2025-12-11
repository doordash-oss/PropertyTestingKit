#!/bin/bash
# Build/test PropertyTestingKit using the locally compiled Swift toolchain
#
# Usage:
#   ./Scripts/build-local-toolchain.sh              # build
#   ./Scripts/build-local-toolchain.sh test         # run tests
#   ./Scripts/build-local-toolchain.sh -c release   # release build

set -e

TOOLCHAIN_ID="org.swift.local"

# Required workaround for parameter pack IRGen bug
# See: https://github.com/apple/swift/issues/... (parameter pack debug info crash)
DEBUG_FLAG="-Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types"

# First argument determines the command (build or test)
CMD="${1:-build}"

if [[ "$CMD" == "test" ]]; then
    shift
    TOOLCHAINS="$TOOLCHAIN_ID" swift test --enable-code-coverage $DEBUG_FLAG "$@"
else
    TOOLCHAINS="$TOOLCHAIN_ID" swift build $DEBUG_FLAG "$@"
fi
