# KFIFOQueue Optimization History

## Summary
Optimized KFIFOQueue from ~240 M ops/sec to ~10,000 M ops/sec (10 billion) - a **42x improvement**.

## Optimizations Applied

### 1. Swift Atomics DoubleWord (240 → 4000 M ops/sec)
- **Problem:** Custom lock-based 128-bit CAS fallback was catastrophically slow
- **Fix:** Used Swift Atomics' built-in `DoubleWord` and `UnsafeAtomic<DoubleWord>`
- **File:** `Sources/ConcurrentQueues/KFIFOQueue.swift`

### 2. Memory Alignment Fix (crash fix)
- **Problem:** SIGBUS crash - slots at offset 24 weren't 16-byte aligned for 128-bit atomics
- **Fix:** Changed `_rawSegmentSlotsOffset` from 24 to 32 bytes

### 3. @inlinable on All Hot Paths (4000 → 7900 M ops/sec)
- **Problem:** Function call overhead for cross-module calls from benchmark
- **Fix:** Made all hot path methods `@inlinable`:
  - `enqueue`, `dequeue`, `close`, `isClosed`
  - `findEmptySlot`, `findItem`, `committed`, `isReachable`
  - `advanceTail`, `advanceHead`, `decodeItem`
  - `RawSegment.init(ptr:)`

### 4. Fix Double isReachable Call (7900 → 9000 M ops/sec)
- **Problem:** `committed()` called `isReachable()` twice with same arguments
- **Fix:** Cache result in local variable, restructured to match paper's pseudocode
- **Also fixed:** Missing CAS rollback logic in `not_in_queue` and `in_queue_at_head` branches

### 5. Remove Sanitizer Coverage (9000 → 9300 M ops/sec)
- **Problem:** ProfiledBenchmark had `-sanitize-coverage` flags causing instrumentation overhead
- **Fix:** Removed PropertyTestingKit dependency and sanitizer flags from ProfiledBenchmark target

### 6. For Loop → While Loop (9300 → 10000 M ops/sec)
- **Problem:** `for i in 0..<k` had `IndexingIterator.next()` protocol witness overhead
- **Fix:** Replaced with `while i < k` using overflow operators (`&+`, `&-`)
- **Files:** `findEmptySlot()` and `findItem()` functions

## Failed Optimization Attempts

### Global Atomic Counter for RNG
- **Attempted:** Replace pthread TLS with `ManagedAtomic<UInt64>` counter
- **Result:** 73s of `swift_retain`/`swift_release` overhead - `ManagedAtomic` is a class
- **Tried:** `UnsafeAtomic` with `AtomicCounter` wrapper class
- **Result:** Still 30s overhead from cache line contention across all threads
- **Conclusion:** pthread TLS (~1.7s overhead) is better than global counter contention

## Remaining Optimization Opportunities

### 1. isReachable() - O(n) Linked List Traversal (~8% of time)
- Currently traverses segment chain from head to find target
- **Fix would require:** Adding segment generation numbers for O(1) comparison
- **Complexity:** Structural change to RawSegment and head/tail DoubleWords
- **Priority:** Medium - only matters with many segments

### 2. Memory Allocation (~12% of time)
- `RawBox.allocate`/`deallocate` and segment creation
- **Potential fix:** Segment pooling / object pooling
- **Complexity:** Medium - adds lifecycle management
- **Priority:** Low - malloc is reasonably fast

### 3. Direct Storage for Larger Types
- Currently only types ≤7 bytes use direct storage
- `Int` is 8 bytes, so it uses heap allocation
- **Potential fix:** Increase direct storage threshold or use tagged pointers
- **Complexity:** Low-Medium
- **Priority:** Low - benchmark-specific

## Final Profile (10B ops/sec)

| Function | Self Time % | Notes |
|----------|-------------|-------|
| enqueue | 87.0% | Core atomic work - unavoidable |
| Kernel | 32.7% | OS overhead |
| findEmptySlot | 17.8% | Slot scanning |
| dequeue | 16.9% | Core atomic work |
| committed | 13.5% | Validation |
| advanceTail | 11.3% | Segment allocation |
| isReachable | 8.2% | Linked-list traversal |
| Memory ops | ~12% | malloc/free |
| pthread TLS | ~3.6% | RNG state |

## Key Files
- `Sources/ConcurrentQueues/KFIFOQueue.swift` - Main implementation
- `Package.swift` - ProfiledBenchmark target configuration
- `Benchmarks/ProfiledBenchmark/` - Benchmark code
