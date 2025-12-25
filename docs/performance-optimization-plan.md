# CoverageGapDetector Optimization Plan

## Status: COMPLETED ✓

Implemented two optimizations:
1. Per-function PC range filtering (Phase 1)
2. Symbol table function sizes (Phase 2)

## Problem (Fixed)

`CoverageGapDetector.detect()` was making excessive `dladdr` calls, wasting ~98% of them on edges that aren't in tested functions.

**Before optimization (testNumberParserCoverage):**
```
Step 2 total: 0.504s
  - PC filter time: 0.000s (16,129 edges filtered out)
  - dladdr time: 0.497s (5,785 calls)  ← 98.6% of time
  - Function filter time: 0.005s (5,686 edges filtered out)

Total dladdr calls: 5,805
```

## Solution Implemented

### Phase 1: Per-Function PC Range Filtering
Changed from **global PC range** filter to **per-function PC range** filter.

### Phase 2: Symbol Table Function Sizes
Query the Mach-O symbol table once to get accurate function sizes instead of using arbitrary padding:

1. **Symbol Table Parsing:** Parse the symbol table from the loaded binary's Mach-O header
2. **Function Sizes:** Compute sizes as gaps between adjacent symbols (sorted by address)
3. **Accurate Bounds:** Use `functionStart + size` instead of `functionStart + padding`

Benefits:
- Large functions (>4KB) are now fully covered
- Small functions have tighter bounds, filtering more edges

## Results

**After Phase 2 (testNumberParserCoverage):**
```
Symbol table lookup: 0.049s for 9 functions (32,631 symbols parsed)
Step 2 total: 0.014s
  - PC filter time: 0.004s (21,811 edges filtered out)
  - dladdr time: 0.009s (103 calls)
  - Function filter time: 0.000s (4 edges filtered out)

Total dladdr calls: 123
```

### Improvement Summary

| Metric | Original | Phase 1 | Phase 2 | Total Improvement |
|--------|----------|---------|---------|-------------------|
| dladdr calls | 5,805 | 496 | 123 | **47x reduction** |
| Step 2 time | 0.504s | 0.047s | 0.014s | **36x faster** |
| Edges filtered by PC | 16,129 | 21,438 | 21,811 | More precise |
| Edges filtered by func name | 5,686 | 377 | 4 | Minimal waste |

Symbol table is parsed once and cached. First call ~50ms, subsequent calls near-zero.

## Benchmark Results

```
fuzz(Int) - 1000 iterations, with gap detection
------------------------------------------------
Before: 45ms (p50)
After:  11ms (p50)
Improvement: 76-82% faster (4x speedup)
```
