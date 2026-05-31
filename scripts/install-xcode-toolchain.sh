#!/bin/bash
# Register the locally built Swift toolchain as a selectable Xcode toolchain.
#
# Creates ~/Library/Developer/Toolchains/propertytestingkit-local.xctoolchain
# whose `usr` symlinks to the swift build product directory. That directory is
# the one the CLI build uses (scripts/build-local-toolchain.sh): it holds the
# patched compiler, the swift-testing fork's Testing module (with the
# @_spi(ForToolsIntegrationOnly) APIs), TestingMacros, and the ad-hoc-signed
# runtime dylibs. See scripts/LOCAL_TOOLCHAIN_TESTING_NOTES.md.
#
# Usage:
#   ./scripts/install-xcode-toolchain.sh            # install / refresh
#   BUILD_ROOT=/path ./scripts/install-xcode-toolchain.sh
#   ./scripts/install-xcode-toolchain.sh --uninstall
#
# After installing, pick it in Xcode via:  Xcode ▸ Toolchains ▸ Local Swift (PropertyTestingKit)
# or on the command line:  export TOOLCHAINS=dev.alex.propertytestingkit.local

set -euo pipefail

BUILD_ROOT="${BUILD_ROOT:-$HOME/Documents/OpenSourceDev/build/Ninja-RelWithDebInfoAssert}"
SWIFT_BUILD="$BUILD_ROOT/swift-macosx-arm64"

BUNDLE_ID="dev.alex.propertytestingkit.local"
DISPLAY_NAME="Local Swift (PropertyTestingKit)"
TOOLCHAIN_DIR="$HOME/Library/Developer/Toolchains/propertytestingkit-local.xctoolchain"

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "$TOOLCHAIN_DIR"
    echo "Removed $TOOLCHAIN_DIR"
    exit 0
fi

# Validate the build product directory looks like a usable toolchain.
if [[ ! -x "$SWIFT_BUILD/bin/swiftc" ]]; then
    echo "Error: $SWIFT_BUILD/bin/swiftc not found." >&2
    echo "Build the local toolchain first (see scripts/LOCAL_TOOLCHAIN_TESTING_NOTES.md)," >&2
    echo "or set BUILD_ROOT to your install location." >&2
    exit 1
fi
if [[ ! -f "$SWIFT_BUILD/lib/swift/macosx/libswiftCore.dylib" ]]; then
    echo "Error: swift runtime not found under $SWIFT_BUILD/lib/swift/macosx." >&2
    exit 1
fi
if [[ ! -f "$SWIFT_BUILD/lib/swift/macosx/Testing.swiftmodule" ]]; then
    echo "Warning: Testing.swiftmodule not found in the toolchain runtime dir." >&2
    echo "         'import Testing' may resolve to Xcode's copy without the SPI." >&2
    echo "         Run Step 3 of LOCAL_TOOLCHAIN_TESTING_NOTES.md to copy it in." >&2
fi

mkdir -p "$TOOLCHAIN_DIR"

# `usr` -> the build product dir. -n so re-running replaces the symlink rather
# than nesting inside an existing one.
ln -sfn "$SWIFT_BUILD" "$TOOLCHAIN_DIR/usr"

cat > "$TOOLCHAIN_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>DisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>Aliases</key>
    <array>
        <string>propertytestingkit-local</string>
    </array>
    <key>CompatibilityVersion</key>
    <integer>2</integer>
    <key>CompatibilityVersionDisplayString</key>
    <string>Xcode 8.0</string>
    <key>ShortDisplayVersion</key>
    <string>1.0</string>
    <key>Version</key>
    <string>1.0.0</string>
    <key>ReportProblemURL</key>
    <string>https://swift.org/</string>
</dict>
</plist>
PLIST

echo "Installed Xcode toolchain:"
echo "  bundle:     $TOOLCHAIN_DIR"
echo "  usr ->      $SWIFT_BUILD"
echo "  identifier: $BUNDLE_ID"
echo
echo "Select it in Xcode:   Xcode ▸ Toolchains ▸ $DISPLAY_NAME"
echo "Or per shell/CI:      export TOOLCHAINS=$BUNDLE_ID"
echo "Verify:               xcrun --toolchain $BUNDLE_ID swiftc --version"
