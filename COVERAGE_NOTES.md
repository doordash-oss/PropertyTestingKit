# Per-Test Coverage Implementation Notes

## Current Status

✅ **All 27 tests pass** with `swift test --enable-code-coverage --no-parallel`

✅ **Difference-based measurement** - does not interfere with Xcode or other coverage tools

⚠️ **Parallel execution** - tests using coverage counters should be in `.serialized` suites

---

## Key Findings

### 0. Difference-Based Measurement (Latest)

**Problem:** Resetting LLVM counters via `__llvm_profile_reset_counters()` interferes with Xcode and other coverage tooling.

**Solution:** `measureSourceCoverage` now uses difference-based measurement:
1. Snapshot counters before running code
2. Run the code under test
3. Snapshot counters after
4. Compute delta (after - before) for each counter
5. Resolve coverage from the delta array

This approach:
- Does NOT reset global counters
- Works with Xcode coverage reports
- Isolates measurements to just the code that ran during the block

**Code:**
```swift
// In measureSourceCoverage:
guard let before = CoverageCounters.snapshot() else { ... }
let result = try body()
guard let after = CoverageCounters.snapshot() else { ... }

let deltaCounters = zip(after.counters, before.counters).map { after, before in
    after >= before ? after - before : 0
}
let coverage = reader.resolveCoverage(counters: deltaCounters)
```

**C++ Changes:** `buildFunctionCounterOffsetMap()` now returns offsets into the counter array instead of pointers to live memory. `resolveCoverage()` reads from the provided array at these offsets.

---

### 1. ProfileData CounterPtr Offset (Fixed)

**Problem:** Apple's Swift (raw profile format version 10) calculates CounterPtr differently than older LLVM versions.

**Root Cause:** The `CounterPtr` field is a relative offset from the **start of the ProfileData struct**, not from `&CounterPtr`.

**Fix:** In `LLVMCoverageInterop.cpp`:
```cpp
// Correct calculation for Apple's Swift (profile format v10):
const uint64_t* counters = reinterpret_cast<const uint64_t*>(
    reinterpret_cast<const char*>(data) + data->CounterPtr
);
```

**Verification:** Tests pass individually after this fix.

---

### 2. Test Isolation Issue (RESOLVED)

**Symptom:** Tests pass individually but fail when run together.

**Root Cause:** Swift Testing runs different suites in parallel by default. The `.serialized` trait only serializes tests *within* a suite, not between suites. LLVM coverage counters are global mutable state.

**Solution:** `CoverageLock.shared` - a global lock that all coverage-dependent code acquires:

- `FuzzEngine.run()` acquires the lock for the entire fuzz run
- `measureSourceCoverage()` acquires the lock during measurement
- `measureCoverage()` acquires the lock during measurement

This ensures only one test can measure coverage at a time, even when tests run in parallel.

```swift
// The lock is acquired automatically by these APIs:
try fuzz { input in ... }  // Lock held for entire fuzz run
try measureSourceCoverage { ... }  // Lock held during measurement
measureCoverage { ... }  // Lock held during measurement

// Manual usage for custom scenarios:
CoverageLock.shared.withLock {
    let before = CoverageCounters.snapshot()
    // ... run code ...
    let after = CoverageCounters.snapshot()
}
```

**Tests affected by counter state:**
- Any test using `measureSourceCoverage`
- Any test using `measureCoverage`
- Any test using `fuzz()`
- Any test using `CoverageLock.shared.withLock`

---

## ProfileData Struct Layout (LLVM 18 / Apple Swift 6.2)

```cpp
struct ProfileData {
    uint64_t NameRef;           // 0: MD5 hash of function name
    uint64_t FuncHash;          // 8: Structural hash
    int64_t CounterPtr;         // 16: Relative offset to counters (from struct start)
    int64_t BitmapPtr;          // 24: Relative offset to bitmap
    void *FunctionPointer;      // 32: Function address
    void *Values;               // 40: Value profiling data
    uint32_t NumCounters;       // 48: Number of counters
    uint16_t NumValueSites[2];  // 52: Value sites per kind
    uint32_t NumBitmapBytes;    // 56: Bitmap size
    // Total: 60 bytes, padded to 64
};
```

---

## Debug Commands Reference

### Using lldb for coverage debugging:
```bash
# Run test under lldb
lldb -- swift test --enable-code-coverage --filter "TestName"

# Useful breakpoints
b ptk::InMemoryCoverageReader::Impl::buildFunctionCounterMap
b ptk::InMemoryCoverageReader::Impl::resolveCoverage

# Examine ProfileData
p *data
p data->CounterPtr
x/8gx data  # raw memory view

# Examine counters
x/10gx counterRangeBegin
p counterRangeBegin[350]
```
