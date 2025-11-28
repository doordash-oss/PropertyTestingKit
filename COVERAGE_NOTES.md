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

**Root Cause:** Swift Testing runs different suites in parallel by default. The `.serialized` trait only serializes tests *within* a suite, not between suites.

**Solution:** Consolidate all counter-dependent tests into a single serialized suite (`AllCoverageTests`), or use `--no-parallel` flag when running tests.

```bash
# Run all tests serially (guaranteed to pass):
swift test --enable-code-coverage --no-parallel

# Or run counter-dependent tests separately:
swift test --enable-code-coverage --filter "Coverage Counter Tests"
```

**Tests affected by counter state:**
- Any test using `measureSourceCoverage`
- Any test using `CoverageCounters.reset()`
- Any test using `withCoverage` (writes profraw files)
- Any test using `LLVMCoverageReader` (reads profraw files)

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
