# Task Completion Checklist

## After Making Code Changes

### 1. Build
```bash
./scripts/build-local-toolchain.sh
```

### 2. Run Tests
```bash
# Run main test suite
./scripts/build-local-toolchain.sh test --filter "PropertyTestingKitTests"

# If changes affect coverage/SanCov:
./scripts/build-local-toolchain.sh test --filter "SanCovTests"
```

### 3. Check for Flaky Tests (if relevant)
```bash
./scripts/test-until-failure.sh PropertyTestingKitTests 10
```

### 4. Run Benchmarks (if performance-sensitive changes)
```bash
./scripts/run-benchmarks.sh
```

## Code Quality Checks
- Ensure no `nonisolated(unsafe)` usage
- Ensure no force unwrapping (`!`)
- Verify branch coverage for new code
- Use dependency injection for testability

## Important Notes
- This is a testing library - testing IS the production use case
- Instrumentation is part of the production environment
- Breaking changes are allowed (project not yet released)
- Project must work from both command line AND Xcode
