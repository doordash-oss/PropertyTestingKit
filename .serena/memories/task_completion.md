# Task Completion Checklist

## After Making Code Changes

### 1. Run Tests
```bash
# Run main test suite
./scripts/build-local-toolchain.sh test --filter "PropertyTestingKitTests"

# If changes affect coverage/SanCov:
./scripts/build-local-toolchain.sh test --filter "SanCovTests"
```

## Code Quality Checks
- Ensure no `nonisolated(unsafe)` usage
- Ensure no force unwrapping (`!`)
- Use dependency injection for testability

## Important Notes
- This is a testing library - testing IS the production use case
- Instrumentation is part of the production environment
- Breaking changes are allowed (project not yet released)
- Project must work from both command line AND Xcode
