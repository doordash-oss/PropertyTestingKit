# Per-Test Coverage Implementation Notes

## Current Status

✅ **All 31 tests pass** with `swift test --enable-code-coverage --no-parallel`

⚠️ **Parallel execution fails** due to shared counter state between test suites

---

## Key Findings

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
