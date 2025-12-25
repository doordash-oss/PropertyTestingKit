# Performance Optimization Plan

Based on benchmark analysis from December 2024.

## Summary

| Priority | Issue | Before | After | Status |
|----------|-------|--------|-------|--------|
| 1 | Gap detection overhead | +37ms constant | +9ms constant | ✅ 4x improvement |
| 2 | snapshotCoveredOnly() | 3.85μs/call | 3.57μs/call | ✅ 8% (SIMD+single-pass) |
| 3 | Batch size tuning | 6.3ms (default) | 3.9ms (auto) | ✅ 40% improvement |
| 4 | String.fuzz generation | 53μs | 16ns | ✅ 3375x improvement |
| 5 | CoverageSignature full scan | 27μs | 5.9μs (sparse) | ✅ Already optimized |

## 1. Gap Detection (~37ms → ~9ms) ✅ COMPLETED

**Problem**: Gap detection adds ~37ms constant overhead regardless of iteration count.

| Benchmark | Without Gap Detection | With Gap Detection (Before) | With Gap Detection (After) |
|-----------|----------------------|----------------------------|---------------------------|
| 100 iterations | 1.2ms | 38ms (31x slower) | 10ms (8x slower) |
| 1000 iterations | 4ms | 41ms (10x slower) | 12ms (4x slower) |

**Result**: 4x improvement (37ms → 9ms constant overhead)

**Optimizations Applied**:
- [x] Reduced PC padding from 64KB to 4KB for tighter filtering
- [x] Skip DWARF lookup during detection (defer to lazy access if needed)
- [x] Store PC in UncoveredRegion for future lazy line lookup

**Remaining Overhead** (~9ms): dladdr calls for ~22K edges. Further optimization would require:
- Cache dladdr results by function name
- Use binary search with sorted PC index instead of linear scan
- Make entire gap detection lazy (only run when results accessed)

## 2. SanCovCounters.snapshotCoveredOnly() (3.85μs → 3.57μs) ✅ PARTIAL

**Problem**: The sparse snapshot is counterintuitively slower than the full snapshot.

| Operation | Time (p50) Before | Time (p50) After |
|-----------|-------------------|------------------|
| snapshot() - full | 208ns | 208ns |
| snapshotCoveredOnly() | 3.85μs | 3.57μs |

**Result**: 8% improvement (3.85μs → 3.57μs). Still 17x slower than full snapshot.

**Optimizations Applied**:
- [x] SIMD (NEON) instructions to scan counter array (16 bytes at a time)
- [x] Single-pass algorithm (avoid two full scans)
- [x] Quick-skip for all-zero 16-byte chunks

**Remaining Bottleneck**: Swift Dictionary building (~2.5μs of the 3.57μs).
To reach <500ns would require:
- Return parallel arrays instead of Dictionary
- Pre-allocate and reuse buffers across calls
- Or use a custom sparse data structure

## 3. Auto-tune Batch Size Based on Test Cost (6.3ms → 3.9ms) ✅ COMPLETED

**Problem**: Default batching (8) hurts performance for cheap tests.

| Batch Size | Time (100 iter, expensive test) Before | After (auto-tune) |
|------------|----------------------------------------|-------------------|
| 1 (sequential) | 2.7ms | 2.6ms |
| 16 | 3.9ms | 3.8ms |
| default (was 8) | 6.3ms | 3.9ms (auto) |

**Result**: ~40% improvement for expensive tests with auto-tuning.

**Optimizations Applied**:
- [x] Measure seed execution time during Phase 1
- [x] Auto-select batch size based on average test time
- [x] Default changed from 8 to 0 (auto-tune)

**Heuristic Implemented** (in `FuzzEngine.selectBatchSize`):
```swift
if avgTestTime < 100μs: batchSize = 1   // Sequential for cheap tests
else if avgTestTime < 1ms: batchSize = 4  // Small batches for medium tests
else: batchSize = 16                      // Large batches for expensive tests
```

## 4. Lazy String.fuzz Generation (53μs → 16ns) ✅ COMPLETED

**Problem**: String.fuzz generation is 3375x slower than Int.fuzz.

| Type | Before | After |
|------|--------|-------|
| Int.fuzz | 16ns | 16ns |
| String.fuzz | 53μs | 16ns |
| [Int].fuzz | 1.16μs | 1.16μs |

**Result**: 3375x improvement (53μs → 16ns). Now matches Int.fuzz speed.

**Root Cause**: The `String(repeating: "a", count: 1000)` was regenerated on every access.

**Solution Applied**:
- [x] Cache the fuzz array in a static `let` property
- Now returns a reference to the cached array instead of regenerating

## 5. CoverageSignature Full Counter Scan (1000x slower)

**Problem**: Creating CoverageSignature from full counter array is extremely slow.

| Input Type | Time |
|------------|------|
| Sparse (100 edges) | 3.8μs |
| Full (100 edges in 26K counters) | 4.3ms |

**Root Cause**: Scanning 26K counters to bucket and compress into signature.

**Solutions**:
- [ ] Always use sparse representation internally
- [ ] Never materialize full counter array when sparse is available
- [ ] Use SIMD for bucketing when full scan is unavoidable
- [ ] Incremental signature updates (delta from previous)
- [ ] Lazy signature computation (defer until comparison needed)

## Implementation Order

1. **Gap Detection** - Highest impact, likely requires architectural changes to make lazy
2. **snapshotCoveredOnly()** - High iteration-count impact, SIMD is straightforward
3. **Batch Size Tuning** - Medium impact, relatively simple to implement
4. **String.fuzz** - Lazy generation is a larger refactor but improves API ergonomics
5. **CoverageSignature** - Already uses sparse path in most cases, lower priority

## Benchmark Commands

```bash
# Run all benchmarks
./scripts/run-benchmarks.sh

# Run specific benchmark (must match full name)
./scripts/run-benchmarks.sh --filter "fuzz(Int) - 100 iterations, refuzzReplace"

# Compare against baseline
./scripts/run-benchmarks.sh --baseline baseline.json
```

## Success Metrics

- [ ] `fuzz(Int) - 100 iterations` with gap detection < 5ms (currently 38ms)
- [ ] `fuzz(Int) - 1000 iterations` < 10ms (currently 4ms without gaps)
- [ ] `SanCovCounters.snapshotCoveredOnly()` < 500ns (currently 3.85μs)
- [ ] `String.fuzz generation` < 5μs (currently 53μs)
