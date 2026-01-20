# Suggested Commands

## IMPORTANT: Do NOT use system Swift
This project requires a patched Swift toolchain. Always use the build scripts.

## Building
```bash
# Build the project (uses local patched toolchain)
./scripts/build-local-toolchain.sh

# Build and run tests
./scripts/build-local-toolchain.sh test
```

## Testing
```bash
# Run main test suite
./scripts/build-local-toolchain.sh test --filter "PropertyTestingKitTests"

# Run specific test target
./scripts/build-local-toolchain.sh test --filter "SanCovTests"

## Benchmarking
```bash
# Run benchmarks
./scripts/run-benchmarks.sh

# Profile a benchmark
./scripts/profile-benchmark.sh

# Analyze call tree output
./scripts/parse-call-tree.py
```

## Debugging
- Use LLDB interactively, not print debugging
- For crashes: use `lldb` then `bt` to get stack trace
- When testing, write full output to file (don't use head/tail during test runs)

## Test Targets
- `PropertyTestingKitTests` - Main test suite
- `SanCovTests` - SanitizerCoverage tests
- `TSanTests` - Thread sanitizer tests
- `StressTests` - Stress/load tests
- `ScratchPad` - Experimental tests
