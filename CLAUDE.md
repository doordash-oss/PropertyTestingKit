## General
- This is a testing tool, so testing is the production case for this project. Instrumentation will be part of the production environment.
- You are free to make breaking changes. This project has not been released.
- `nonisolated(unsafe)` should not be used.
- Force unwrapping should not be used.
- If you believe something about the development environment (OS, tools, compiler, etc.) is blocking you, then double check that assumption. Explain what the issue is and why you believe that to be the case.
- The project needs to be operational from both the command line and Xcode.

## Building
- Do not build this project with system swift. Use the build script found in the scripts directory. It builds this project using a patched swift toolchain that fixes issues with parameter packs.
- You can build with `./scripts/build-local-toolchain.sh`

## Debugging
- If you're debugging a crash, you will not be able to do so without identifying the stack trace. Use `lldb` to get the stack trace and then use `bt` to print it.
- Read DEBUGGING.md

## Testing
- When testing, write the full output to a file and then analyze it. Do not use `head` or `tail` during the test run. You will lose information that may be useful for debugging.
- We do not care about logic in our mock dependencies. Most of the time methods should be replaced with spies.
- You can test with `./scripts/build-local-toolchain.sh test` and if you want to run the main test suite, use `./scripts/build-local-toolchain.sh --filter "PropertyTestingKitTests"`
- You can try to find flaky tests by running `./scripts/test-until-failure.sh PropertyTestingKitTests 100` which will run the `PropertyTestingKitTests` target 100 times until it fails.
  - The test-until-failure script places output in `/tmp/test-failure-run{N}.log`. Look for failures there.
- The test filter uses the method name, not the human readable name.

### TDD Workflow
- Always write failing tests BEFORE implementation
- Use AAA pattern: Arrange-Act-Assert
- One assertion per test when possible
- Test names describe behavior: "should_return_empty_when_no_items"

### Test-First Rules
- When I ask for a feature, write tests first
- Tests should FAIL initially (no implementation exists)
- Only after tests are written, implement minimal code to pass

### Benchmarks
- To benchmark, run `./scripts/run-benchmarks.sh`.
- The filter flag for benchmarks requires that you match the entire name of the benchmark you want to run. Partial matches will not work, and may appear to hang.
- You can analyze calltrees using `./scripts/parse-call-tree.py`.
