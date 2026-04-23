# Debugging with LLDB MCP

## Overview

This project can be debugged interactively using the LLDB MCP (Model Context Protocol) server.

## Debugging xctest Bundles

xctest bundles are Mach-O bundles, not standalone executables. They cannot be launched directly by LLDB. Instead, use the `xctest` binary as the executable and pass the test bundle as an argument.

### Steps

1. Start an LLDB session
2. Load the `xctest` executable (not the test bundle):
   ```
   file /Applications/Xcode-beta.app/Contents/Developer/usr/bin/xctest
   ```

3. Set the test bundle path as a run argument:
   ```
   settings set -- target.run-args "/path/to/PropertyTestingKit/.build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest"
   ```

4. Launch with shell expansion disabled:
   ```
   process launch -X false -s
   ```

   The `-X false` flag is critical - it disables shell expansion which avoids macOS security issues where debugserver cannot attach to the hardened `/bin/sh`.

   The `-s` flag stops at the entry point, useful for setting breakpoints before tests run.

5. Set breakpoints and continue:
   ```
   breakpoint set --name YourFunctionName
   continue
   ```

### Why This Works

On macOS, when LLDB launches a process with default settings, it uses a shell (`/bin/sh`) to set up I/O and expand arguments. However, `/bin/sh` is a hardened system binary without the `get-task-allow` entitlement, so debugserver cannot attach to it.

The error looks like:
```
macOSTaskPolicy: (com.apple.debugserver) may not get the task control port of (sh):
(sh) is hardened, (sh) doesn't have get-task-allow
```

Using `-X false` tells LLDB to launch the process directly without shell involvement.

### Finding xctest Location

```bash
xcrun --find xctest
```

This typically returns something like:
```
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest
```

## Debugging a Specific Swift Testing Test

The `xctest` binary doesn't support `--filter` for Swift Testing. To debug a specific test,
use `swiftpm-testing-helper` directly with the correct library paths.

### Steps

1. Build test targets first:
   ```
   ./scripts/build-local-toolchain.sh build --build-tests
   ```

2. Start an LLDB session and load `swiftpm-testing-helper`:
   ```
   file $BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/release/swiftpm-testing-helper
   ```

3. Set run arguments with `--filter`:
   ```
   settings set -- target.run-args "--test-bundle-path" "/path/to/.build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest/Contents/MacOS/PropertyTestingKitPackageTests" "--filter" "yourTestMethodName" "/path/to/.build/arm64-apple-macosx/debug/PropertyTestingKitPackageTests.xctest/Contents/MacOS/PropertyTestingKitPackageTests" "--testing-library" "swift-testing"
   ```

4. Set environment variables for library loading:
   ```
   env DYLD_LIBRARY_PATH=$BUILD_ROOT/swift-macosx-arm64/lib/swift/macosx:/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
   env DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks:/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks
   ```

5. Set breakpoints and launch:
   ```
   breakpoint set --file MyFile.swift --line 42
   process launch -X false
   ```

### Why swiftpm-testing-helper?

`swift-test` passes `--filter` to `swiftpm-testing-helper`, which loads the test bundle via
`dlopen` and passes the filter to Swift Testing's `CommandLine.arguments` parser. The `xctest`
binary parses arguments itself and rejects unknown flags like `--filter`.

### Required Library Paths

`swiftpm-testing-helper` needs:
- **DYLD_LIBRARY_PATH**: Local Swift runtime + `libXCTestSwiftSupport.dylib`
- **DYLD_FRAMEWORK_PATH**: `XCTest.framework` + `XCTestCore.framework` (private)

Without these, `dlopen` fails with "Library not loaded" errors.

### Alternative: Attach to Running Process

For quick debugging without setting up library paths:
```bash
# Terminal 1: Launch test
./scripts/build-local-toolchain.sh test --filter "testName" --skip-build &
# Terminal 2: Find PID and attach
pgrep -f "swiftpm-testing-helper"
# In LLDB: process attach -p <PID>
```

This works but has a race condition — the test may complete before you attach.

## Console Log Debugging

If you encounter attach failures, check the system logs:

```bash
/usr/bin/log show --last 5m | grep -i "macOSTaskPolicy"
```

This will show which process debugserver is trying to attach to and why it's being denied.
