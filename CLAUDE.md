## General
- `nonisolated(unsafe)` should not be used.
- Force unwrapping should not be used.

## Building
- Do not build this project with system swift. Use the build script found in the scripts directory. It builds this project using a patched swift toolchain that fixes issues with parameter packs.
- You can build with `./scripts/build-local-toolchain.sh`

## Debugging
- Use LLDB interactively instead of print debugging when it will speed up the process.

## Testing
- We do not care about logic in our mock dependencies. Most of the time methods should be replaced with spies.
- You can test with `./scripts/build-local-toolchain.sh test` and if you want to run the main test suite, use `./scripts/build-local-toolchain.sh --filter "PropertyTestingKitTests"`
- You can try to find flaky tests by running `./scripts/test-until-failure.sh PropertyTestingKitTests 100` which will run the `PropertyTestingKitTests` target 100 times until it fails.
  - The test-until-failure script places output in `/tmp/test-failure-run{N}.log`. Look for failures there.
- When targeting 100% coverage, target 100% branch coverage. If branches are difficult or impossible to reach, either rework code to remove the need for them, or use dependency injection to achieve the necessary state.

### Benchmarks
- The filter flag for benchmarks requires that you match the entire name of the benchmark you want to run. Partial matches will not work, and may appear to hang.

## Scripts
- If you find yourself performing operations frequently, add a script to the scripts directory.
- If one of those scripts stops working, fix it.
