# Code Style and Conventions

## Swift Style
- Swift 6.2+ with strict concurrency
- Actor-based concurrency (e.g., `FuzzEngine` is an actor)
- Parameter packs used extensively (requires patched toolchain)

## Prohibited Patterns
- **NO `nonisolated(unsafe)`** - Never use this
- **NO force unwrapping** - Don't use `!` for unwrapping

## Testing Conventions
- Use spies instead of mocks with logic (via FunctionSpy library)

## Naming
- Protocols: `Mutator`, `MutatorProviding`, `Shrinkable`
- Type erasure: `AnyMutator`, `AnyShrinkable`
- Composed types: `ComposedMutator`, `SingleMutator`
- Plugins: `*Plugin` suffix (e.g., `PlateauDetectorPlugin`)

## File Organization
- `Sources/PropertyTestingKit/` - Main library
  - `Fuzzing/` - Core fuzzing engine and related types
  - `Coverage/` - Coverage tracking and DWARF symbolization
  - `Dependencies/` - Dependency injection clients
- `Sources/SanCovHooks/` - C code for SanitizerCoverage hooks
- `Sources/CLLVMSymbolizer/` - C++ LLVM symbolizer wrapper
- `Tests/` - Test targets organized by purpose

## Documentation
- Use Swift doc comments (`///`) for public APIs
- README contains comprehensive usage examples
