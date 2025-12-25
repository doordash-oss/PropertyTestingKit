# Performance Optimization Plan

Based on benchmark analysis from December 2024. Baseline: `first_optimization`.

## Summary - Phase 2 Complete

| Priority | Issue | Before | After | Status |
|----------|-------|--------|-------|--------|
| 1 | snapshotCoveredOnly() Dictionary overhead | 6.9μs | 1.2μs | ✅ 5.6x faster |
| 2 | CoverageSignature(sparse) hash bucketing | 5.4μs | 4.9μs | ✅ 10% faster |
| 3 | hasUniqueCoverage Set creation | (created Sets) | 137ns | ✅ Optimized |
| 4 | Gap detection dladdr calls | ~5ms | ~5ms | ✅ Already acceptable |

## Hot Path Improvement (per iteration)

```
Before: snapshot + signature = 6.9μs + 5.4μs = 12.3μs
After:  snapshot + signature = 1.2μs + 4.9μs = 6.1μs
```

**Result: 2x faster per-iteration coverage processing**

## Completed Optimizations (Phase 1)

| Optimization | Before | After | Improvement |
|-------------|--------|-------|-------------|
| Gap detection | 37ms | 5ms | 7x faster |
| snapshotCoveredOnly() SIMD | 3.85μs | 3.72μs | 8% faster |
| Batch size auto-tune | 6.3ms | 3.6ms | 40% faster |
| String.fuzz caching | 53μs | 16ns | 3375x faster |

## Completed Optimizations (Phase 2)

### 1. SparseCoverage Type (5.6x faster)

Replaced `[Int: UInt8]` dictionary return with parallel arrays:

```swift
// Before
func snapshotCoveredOnly() -> [Int: UInt8]?  // 6.9μs

// After
func snapshotCoveredArrays() -> SparseCoverage?  // 1.2μs

public struct SparseCoverage: Sendable {
    let indices: [UInt32]
    let counts: [UInt8]
}
```

### 2. CoverageSignature(sparse:) Init (10% faster)

Used `Dictionary(uniqueKeysWithValues:)` for bulk construction:

```swift
// Before: repeated Dictionary insertions
for i in 0..<sparse.count {
    buckets[Int(sparse.indices[i])] = bucket
}

// After: single bulk construction
self.buckets = Dictionary(uniqueKeysWithValues: pairs)
```

### 3. hasUniqueCoverage Early Exit

Eliminated intermediate Set creation:

```swift
// Before: created Set for comparison
public func hasUniqueCoverage(comparedTo other: CoverageSignature) -> Bool {
    !uniqueIndices(comparedTo: other).isEmpty  // Creates intermediate Set
}

// After: early exit on first unique index
public func hasUniqueCoverage(comparedTo other: CoverageSignature) -> Bool {
    for key in buckets.keys {
        if other.buckets[key] == nil {
            return true
        }
    }
    return false
}
```

### 4. Gap Detection

Gap detection at ~5ms is acceptable since it only runs once at the end of a fuzz run
(not per-iteration). The 560ms case only occurs when significant coverage gaps exist.

## Evaluated Optimizations (Not Beneficial)

### Corpus.addIfInteresting Bloom Filter

**Attempted:** Bloom filter for O(1) rejection of non-interesting inputs.

**Result:** No improvement. `hasUniqueCoverage` is already O(1) per key via dictionary
lookup, matching the bloom filter's complexity. The added hash computation overhead
made it slightly slower (2.1μs vs 2.0μs for 100 entries).

**Conclusion:** The `hasUniqueCoverage` early-exit optimization (Phase 2, item 3)
eliminated the need for a bloom filter.

## Phase 3 - Synchronization Overhead

Identified unnecessary actor boundary crossings and async overhead in hot path.

| Priority | Issue | Hot Path Impact | Status |
|----------|-------|-----------------|--------|
| 1 | DateClient.now() async | ~10 awaits/batch | ✅ Completed |
| 2 | Corpus actor hops | ~400 hops/batch | ✅ Completed |
| 3 | PlateauDetector.record() async | 1 await/iteration | ✅ Completed (via #1) |
| 4 | ValueProfileTracker actor | 1 hop/batch | ✅ Completed |
| 5 | union() creates new Dict | 1 alloc/add | ✅ Completed |
| 6 | entries() copies array | 1 copy/batch | ✅ Completed (via #2) |
| 7 | executedIndices creates Set | Minimization only | ✅ Completed |

### 1. DateClient.now() synchronous ✅

Made `DateClient.now` synchronous since `Date()` is thread-safe.

**Changes:**
- `DateClient.now`: `@Sendable () async -> Date` → `@Sendable () -> Date`
- `CoveragePlateauDetector.record()`: removed async
- `CoveragePlateauDetector.stats()`: removed async
- `CorpusEntry.init`: removed async
- `FailureInfo.init`: removed async
- `Corpus.init`, `addIfInteresting`, `add`, `minimized`: removed async/await
- `CorpusClient.live()`, `alwaysInteresting()`: removed async
- `CorpusRegistryProtocol.get()`: removed async

**Files modified:**
- `Sources/PropertyTestingKit/Dependencies/DateClient.swift`
- `Sources/PropertyTestingKit/Fuzzing/CoveragePlateauDetector.swift`
- `Sources/PropertyTestingKit/Fuzzing/Corpus/CorpusEntry.swift`
- `Sources/PropertyTestingKit/Fuzzing/Corpus/FailureInfo.swift`
- `Sources/PropertyTestingKit/Fuzzing/Corpus/Corpus.swift`
- `Sources/PropertyTestingKit/Dependencies/CorpusClient.swift`
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine/FuzzEngine.swift`
- `Sources/PropertyTestingKit/Fuzzing/TestCaseShrinker.swift`
- Test files updated to use `SyncBox` for deterministic timing tests

### 2. Corpus batch state API ✅

Each input generation in a batch was making 3-4 actor hops:
```swift
let corpusIsEmpty = await corpus.isEmpty()        // hop 1
let corpusCount = await corpus.count()            // hop 2
selectedIndex = await corpus.selectForMutation()  // hop 3
let entries = await corpus.entries()              // hop 4 (copies entire array!)
```

For batch of 100, that was ~400 actor crossings.

**Solution:** Added `CorpusBatchState` struct and `batchState()` method.

```swift
// Before: ~400 actor hops per batch
for batchIdx in 0..<batchSize {
    let isEmpty = await corpus.isEmpty()
    let count = await corpus.count()
    // ...
}

// After: 1 actor hop per batch
let corpusState = await corpus.batchState()
for batchIdx in 0..<batchSize {
    if corpusState.isEmpty { ... }
    let idx = corpusState.selectForMutation()
    let parent = corpusState.entries[idx].input
}
```

**Files modified:**
- `Sources/PropertyTestingKit/Fuzzing/Corpus/Corpus.swift` - Added `CorpusBatchState`, `batchState()`
- `Sources/PropertyTestingKit/Dependencies/CorpusClient.swift` - Added `batchState` property
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine/FuzzEngine.swift` - Use batch state API

### 3. CoveragePlateauDetector.record() async

Only async because it calls `dateClient.now()` once at startup.

**Solution:** Remove async after DateClient fix.

### 4. ValueProfileTracker nonisolated methods ✅

`extractTargets()` and `scoreBonus()` were crossing actor boundaries unnecessarily.
They only read from thread-local C state (`vp_get_records()`) or operate on input parameters.

**Solution:** Marked both methods `nonisolated`.

```swift
// Before
public func extractTargets() -> [ComparisonTarget]  // actor-isolated
public func scoreBonus(for:) -> Double              // actor-isolated

// After
nonisolated public func extractTargets() -> [ComparisonTarget]
nonisolated public func scoreBonus(for:) -> Double
```

**Files modified:**
- `Sources/PropertyTestingKit/Fuzzing/ValueProfile.swift` - Added `nonisolated` to both methods
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine/FuzzEngine.swift` - Removed `await` from `extractTargets()` call

### 5. CoverageSignature in-place merge ✅

Every `addIfInteresting` was creating a new dictionary:
```swift
totalCoverage = totalCoverage.union(with: signature)
```

**Solution:** Added mutating `merge(with:)` method for in-place modification.

```swift
// Before: allocates new dictionary
totalCoverage = totalCoverage.union(with: signature)

// After: modifies in-place
totalCoverage.merge(with: signature)
```

**Changes:**
- `CoverageSignature.buckets`: `let` → `private(set) var`
- Added `mutating func merge(with:)` method
- Updated all call sites in Corpus and SignatureSet

**Files modified:**
- `Sources/PropertyTestingKit/Fuzzing/CoverageSignature.swift` - Added `merge(with:)`, changed `buckets` to `var`
- `Sources/PropertyTestingKit/Fuzzing/Corpus/Corpus.swift` - Use `merge` in `addIfInteresting`, `add`, `minimized`

### 6. Corpus.entries() returns full copy ✅

FuzzEngine was copying entire array to access one entry:
```swift
let entries = await corpus.entries()
let parent = entries[selectedIndex].input
```

**Solution:** Addressed via batch state API (#2). The batch state captures entries once
per batch rather than once per iteration, and the copy is shared across all iterations.

### 7. executedIndices Set operations ✅

`minimized()` was creating intermediate Sets for every entry:
```swift
uncovered.subtract(entry.signature.executedIndices)  // Creates Set
entry.signature.executedIndices.intersection(uncovered).count  // Creates 2 Sets
```

**Solution:** Added helper methods that operate on `buckets.keys` directly.

```swift
// Before: creates intermediate Set
uncovered.subtract(entry.signature.executedIndices)
let count = entry.signature.executedIndices.intersection(uncovered).count

// After: operates on keys directly
entry.signature.subtractIndices(from: &uncovered)
let count = entry.signature.countIndicesIn(uncovered)
```

**Files modified:**
- `Sources/PropertyTestingKit/Fuzzing/CoverageSignature.swift` - Added `subtractIndices(from:)`, `countIndicesIn(_:)`
- `Sources/PropertyTestingKit/Fuzzing/Corpus/Corpus.swift` - Updated `minimized()` to use new methods

## Remaining Lower-Priority Opportunities

### snapshotCoveredArrays Array Trimming

Currently trims arrays with `removeLast()`. Could pre-size exactly using
two-pass or reusable buffer pool. Minor impact.

## Benchmark Commands

```bash
# Run all benchmarks
./scripts/run-benchmarks.sh

# Run specific benchmark
./scripts/run-benchmarks.sh --filter "SanCovCounters.snapshotCoveredArrays()"
```

## Key Files Modified (Phase 2)

- `Sources/PropertyTestingKit/SanCovCounters.swift` - Added SparseCoverage, snapshotCoveredArrays()
- `Sources/PropertyTestingKit/Fuzzing/CoverageSignature.swift` - init(sparse:), hasUniqueCoverage optimization
- `Sources/PropertyTestingKit/Dependencies/CoverageCountersClient.swift` - Updated dependency
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine/FuzzEngine.swift` - Use new APIs
- `Benchmarks/CoverageBenchmarks/CoverageBenchmarks.swift` - Added new benchmarks
