## General
- This is a testing tool, so testing is the production case for this project. Instrumentation will be part of the production environment.
- You are free to make breaking changes. This project has not been released.
- `nonisolated(unsafe)` should not be used.
- Force unwrapping should not be used.
- If you believe something about the development environment (OS, tools, compiler, etc.) is blocking you, then double check that assumption. Explain what the issue is and why you believe that to be the case.
- Our eventual goal is to have a functioning library that developers can use to write property-based tests. Anything that prevents us from achieving this goal should be addressed. We are not satisfied when things block us from achieving this goal. The project needs to be operational from both the command line and Xcode.

## Building
- Do not build this project with system swift. Use the build script found in the scripts directory. It builds this project using a patched swift toolchain that fixes issues with parameter packs.
- You can build with `./scripts/build-local-toolchain.sh`

## Debugging
- Use LLDB interactively instead of print debugging when it will speed up the process.
- If you're debugging a crash, you will not be able to do so without identifying the stack trace. Use `lldb` to get the stack trace and then use `bt` to print it.
- Read DEBUGGING.md

## Testing
- When testing, write the full output to a file and then analyze it. Do not use `head` or `tail` during the test run. You will lose information that may be useful for debugging.
- We do not care about logic in our mock dependencies. Most of the time methods should be replaced with spies.
- You can test with `./scripts/build-local-toolchain.sh test` and if you want to run the main test suite, use `./scripts/build-local-toolchain.sh --filter "PropertyTestingKitTests"`
- You can try to find flaky tests by running `./scripts/test-until-failure.sh PropertyTestingKitTests 100` which will run the `PropertyTestingKitTests` target 100 times until it fails.
  - The test-until-failure script places output in `/tmp/test-failure-run{N}.log`. Look for failures there.
- When targeting 100% coverage, target 100% branch coverage. If branches are difficult or impossible to reach, either rework code to remove the need for them, or use dependency injection to achieve the necessary state.
- The test filter uses the method name, not the human readable name.

### Benchmarks
- To benchmark, run `./scripts/run-benchmarks.sh`.
- The filter flag for benchmarks requires that you match the entire name of the benchmark you want to run. Partial matches will not work, and may appear to hang.
- You can analyze calltrees using `./scripts/parse-call-tree.py`.

## Scripts
- If you find yourself performing operations frequently, add a script to the `scripts` directory.
- If one of those scripts stops working, fix it.
