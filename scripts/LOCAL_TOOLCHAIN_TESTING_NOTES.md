# Local Toolchain Testing with @_spi(ForToolsIntegrationOnly) APIs

This guide explains how to build and use a local Swift toolchain that includes your modified swift-testing fork with `@_spi(ForToolsIntegrationOnly)` APIs exposed.

## Prerequisites

- Swift compiler fork checked out somewhere on disk (this guide uses `~/Documents/OpenSourceDev/swift` — adjust the `BUILD_ROOT` env var below if your layout differs).
- Your swift-testing fork checked out as a **sibling** of the swift checkout (e.g. `~/Documents/OpenSourceDev/swift-testing`). Stock `release/6.3` is missing `Issue.onRecordCallback` (used by `Sources/PropertyTestingKit/Fuzzing/IssueDetection.swift`), so PropertyTestingKit will fail to compile against it.
- Xcode-beta installed at `/Applications/Xcode-beta.app`.
- Homebrew tools: `cmake`, `ninja` (`brew install ninja`).

Sibling repos (`swift-testing`, `swiftpm`, `llvm-project`, `cmark`, `swift-syntax`, etc.) are fetched by `update-checkout` — see Step 0.

## Build Variables

```bash
# Adjust BUILD_ROOT to wherever you want intermediate/install output to live.
# Everything else is derived from it. Build artifacts will land alongside the
# swift checkout (build-script puts them at ../build relative to swift/).
export BUILD_ROOT="$HOME/Documents/OpenSourceDev/build/Ninja-RelWithDebInfoAssert"
export SWIFT_SRC="$HOME/Documents/OpenSourceDev/swift"
export SWIFTPM_SRC="$HOME/Documents/OpenSourceDev/swiftpm"

export TOOLCHAIN_BIN="$BUILD_ROOT/toolchain-macosx-arm64/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
export LOCAL_SWIFTC="$BUILD_ROOT/swift-macosx-arm64/bin/swiftc"
export LOCAL_RUNTIME="$BUILD_ROOT/swift-macosx-arm64/lib/swift/macosx"
export LOCAL_SWIFTPM="$BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/release"
export SWIFTTESTING_BUILD="$BUILD_ROOT/swifttesting-macosx-arm64"

# Xcode-beta is used as the host toolchain (host clang/clang++, SDK).
# DEVELOPER_DIR is passed per-command rather than via `sudo xcode-select -s`
# so we don't disturb the rest of the system.
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

## Step 0: Fetch Sibling Repos

From the swift checkout, fetch every sibling repo Swift's build expects:

```bash
cd "$SWIFT_SRC"
utils/update-checkout --scheme release/6.3 --clone --skip-repository swift
```

`--skip-repository swift` leaves your fork branch alone. Pick the scheme that matches your fork's base (e.g. `release/6.3` if you rebased on 6.3).

If `llvm-project` ends up empty or `.git/refs` is missing (clone interrupted mid-flight), wipe and clone it directly:

```bash
rm -rf "$HOME/Documents/OpenSourceDev/llvm-project"
git -c http.postBuffer=524288000 clone --branch swift/release/6.3 --single-branch \
  https://github.com/swiftlang/llvm-project.git \
  "$HOME/Documents/OpenSourceDev/llvm-project"
```

## Step 1: Build the Swift Toolchain

```bash
cd "$SWIFT_SRC"
utils/build-script \
  --skip-build-benchmarks \
  --swift-darwin-supported-archs "$(uname -m)" \
  --release-debuginfo \
  --swift-disable-dead-stripping \
  --bootstrapping=hosttools \
  --swift-testing \
  --install-swift
```

**Important flag notes:**
- `--bootstrapping=hosttools` (not `bootstrapping`). Every official preset uses `hosttools`; using `bootstrapping` triggers a CMake-configure-ordering bug in release/6.3 where `lib/SwiftDemangle` and `lib/Tooling/libSwiftScan` reference `HostCompatibilityLibs` before `stdlib/toolchain` has defined it.
- `--swift-disable-dead-stripping` — matches `docs/HowToGuides/GettingStarted.md`.

## Step 1a: Symlink clang/clang++ into the installed toolchain (must happen during Step 1)

The swift-testing CMake configure inside the main build references `$TOOLCHAIN_BIN/clang++`, but the swift build doesn't install clang there (clang lives in Xcode). Step 1 will fail at the swift-testing configure with:

```
CMake Error at CMakeLists.txt:24 (project):
  The CMAKE_CXX_COMPILER:
    .../toolchain-macosx-arm64/.../usr/bin/clang++
  is not a full path to an existing compiler tool.
```

When you hit that, symlink Xcode-beta's clang into the toolchain bin and re-run Step 1 — it will pick up where it left off (~75s to rebuild just swift-testing):

```bash
XB="/Applications/Xcode-beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
ln -sf "$XB/clang"   "$TOOLCHAIN_BIN/clang"
ln -sf "$XB/clang++" "$TOOLCHAIN_BIN/clang++"
```

## Step 2: Build TestingMacros

The initial build doesn't include TestingMacros. Build them separately:

```bash
cd "$SWIFT_SRC"
utils/build-script \
  --skip-build-benchmarks \
  --swift-darwin-supported-archs "$(uname -m)" \
  --release-debuginfo \
  --swift-disable-dead-stripping \
  --bootstrapping=hosttools \
  --swift-testing-macros \
  --install-swift-testing-macros \
  --skip-build-swift \
  --skip-build-llvm \
  --skip-build-cmark \
  --skip-build-clang
```

## Step 3: Copy Testing Components to Compiler Directory

The build installs to `toolchain-macosx-arm64/...`, but the compiler at `swift-macosx-arm64/` looks for its own copies. Copy them across:

```bash
mkdir -p "$BUILD_ROOT/swift-macosx-arm64/lib/swift/host/plugins/testing"
cp "$BUILD_ROOT/swifttestingmacros-macosx-arm64/libTestingMacros.dylib" \
   "$BUILD_ROOT/swift-macosx-arm64/lib/swift/host/plugins/testing/"

cp "$SWIFTTESTING_BUILD/swift/Testing.swiftmodule"            "$LOCAL_RUNTIME/"
cp "$SWIFTTESTING_BUILD/swift/Testing.private.swiftinterface" "$LOCAL_RUNTIME/"
cp "$SWIFTTESTING_BUILD/swift/Testing.package.swiftinterface" "$LOCAL_RUNTIME/"
cp "$SWIFTTESTING_BUILD/lib/libTesting.dylib"                 "$LOCAL_RUNTIME/"

cp -r "$SWIFTTESTING_BUILD/swift/_Testing_Foundation.swiftmodule" "$LOCAL_RUNTIME/" 2>/dev/null
cp    "$SWIFTTESTING_BUILD/lib/lib_Testing_Foundation.dylib"      "$LOCAL_RUNTIME/" 2>/dev/null
```

## Step 4: Code Sign the Testing Libraries

Locally built libraries aren't code signed. macOS will kill the test process with `SIGKILL (Code Signature Invalid)` if you skip this step.

```bash
codesign -s - "$LOCAL_RUNTIME/libTesting.dylib"
codesign -s - "$LOCAL_RUNTIME/lib_Testing_Foundation.dylib"
codesign -s - "$BUILD_ROOT/swift-macosx-arm64/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

## Step 5: Bootstrap SwiftPM with the Local Toolchain

The locally built compiler (an assertion build) hits two issues when it tries to compile swift-build / swift-bootstrap:

1. **IRGen debug-types round-trip assertion.** Patches that touch type mangling/canonical type uniquing (parameter-pack work in particular) can trigger
   ```
   Assertion failed: (type1->getDecl() != type2->getDecl()),
   function visitNominalType, file TypeDifferenceVisitor.h, line 209.
   ```
   in `EqualUpToDebugDifferences` while emitting debug info for `SWBChannel.swift`. Workaround flag: `-Xfrontend -disable-round-trip-debug-types`.

2. **swift-driver batch-mode single-file confusion** in `-emit-executable -incremental` builds for single-source-file executables (`swift-help`, `swift-bootstrap`). Fails with
   ```
   error: cannotResolveTempPath(main-1.swiftmodule)
   ```
   Workaround flag: `-disable-batch-mode`.

Patch `swiftpm/Utilities/bootstrap` once to inject both flags. Apply these two edits:

```python
# Around line 630 (build_with_cmake): seed swift_flags with the workarounds.
        swift_flags = "-Xfrontend -disable-round-trip-debug-types -disable-batch-mode"
        if args.sysroot:
            swift_flags += " -sdk %s" % args.sysroot
```

```python
# Around line 996 (final swift-bootstrap invocation): inject the same flags
# via -Xswiftc / -Xbuild-tools-swiftc.
    for modifier in ["-Xswiftc", "-Xbuild-tools-swiftc"]:
        build_flags.extend([modifier, "-module-cache-path", modifier, local_module_cache_path])
        build_flags.extend([modifier, "-Xfrontend", modifier, "-disable-round-trip-debug-types"])
        build_flags.extend([modifier, "-disable-batch-mode"])
```

Then bootstrap:

```bash
cd "$SWIFTPM_SRC"
./Utilities/bootstrap build --release \
  --swiftc-path "$TOOLCHAIN_BIN/swiftc" \
  --clang-path  "$TOOLCHAIN_BIN/clang"  \
  --cmake-path /opt/homebrew/bin/cmake \
  --ninja-path /opt/homebrew/bin/ninja \
  --build-dir "$BUILD_ROOT/swiftpm-macosx-arm64"
```

If a previous failed run leaves stale `swift-driver` or `bootstrap` subdirs, wipe them before retrying:

```bash
rm -rf "$BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/swift-driver" \
       "$BUILD_ROOT/swiftpm-macosx-arm64/arm64-apple-macosx/bootstrap"
```

Successful bootstrap produces `$LOCAL_SWIFTPM/swift-build` and `$LOCAL_SWIFTPM/swift-test`.

## Step 6: Configure Package.swift

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
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
DYLD_LIBRARY_PATH="$LOCAL_RUNTIME" \
SWIFT_EXEC="$LOCAL_SWIFTC" \
"$LOCAL_SWIFTPM/swift-test" \
  -Xswiftc -I"$SWIFTTESTING_BUILD/swift"
```

**Important:**
- The `-Xswiftc -I` flag is required to make our Testing module take precedence over Xcode's built-in Testing.framework.
- `DEVELOPER_DIR` is required so clang++ (used to compile `CLLVMSymbolizer`) finds the SDK's C++ stdlib. Without it the build fails with `'type_traits' file not found`.

### Convenience Script

Use `scripts/build-local-toolchain.sh`:

```bash
# Build (override BUILD_ROOT if your install isn't at the default OpenSource path)
BUILD_ROOT="$BUILD_ROOT" ./scripts/build-local-toolchain.sh build

# Run tests
BUILD_ROOT="$BUILD_ROOT" ./scripts/build-local-toolchain.sh test

# Run specific tests
BUILD_ROOT="$BUILD_ROOT" ./scripts/build-local-toolchain.sh test --filter "MyTests"
```

The script validates that all required components are in place and provides helpful error messages if something is missing.

## Troubleshooting

### "TestingMacros plugin not found"

Ensure TestingMacros was built and copied:
```bash
ls "$BUILD_ROOT/swift-macosx-arm64/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```

### "@_spi import of 'Testing' will not include any SPI symbols"

This warning means the compiler is finding Xcode's Testing instead of ours. Ensure you're passing:
```bash
-Xswiftc -I"$SWIFTTESTING_BUILD/swift"
```

### "type 'Issue' has no member 'onRecordCallback'"

PropertyTestingKit uses `@_spi(ForToolsIntegrationOnly)` APIs that only exist in your modified swift-testing fork — not in stock `release/6.3`. Make sure your fork is checked out at `~/Documents/OpenSourceDev/swift-testing` (sibling of the swift checkout) before running Step 1. If you've already built against stock, re-run Step 1 after swapping the sibling — Step 1 will rebuild only swift-testing.

### "'type_traits' file not found" when compiling CLLVMSymbolizer

clang++ (Xcode-beta's) can't find the C++ stdlib without an `-isysroot`. Pass `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` to every build/test command (or `export` it for the shell). Don't `sudo xcode-select -s` system-wide.

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

### CMake error: "could not find TARGET HostCompatibilityLibs"

You used `--bootstrapping=bootstrapping`. Use `--bootstrapping=hosttools` instead (Step 1).

### Compiler crash building swift-build: "Assertion failed: (type1->getDecl() != type2->getDecl())"

You haven't applied the `-disable-round-trip-debug-types` workaround to `swiftpm/Utilities/bootstrap`. See Step 5.

### swift-driver error: "cannotResolveTempPath(main-1.swiftmodule)"

You haven't applied the `-disable-batch-mode` workaround to `swiftpm/Utilities/bootstrap`, or you have a stale build dir. See Step 5 (apply patch + wipe `swift-driver` and `bootstrap` subdirs).

## Using the Toolchain in Xcode

The CLI build points `swiftc` at `swift-macosx-arm64/bin/swiftc` directly. To get
the same patched compiler (plus the fork's `Testing` SPI, `TestingMacros`, and the
signed runtime) inside Xcode, register that build directory as a selectable Xcode
toolchain:

```bash
# Defaults BUILD_ROOT to the OpenSourceDev path; override if yours differs.
./scripts/install-xcode-toolchain.sh
```

This creates `~/Library/Developer/Toolchains/propertytestingkit-local.xctoolchain`
with an `Info.plist` (bundle id `dev.alex.propertytestingkit.local`) and a
`usr` symlink to `$BUILD_ROOT/swift-macosx-arm64`. Because it's a symlink, a fresh
`utils/build-script` rebuild is picked up automatically — no reinstall needed (but
re-run Step 4 code-signing if the Testing dylibs were rebuilt).

Select it:
- **Xcode UI:** `Xcode ▸ Toolchains ▸ Local Swift (PropertyTestingKit)`. Relaunch
  Xcode once after installing so the toolchain appears in the menu.
- **Command line / CI:** `export TOOLCHAINS=dev.alex.propertytestingkit.local`
  before `xcodebuild`, or pass `-toolchain dev.alex.propertytestingkit.local`.

Verify resolution: `xcrun --toolchain dev.alex.propertytestingkit.local swiftc --version`
should report `+assertions`.

Remove it: `./scripts/install-xcode-toolchain.sh --uninstall`.

**Notes / caveats:**
- Open the project in **Xcode-beta** (`/Applications/Xcode-beta.app`). The toolchain
  ships no `clang` and no SDK — Xcode supplies those — so use the same Xcode the
  toolchain was built against to keep the clang/SDK consistent with CLI builds.
- `import Testing` resolves to the toolchain's own `lib/swift/macosx/Testing.swiftmodule`
  (the fork, with `@_spi(ForToolsIntegrationOnly)`), so the `-I$SWIFTTESTING_BUILD/swift`
  flag the CLI uses isn't needed in Xcode. If you ever see the "will not include any SPI
  symbols" warning in Xcode, Step 3 wasn't completed for the `swift-macosx-arm64` tree.
- The package's `-sanitize-coverage`/`-sanitize=undefined` unsafe flags apply in Xcode
  builds just as on the CLI.

## Why This Setup Works

1. **SwiftPM** is compiled with the local compiler and links against system paths
2. **DYLD_LIBRARY_PATH** overrides runtime library loading to use local versions
3. **SWIFT_EXEC** tells SwiftPM to use the local compiler for building packages
4. **DEVELOPER_DIR** tells clang/clang++ which SDK to use without disturbing system `xcode-select`
5. **-Xswiftc -I** makes our Testing module take precedence over Xcode's
6. **TestingMacros** in the compiler's plugin path allows all packages to use Testing macros
7. **Testing.private.swiftinterface** contains the `@_spi(ForToolsIntegrationOnly)` API declarations (from your swift-testing fork)
