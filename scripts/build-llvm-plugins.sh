#!/bin/bash
# Build the out-of-tree LLVM pass plugins that provide PTK's coverage
# instrumentation at COMPILE time (replacing the former runtime filters in
# SanCovHooks.c):
#
#   EmitCmpTrace.dylib         — emits __sanitizer_cov_trace_cmp* ourselves for
#                                the comparisons we want, dropping trap-guard
#                                cmps (bounds/overflow/precondition). Build the
#                                SUT with `-sanitize-coverage=edge,pc-table`
#                                (NO trace-cmp) and load this plugin.
#   TagCompilerGenerated.dylib — tags compiler-generated functions
#                                NoSanitizeCoverage so SanCov emits no edge/cmp
#                                for them (and async resume/yield edges stay
#                                filtered for pathTrie determinism).
#
# Instrumented targets load them via `-Xswiftc -load-pass-plugin=<dylib>`
# (wired in Package.swift). The plugins link against the patched toolchain's
# LLVM (same one PTK builds with), so they're rebuilt here rather than checked
# in. Output: .build/llvm-plugins/*.dylib.
set -e

BUILD_ROOT="${BUILD_ROOT:-$HOME/Documents/OpenSourceDev/build/Ninja-RelWithDebInfoAssert}"
LLVM_CONFIG="$BUILD_ROOT/llvm-macosx-arm64/bin/llvm-config"

cd "$(dirname "$0")/.."
SRC_DIR="LLVMPasses"
OUT_DIR=".build/llvm-plugins"

if [ ! -x "$LLVM_CONFIG" ]; then
    echo "error: llvm-config not found at $LLVM_CONFIG" >&2
    echo "       set BUILD_ROOT to your patched-toolchain build dir." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CXXFLAGS="$("$LLVM_CONFIG" --cxxflags)"

build_one() {
    local name="$1"
    local src="$SRC_DIR/$name.cpp"
    local out="$OUT_DIR/$name.dylib"
    # Rebuild only when the source is newer than the dylib (plugins are tiny).
    if [ -f "$out" ] && [ "$out" -nt "$src" ]; then
        echo "up to date: $out"
        return
    fi
    echo "building:   $out"
    # shellcheck disable=SC2086
    xcrun clang++ $CXXFLAGS -isysroot "$SDK" -dynamiclib -undefined dynamic_lookup \
        "$src" -o "$out"
}

build_one EmitCmpTrace
build_one TagCompilerGenerated
echo "llvm plugins ready in $OUT_DIR"
