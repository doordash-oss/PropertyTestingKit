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

## Console Log Debugging

If you encounter attach failures, check the system logs:

```bash
/usr/bin/log show --last 5m | grep -i "macOSTaskPolicy"
```

This will show which process debugserver is trying to attach to and why it's being denied.
