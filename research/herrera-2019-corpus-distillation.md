# Corpus Distillation for Effective Fuzzing: A Comparative Evaluation

**Authors:** Adrian Herrera, Hendra Gunadi, et al.
**Published:** 2019
**Source:** arXiv:1905.13055
**Institution:** The Australian National University

## Paper Summary

This paper presents a comprehensive evaluation of corpus distillation techniques for mutation-based fuzzing, representing 34+ CPU-years of experimental work. The central problem addressed is that fuzzers often begin with large seed corpora containing thousands of similar inputs, leading to wasted effort through exhaustive mutation of redundant seeds. The authors investigate whether minimizing the corpus - selecting the smallest subset that maintains the same code coverage - improves bug-finding effectiveness in real-world software.

The research compares five different approaches across diverse targets including the Google Fuzzer Test Suite and real-world libraries covering 13 file formats (PDF, MP3, WAV, SVG, TIFF, TTF, XML). The study exposed 33 bugs, with seven receiving CVE assignments. A key finding is that distillation is a necessary precursor to any fuzzing campaign when starting with a large initial corpus, but no single technique dominates - each has complementary strengths. Advanced tools like MoonLight and Minset found different bugs that AFL's afl-cmin missed, suggesting hybrid approaches could maximize effectiveness.

The paper introduces MoonLight, an open-source distillation tool that formulates corpus reduction as a weighted minimum set cover problem (WMSCP). MoonLight uses dynamic programming with matrix operations to efficiently compute near-optimal solutions, extending the Minset approach. Experimental results show that MoonLight weighted by file size is, on average, the fastest at finding bugs compared to Minset and afl-cmin, while maximizing fuzzing yield is achieved with either MoonLight (file-size weighted) or Unweighted Minset.

## Key Strategies/Techniques

### 1. Five Distillation Approaches Evaluated

- **Full**: Undistilled collection corpus (preprocessed for duplicates/size)
- **CMIN (afl-cmin)**: AFL's greedy distillation using edge frequency counts
- **MS-U (Unweighted Minset)**: Unweighted minimum set cover algorithm
- **ML-S (MoonLight-Size)**: MoonLight weighted by file size
- **Empty**: Minimal handcrafted seed for each file format

### 2. Weighted Minimum Set Cover Problem (WMSCP)

All state-of-the-art techniques model distillation as WMSCP where:
- **Universe**: Code coverage information (edges between basic blocks)
- **Goal**: Minimum set of seeds maintaining observed coverage
- **Weights**: Optional file sizes or execution times

The problem satisfies four properties:
1. Maximize coverage diversity
2. Eliminate behavioral redundancy
3. Minimize total corpus size
4. Minimize individual seed sizes

### 3. MoonLight Algorithm

Represents coverage as a matrix where rows are seeds and columns are edges. The dynamic programming approach:
1. Eliminates singularities (zero-sum rows/columns)
2. Identifies exotic rows (sole coverage sources)
3. Detects row/column dominance
4. Uses heuristics selecting rows with largest weighted sums when optimal operations unavailable

### 4. AFL's afl-cmin Approach

- Records edge frequency counts rather than binary coverage
- Selects the smallest seed covering each edge
- Performs weighted greedy reduction
- Uses AFL's edge coverage approximation for efficiency

### 5. Energy-Based Evaluation Metrics

The research evaluated effectiveness using:
- **Code coverage**: Measured via AFL's instrumentation
- **Bug count**: Manual triage avoiding stack-hash deduplication issues
- **Bug-finding reliability**: Frequency of discovering each bug across trials
- **Time-to-bug**: Mean discovery time for successful trials
- **Corpus characteristics**: File count and total size reduction

## Applicability to PropertyTestingKit

### High Applicability - Core Architecture Alignment

PropertyTestingKit's architecture is well-suited for implementing corpus distillation:

1. **Coverage-Guided Foundation**: PropertyTestingKit already implements AFL-inspired coverage-guided fuzzing with coverage signatures based on bucketed execution counts (following AFL's approach). This is the exact foundation needed for corpus distillation.

2. **Existing Corpus Management**: The `Corpus` struct (Corpus.swift) maintains entries with coverage signatures and already implements a greedy set cover minimization algorithm in the `minimized()` method (lines 174-214). This is directly comparable to the techniques evaluated in the paper.

3. **Coverage Signature Infrastructure**: The `CoverageSignature` struct uses bucketed counter values (matching AFL's categories: 0, 1, 2, 3, 4-7, 8-15, etc.) and provides methods like `hasUniqueCoverage()` and `union()` that are essential primitives for distillation algorithms.

4. **Corpus Persistence**: PropertyTestingKit saves corpora to disk (corpus.json) with coverage signatures, enabling offline distillation and corpus evolution across test runs.

### Key Insights from Paper Applicable to PropertyTestingKit

1. **Multiple Techniques Have Complementary Strengths**: The paper shows that MoonLight, Minset, and afl-cmin each found different bugs. PropertyTestingKit could benefit from supporting multiple distillation strategies rather than a single approach.

2. **Weighted vs Unweighted Trade-offs**: Unweighted Minset maximizes bug yield, while file-size-weighted MoonLight finds bugs fastest. PropertyTestingKit currently uses unweighted greedy selection, which aligns with maximizing yield.

3. **Distillation is Essential with Large Corpora**: The paper proves distillation is necessary when starting with large initial corpora. PropertyTestingKit's `.refuzzExtend` mode, which loads an existing corpus and continues fuzzing, would particularly benefit from distillation.

4. **Energy-Based Scheduling Complements Distillation**: PropertyTestingKit already implements energy-based seed selection in `selectForMutation()` (lines 225-267), prioritizing entries covering rare indices. This aligns with the paper's findings about the importance of seed selection strategy.

### Limitations and Considerations

1. **Different Domain**: The paper focuses on file-format fuzzing (PDF, MP3, etc.) where file size matters for execution time. PropertyTestingKit targets Swift APIs and functions where "input size" has different semantics.

2. **Swift-Specific Context**: PropertyTestingKit works with Swift types (structs, enums, tuples) rather than binary file formats. Corpus entry "size" metrics need adaptation (e.g., structural complexity, serialized JSON size).

3. **Value Profile Guidance**: PropertyTestingKit supports value profile guidance for comparison tracking, which goes beyond basic edge coverage. Distillation algorithms should consider value profiles, not just edge coverage.

4. **Test Framework Integration**: PropertyTestingKit integrates with Swift Testing framework and needs fast regression testing. Distillation must balance corpus size with deterministic test execution time.

## Concrete Recommendations

### 1. Implement MoonLight-Style Dynamic Programming Distillation

**Current State**: `Corpus.minimized()` uses basic greedy selection (lines 186-211).

**Enhancement**: Implement MoonLight's matrix-based dynamic programming approach:

```swift
// In Corpus.swift
public func minimizedAdvanced(weighted: Bool = false) -> Corpus<repeat each Input> {
    // Build coverage matrix: rows = entries, columns = coverage indices
    // Apply MoonLight reductions: singularities, exotic rows, dominance
    // Use dynamic programming for optimal selection
}
```

**Implementation Strategy**:
- Create a `CoverageMatrix` type to represent the rows/columns structure
- Implement matrix reduction operations (eliminate zero-sum, identify exotic rows, detect dominance)
- Add weighted variants using serialized input size (JSON byte count)
- Benchmark against existing greedy approach

### 2. Add Configurable Distillation Strategies

**Enhancement**: Allow users to choose distillation strategy via configuration:

```swift
public enum DistillationStrategy: Sendable {
    case greedy           // Current implementation (fast, reasonable)
    case moonlightUnweighted  // Best for bug yield
    case moonlightWeighted    // Best for bug-finding speed
    case hybrid           // Run multiple, take union of results
}

// In fuzz() API
try fuzz(
    distillationStrategy: .moonlightWeighted,
    // ... other parameters
) { input in
    // test
}
```

**Rationale**: Paper shows different techniques have complementary strengths. Provide flexibility for users to optimize for different goals (fast CI runs vs. maximum bug discovery).

### 3. Implement Hybrid Multi-Strategy Distillation

**Enhancement**: Since the paper shows different techniques find different bugs, implement a hybrid approach:

```swift
// In Corpus.swift
public func minimizedHybrid() -> Corpus<repeat each Input> {
    let greedyCorpus = minimized()
    let moonlightCorpus = minimizedAdvanced(weighted: false)
    let moonlightWeightedCorpus = minimizedAdvanced(weighted: true)

    // Merge: take union of all three minimized sets
    // This may be larger but finds more bugs
    return merge([greedyCorpus, moonlightCorpus, moonlightWeightedCorpus])
}
```

**Use Case**: For critical test suites or extended fuzzing campaigns where thoroughness matters more than corpus size.

### 4. Add Pre-Fuzzing Distillation for Large Seed Sets

**Current State**: Users can provide custom seeds via `seeds:` parameter, and PropertyTestingKit combines these with type defaults.

**Enhancement**: When seed count exceeds a threshold (e.g., 100), automatically distill before fuzzing:

```swift
// In fuzzing engine
if allSeeds.count > 100 {
    // Run quick coverage sampling of all seeds
    let sampledCoverage = allSeeds.map { seed in
        (seed, captureCoverageSignature(test(seed)))
    }

    // Distill to minimal set maintaining coverage
    let distilledSeeds = Corpus.distillSeeds(sampledCoverage)
    startFuzzingWith(distilledSeeds)
} else {
    startFuzzingWith(allSeeds)
}
```

**Rationale**: Paper proves distillation is "necessary precursor" with large initial corpora. This would help users who provide extensive domain-specific seeds.

### 5. Implement Corpus Quality Metrics

**Enhancement**: Add diagnostic metrics to understand corpus effectiveness:

```swift
public struct CorpusMetrics: Sendable, Codable {
    /// Total unique coverage indices
    let totalCoverage: Int

    /// Average coverage per entry
    let averageCoveragePerEntry: Double

    /// Redundancy ratio (how much overlap exists)
    let redundancyRatio: Double

    /// Entries covering unique indices (exotic rows)
    let uniqueCoverageEntries: Int
}

extension Corpus {
    public func metrics() -> CorpusMetrics {
        // Calculate metrics for corpus quality analysis
    }
}
```

**Use Case**: Help users understand whether their corpus is well-distilled or needs optimization. Report in verbose fuzzing logs.

### 6. Add Environment Variable for Distillation Control

**Enhancement**: Provide environment-level control consistent with existing design:

```swift
// New environment variable
FUZZ_DISTILLATION_STRATEGY=moonlight    // greedy, moonlight, weighted, hybrid

// In configuration
extension FuzzConfiguration {
    static func fromEnvironment() -> Self {
        let strategy: DistillationStrategy = {
            switch ProcessInfo.processInfo.environment["FUZZ_DISTILLATION_STRATEGY"] {
            case "moonlight": return .moonlightUnweighted
            case "weighted": return .moonlightWeighted
            case "hybrid": return .hybrid
            default: return .greedy
            }
        }()
        // ...
    }
}
```

**Rationale**: Consistent with existing environment-based configuration (FUZZ_CORPUS_MODE, FUZZ_ITERATIONS, etc.).

### 7. Benchmark and Document Trade-offs

**Action**: Create benchmark tests comparing distillation strategies:

```swift
@Suite("Corpus Distillation Benchmarks")
struct DistillationBenchmarks {
    @Test func compareStrategies() async throws {
        let largeCorpus = generateTestCorpus(size: 1000)

        // Measure distillation time and resulting size
        let greedyResult = measure { largeCorpus.minimized() }
        let moonlightResult = measure { largeCorpus.minimizedAdvanced() }

        // Document in research/
        print("Greedy: \(greedyResult.size) entries in \(greedyResult.time)ms")
        print("MoonLight: \(moonlightResult.size) entries in \(moonlightResult.time)ms")
    }
}
```

**Deliverable**: Add research/distillation-benchmarks.md documenting strategy comparison on PropertyTestingKit workloads.

### 8. Consider Value Profile Integration

**Research Direction**: The paper focuses on edge coverage, but PropertyTestingKit has value profile guidance. Investigate extending distillation to consider value profiles:

- Should two entries with same edge coverage but different value profiles both be retained?
- Can MoonLight's WMSCP formulation extend to multi-dimensional coverage (edges + value profiles)?
- Would this improve bug-finding or just increase corpus size?

This requires experimentation but could be a unique contribution beyond the paper's scope.

## Implementation Priority

1. **High Priority**: Add configurable distillation strategies (Recommendation #2) - enables experimentation without breaking changes
2. **High Priority**: Implement corpus quality metrics (Recommendation #5) - helps users understand current behavior
3. **Medium Priority**: Implement MoonLight algorithm (Recommendation #1) - significant implementation effort, needs benchmarking
4. **Medium Priority**: Pre-fuzzing distillation for large seeds (Recommendation #4) - clear user benefit, bounded scope
5. **Low Priority**: Hybrid multi-strategy (Recommendation #3) - interesting but increases corpus size, may harm CI performance
6. **Low Priority**: Value profile integration (Recommendation #8) - research direction requiring significant exploration

## References

- Herrera, A., Gunadi, H., et al. (2019). "Corpus Distillation for Effective Fuzzing: A Comparative Evaluation." arXiv:1905.13055
- Paper URL: https://arxiv.org/abs/1905.13055
- HTML version: https://ar5iv.labs.arxiv.org/html/1905.13055

## Related Work

This paper builds on:
- AFL (American Fuzzy Lop) - Introduced coverage-guided fuzzing and basic corpus minimization
- Minset - Extended AFL's approach with weighted variants
- Set cover problem literature - NP-complete problem requiring approximation algorithms

PropertyTestingKit should also investigate:
- AFL++ corpus distillation improvements (post-2019)
- Coverage-guided fuzzing for structured inputs (not just binary files)
- Test case reduction techniques (e.g., delta debugging, which PropertyTestingKit already researched)
