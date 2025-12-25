# Performance Optimization Plan

Based on benchmark analysis from December 2024.

## Summary

| Priority | Issue | Before | After | Status |
|----------|-------|--------|-------|--------|
| 1 | Gap detection overhead | +37ms constant | +9ms constant | ✅ 4x improvement |
| 2 | snapshotCoveredOnly() | 3.85μs/call | <500ns target | pending |
| 3 | Batch size tuning | 6.3ms (default) | 2.7ms (auto) target | pending |
| 4 | String.fuzz generation | 53μs | <5μs target | pending |
| 5 | CoverageSignature full scan | 4.3ms | 3.8μs target | pending |

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

## 2. SanCovCounters.snapshotCoveredOnly() (18x slower than full)

**Problem**: The sparse snapshot is counterintuitively slower than the full snapshot.

| Operation | Time (p50) |
|-----------|------------|
| snapshot() - full | 208ns |
| snapshotCoveredOnly() | 3.85μs |

Called every iteration, this adds ~3.8ms per 1000 iterations.

**Root Cause**: Linear scan through all counters to find non-zero entries, building a dictionary.

**Solutions**:
- [ ] Use SIMD instructions to scan counter array (find non-zero bytes in parallel)
- [ ] Maintain a separate bitmap of "ever-covered" indices, only scan those
- [ ] Use hierarchical sparse tracking (coarse bitmap + fine counters)
- [ ] Return a lazy/streaming iterator instead of materializing dictionary
- [ ] Consider bloom filter for quick "definitely zero" checks

## 3. Auto-tune Batch Size Based on Test Cost

**Problem**: Default batching hurts performance for cheap tests.

| Batch Size | Time (100 iter, expensive test) |
|------------|--------------------------------|
| 1 (sequential) | 2.7ms |
| 16 | 3.9ms |
| default | 6.3ms |

For cheap tests, sequential execution is fastest because batching overhead exceeds parallelization benefit.

**Root Cause**: Task creation and synchronization overhead dominates when test execution is fast.

**Solutions**:
- [ ] Measure first N iterations to estimate test cost
- [ ] Auto-select batch size: cheap tests → batchSize=1, expensive → larger batches
- [ ] Expose batch size as a tunable parameter with sensible defaults
- [ ] Consider adaptive batching that adjusts during the run

**Heuristic**:
```
if (avg_test_time < 100μs) batchSize = 1
else if (avg_test_time < 1ms) batchSize = 4
else batchSize = 16
```

## 4. Lazy String.fuzz Generation

**Problem**: String.fuzz generation is 45x slower than Int.fuzz.

| Type | fuzz Generation Time |
|------|---------------------|
| Int.fuzz | 1.16μs |
| String.fuzz | 53μs |
| [Int].fuzz | 1.16μs |

**Root Cause**: String generates large cartesian products of characters, lengths, and special strings.

**Solutions**:
- [ ] Make fuzz a lazy sequence instead of eager array
- [ ] Reduce default fuzz set size for String
- [ ] Use a generator that yields values on-demand
- [ ] Cache computed fuzz arrays (they're deterministic)
- [ ] Consider streaming/chunked generation for large types

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
