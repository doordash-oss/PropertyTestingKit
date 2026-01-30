# Swift Compiler Fork

We are working on a **fork of the Swift compiler** in parallel with this project.

## Key Points

1. **Do NOT revert code changes** when encountering compiler or runtime crashes
2. Instead, **investigate and report** the crash details:
   - Compiler assertion failures (file, line, message)
   - Runtime crashes (backtrace, error message)
   - Minimal reproduction context

## Current Issues Being Fixed

### Parameter Pack Tuple Concatenation (Jan 2026)
- **Symptom**: Runtime crash with "freed pointer was not the last allocation"
- **Location**: `swift::StackAllocator::dealloc()` in task allocator
- **Trigger**: Async closure capturing `SyncPluginProcessor` with concatenated parameter pack tuple `(repeat each D, repeat each P)`
- **Code**: `concatPlugins()` helper returning `(repeat each D, repeat each P)`

### Previous Fixes
- `GenericSignature.cpp:832` - "only single pack expansion tuples are currently supported" - FIXED
- `RValue.cpp:707` - "can't extract elements from tuples containing pack expansions" - FIXED
