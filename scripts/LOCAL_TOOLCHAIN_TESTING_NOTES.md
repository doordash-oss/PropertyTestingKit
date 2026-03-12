# Local Toolchain Testing with @_spi(ForToolsIntegrationOnly) APIs

This guide explains how to build and use a local Swift toolchain that includes your modified swift-testing fork with `@_spi(ForToolsIntegrationOnly)` APIs exposed.

## Prerequisites

- Swift source checkout at `~/Documents/OpenSource/swift`
- Your swift-testing fork at `~/Documents/OpenSource/swift-testing`
- Xcode-beta installed

## Build Variables

```bash
export BUILD="$HOME/Documents/OpenSource/build/Ninja-RelWithDebInfoAssert"
export TOOLCHAIN_BIN="$BUILD/toolchain-macosx-arm64/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export LOCAL_SWIFTC="$BUILD/swift-macosx-arm64/bin/swiftc"
export LOCAL_RUNTIME="$BUILD/swift-macosx-arm64/lib/swift/macosx"
export LOCAL_SWIFTPM="$BUILD/swiftpm-macosx-arm64/arm64-apple-macosx/release"
export SWIFTTESTING_BUILD="$BUILD/swifttesting-macosx-arm64"
```

## Step 1: Build the Swift Toolchain

Build Swift with swift-testing support:

```bash
cd ~/Documents/OpenSource/swift

utils/build-script \
  --skip-build-benchmarks \
  --swift-darwin-supported-archs "$(uname -m)" \
  --release-debuginfo \
  --bootstrapping=bootstrapping \
  --swift-testing \
  --install-swift
```

This builds your modified swift-testing fork (located as a sibling directory) with the `@_spi(ForToolsIntegrationOnly)` APIs.

## Step 2: Build TestingMacros

The initial build may not include TestingMacros. Build it separately:

```bash
utils/build-script \
  --skip-build-benchmarks \
  --swift-darwin-supported-archs "$(uname -m)" \
  --release-debuginfo \
  --bootstrapping=bootstrapping \
  --swift-testing-macros \
  --install-swift-testing-macros \
  --skip-build-swift \
  --skip-build-llvm \
  --skip-build-cmark \
  --skip-build-clang
```

## Step 3: Copy Testing Components to Compiler Directory

The build installs components to different directories. Copy them to where the compiler looks:

```bash
# Copy TestingMacros plugin
mkdir -p "$BUILD/swift-macosx-arm64/lib/swift/host/plugins/testing"
cp "$TOOLCHAIN_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib" \
   "$BUILD/swift-macosx-arm64/lib/swift/host/plugins/testing/"

# Copy Testing module and library
cp "$SWIFTTESTING_BUILD/swift/Testing.swiftmodule" "$LOCAL_RUNTIME/"
cp "$SWIFTTESTING_BUILD/swift/Testing.private.swiftinterface" "$LOCAL_RUNTIME/"
cp "$SWIFTTESTING_BUILD/swift/Testing.package.swiftinterface" "$LOCAL_RUNTIME/"
cp "$SWIFTTESTING_BUILD/lib/libTesting.dylib" "$LOCAL_RUNTIME/"

# Copy _Testing_Foundation (optional, may be needed)
cp -r "$SWIFTTESTING_BUILD/swift/_Testing_Foundation.swiftmodule" "$LOCAL_RUNTIME/" 2>/dev/null
cp "$SWIFTTESTING_BUILD/lib/lib_Testing_Foundation.dylib" "$LOCAL_RUNTIME/" 2>/dev/null
```

## Step 4: Code Sign the Testing Libraries

Locally built libraries aren't code signed. macOS will kill the test process with `SIGKILL (Code Signature Invalid)` if you skip this step.

```bash
# Ad-hoc sign the Testing libraries
codesign -s - "$LOCAL_RUNTIME/libTesting.dylib"
codesign -s - "$LOCAL_RUNTIME/lib_Testing_Foundation.dylib"
codesign -s - "$BUILD/swift-macosx-arm64/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

## Step 5: Symlink System Clang into Toolchain

SwiftPM bootstrap requires clang in the toolchain:

```bash
ln -sf /Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang "$TOOLCHAIN_BIN/clang"
ln -sf /Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++ "$TOOLCHAIN_BIN/clang++"
```

## Step 6: Build SwiftPM with Local Toolchain

```bash
~/Documents/OpenSource/swiftpm/Utilities/bootstrap build --release \
  --swiftc-path "$TOOLCHAIN_BIN/swiftc" \
  --clang-path "$TOOLCHAIN_BIN/clang" \
  --cmake-path /opt/homebrew/bin/cmake \
  --ninja-path /opt/homebrew/bin/ninja \
  --build-dir "$BUILD/swiftpm-macosx-arm64"
```

## Step 7: Configure Package.swift

Remove the swift-testing package dependency since we're using the toolchain's version:

```swift
// In Package.swift dependencies array, REMOVE:
// .package(path: "../../../Documents/OpenSource/swift-testing"),

// Also remove .product(name: "Testing", package: "swift-testing") from targets
```

## Running Tests

Use this command to run tests with the local toolchain:

```bash
cd /path/to/PropertyTestingKit

DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" \
SWIFT_EXEC="$LOCAL_SWIFTC" \
"$LOCAL_SWIFTPM/swift-test" \
  -Xswiftc -I"$SWIFTTESTING_BUILD/swift"
```

**Important:** The `-Xswiftc -I` flag is required to make our Testing module take precedence over Xcode's built-in Testing.framework.

### Convenience Script

Use `scripts/build-local-toolchain.sh`:

```bash
# Run tests
./scripts/build-local-toolchain.sh test

# Run specific tests
./scripts/build-local-toolchain.sh test --filter "MyTests"

# Build only
./scripts/build-local-toolchain.sh build
```

The script validates that all required components are in place and provides helpful error messages if something is missing.

## Troubleshooting

### "TestingMacros plugin not found"

Ensure TestingMacros was built and copied:
```bash
ls "$BUILD/swift-macosx-arm64/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

### "@_spi import of 'Testing' will not include any SPI symbols"

This warning means the compiler is finding Xcode's Testing instead of ours. Ensure you're passing:
```bash
-Xswiftc -I"$SWIFTTESTING_BUILD/swift"
```

### "cannot find 'Configuration' in scope"

The `@_spi(ForToolsIntegrationOnly)` types aren't being found. Check:
1. Testing.private.swiftinterface exists in `$LOCAL_RUNTIME/`
2. The `-Xswiftc -I` flag is being passed

### FunctionSpy or other dependencies fail with TestingMacros errors

Third-party packages that import Testing but don't declare it as a dependency will fail if TestingMacros isn't in the compiler's plugin path. Ensure Step 3 was completed.

### SIGKILL (Code Signature Invalid) / Crash in swiftpm-xctest-helper

If tests crash immediately with a code signing error, the locally built libraries need to be ad-hoc signed. Check `~/Library/Logs/DiagnosticReports/` for crash reports containing:

```
"exception" : {"signal":"SIGKILL (Code Signature Invalid)"}
"termination" : {"namespace":"CODESIGNING","indicator":"Invalid Page"}
```

Fix by running Step 4 (code signing) again after rebuilding swift-testing.

## Why This Setup Works

1. **SwiftPM** is compiled with the local compiler and links against system paths
2. **DYLD_LIBRARY_PATH** overrides runtime library loading to use local versions
3. **SWIFT_EXEC** tells SwiftPM to use the local compiler for building packages
4. **-Xswiftc -I** makes our Testing module take precedence over Xcode's
5. **TestingMacros** in the compiler's plugin path allows all packages to use Testing macros
6. **Testing.private.swiftinterface** contains the `@_spi(ForToolsIntegrationOnly)` API declarations
