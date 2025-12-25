# CoverageGapDetector Optimization Plan

## Status: COMPLETED ✓

Implemented per-function PC range filtering to reduce dladdr calls.

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

Changed from **global PC range** filter to **per-function PC range** filter:

1. **Step 1:** Build per-function PC ranges from covered edges
   - Track `functionPCRanges: [String: (min: UInt, max: UInt)]` for each tested function
   - Pre-compute `paddedFunctionRanges` array with 4KB padding per function

2. **Step 2:** Two-phase filtering before dladdr
   - First filter: Global PC range (very fast)
   - Second filter: Check if PC falls within ANY tested function's padded range
   - Only call dladdr if both filters pass

## Results

**After optimization (testNumberParserCoverage):**
```
Step 2 total: 0.047s
  - PC filter time: 0.003s (21,438 edges filtered out)
  - dladdr time: 0.043s (476 calls)
  - Function filter time: 0.000s (377 edges filtered out)

Total dladdr calls: 496
```

### Improvement Summary

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| dladdr calls | 5,805 | 496 | **11.7x reduction** |
| Step 2 time | 0.504s | 0.047s | **10.7x faster** |
| Uncovered edges | 99 | 99 | Same (correctness preserved) |

~11x faster gap detection with per-function PC range filtering.
