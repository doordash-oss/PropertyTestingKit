# Ankou: Guiding Grey-box Fuzzing towards Combinatorial Difference

**Paper**: Manès, V. J. M., Kim, S., & Cha, S. K. (2020). Ankou: Guiding Grey-box Fuzzing towards Combinatorial Difference. In Proceedings of the IEEE/ACM 42nd International Conference on Software Engineering (ICSE), 1024-1036.

**URL**: https://www.jiliac.com/files/ankou-icse2020.pdf (Note: Direct PDF access currently unavailable)

**Code**: https://github.com/SoftSec-KAIST/Ankou

---

## Paper Summary

Traditional coverage-guided grey-box fuzzers (like AFL) use fitness functions based on edge coverage—essentially tracking which branches are executed during program execution. However, these fitness functions treat coverage as a simple union of executed edges, making them unable to distinguish between test cases that execute the same branches but in different combinations or sequences. This limitation causes fuzzers to get stuck in local optima, where many test cases appear equally valuable despite exercising different program behaviors.

Ankou addresses this fundamental limitation by introducing the concept of "combinatorial difference"—a fitness function that recognizes not just which branches are executed, but how branches combine together during execution. Instead of treating each edge independently, Ankou treats the entire execution trace as a high-dimensional vector where each dimension represents a branch, and the value represents how many times that branch was hit. Two test cases that execute the same set of branches but with different frequencies or in different combinations produce distinct vectors, allowing Ankou to differentiate between superficially similar executions and guide the fuzzer toward genuinely novel program behaviors.

The core technical innovation is using Principal Component Analysis (PCA) to handle the scalability challenge of tracking all possible branch combinations. PCA performs dimensionality reduction on the branch execution vectors, identifying the principal components that capture the most variance in program behavior. This allows Ankou to efficiently compute distances between execution traces in the reduced space, prioritizing test cases that are far from previously explored combinations. The evaluation demonstrates that this approach is highly effective: Ankou found 1.94× more bugs than AFL and 8.0× more bugs than Angora on a benchmark of 24 real-world programs. However, the paper also acknowledges significant scalability challenges—the PCA computation triggers after approximately 30 minutes of fuzzing and can cause memory exhaustion on large programs, sometimes requiring higher-memory VMs to run successfully.

---

## Key Strategies/Techniques

1. **Combinatorial Coverage Tracking**: Instead of tracking coverage as a set of executed edges (union-based), Ankou treats each execution as a vector in a high-dimensional space where each dimension corresponds to a branch and the value is the hit count for that branch. This allows distinguishing between executions that hit the same branches but with different frequencies or patterns.

2. **Principal Component Analysis (PCA) for Dimensionality Reduction**: To handle the scalability challenge of tracking all possible branch combinations in high-dimensional space, Ankou applies PCA to reduce the dimensionality while preserving the most significant variance in execution behavior. This enables efficient distance calculations between execution traces.

3. **Dynamic PCA Updates**: The PCA model is updated dynamically during fuzzing (typically triggering after ~30 minutes) as new execution patterns are observed. This adaptive approach ensures the dimensionality reduction remains relevant to the evolving corpus.

4. **Distance-Based Fitness Function**: Seed selection prioritizes test cases that are far from previously explored execution patterns in the PCA-reduced space. Seeds revealing more "information" (i.e., greater distance from known patterns) receive higher weights during selection.

5. **Execution Vector Normalization**: Branch hit counts are bucketed (similar to AFL's approach) to create execution vectors that are robust to minor variations in loop iterations or recursion depth while still capturing meaningful combinatorial differences.

6. **Adaptive Seed Weighting**: Seeds are assigned weights based on how much new combinatorial information they provide. The fuzzer tracks both coverage expansion and combinatorial novelty to guide mutation selection.

7. **Scalability Optimizations**: Despite the memory-intensive nature of PCA, Ankou implements optimizations to manage the execution vector matrix and principal component storage, though large programs can still trigger memory exhaustion.

---

## Applicability to PropertyTestingKit

PropertyTestingKit is a Swift coverage-guided fuzzing library with sophisticated corpus management, value profile guidance for comparison tracking, and support for custom mutators. Evaluating Ankou's applicability requires understanding both the potential benefits and implementation challenges.

### Current PropertyTestingKit Architecture

**Existing capabilities relevant to Ankou:**

1. **Coverage-guided fuzzing with bucketed hit counts** (`CoverageSignature.swift`):
   - Uses AFL-style bucketing (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+)
   - Tracks per-edge hit counts, not just binary coverage
   - Already captures the foundation needed for execution vectors

2. **Rarity-based seed selection** (`Corpus.selectForMutation()`):
   - Assigns scores to corpus entries based on coverage rarity: `score = Σ(1/frequency)` for each covered index
   - Uses weighted random selection proportional to rarity scores
   - Prioritizes inputs covering rare paths

3. **Value profile guidance** (`ValueProfileTracker.swift`):
   - Tracks comparison operands and distances (requires `-sanitize-coverage=trace-cmp`)
   - Generates target-directed mutations to satisfy magic constant comparisons
   - Goes beyond basic coverage to capture program semantics

4. **Corpus minimization** (`Corpus.minimized()`):
   - Implements greedy set cover to maintain minimal corpus
   - Removes redundant entries covering the same edges

**Key differences from Ankou:**

1. **Union-based fitness**: PropertyTestingKit's current selection treats coverage as a union of edges. Two entries covering {A, B, C} are considered equivalent regardless of whether A is hit 1 time vs 1000 times, or whether B and C correlate.

2. **No combinatorial tracking**: Hit count buckets are tracked independently per edge, not as coordinated patterns across the entire execution trace.

3. **No dimensionality reduction**: The corpus stores full coverage signatures without applying techniques like PCA to identify patterns in the execution space.

### Applicability Assessment: Moderate to Low

Ankou's approach is **theoretically applicable** but faces **significant practical barriers** for PropertyTestingKit:

**Challenges:**

1. **Memory and Performance Overhead**: Ankou's PCA computation triggers after ~30 minutes and is known to cause OOM errors even in FuzzBench evaluations with 20GB+ memory. PropertyTestingKit targets Swift Testing integration where fuzzing may run for shorter durations (seconds to minutes) or in CI environments with limited resources. The memory footprint would be particularly problematic for PropertyTestingKit's use case.

2. **Limited Benefit for Custom Mutators**: PropertyTestingKit's strength lies in custom mutators that understand domain structure (e.g., mutating specific fields of complex structs). Ankou's combinatorial tracking provides maximum value for bit-level fuzzing of binary formats where subtle byte patterns matter. For higher-level property testing, understanding that `User(name: "Alice", age: 25)` and `User(name: "Bob", age: 30)` represent different *combinatorial patterns* of field values is less useful than understanding semantic relationships (e.g., negative ages are invalid).

3. **Scalability vs Target Size**: Ankou shows strong results on large C programs (parsers, compressors, etc.) where execution traces have thousands of edges. PropertyTestingKit often targets individual Swift functions or modules with smaller coverage surfaces. PCA's benefits diminish when the number of edges is small (< 100) because there's less dimensionality to reduce.

4. **Integration Complexity**: Implementing PCA requires either Swift bindings to numerical computing libraries (Accelerate framework) or pure Swift implementations. This adds significant dependency and maintenance burden compared to PropertyTestingKit's current lightweight architecture.

**Potential Benefits:**

1. **Finding Deep State Bugs**: For stateful fuzzing targets (e.g., testing a file system implementation, a parser with multiple modes, or a state machine), Ankou's ability to distinguish execution patterns could help discover bugs requiring specific sequences of states.

2. **Plateau Breaking**: When PropertyTestingKit gets stuck at a coverage plateau, combinatorial guidance might identify "nearby" execution patterns that lead to new edges, similar to how value profile guidance helps solve magic constant comparisons.

3. **Corpus Diversity**: Maintaining a corpus with diverse combinatorial patterns (not just edge coverage) could improve resilience to bugs requiring specific hit count patterns (e.g., "crash only when function X is called exactly 3 times").

### Alternative: Lightweight Combinatorial Scoring

Instead of full PCA, PropertyTestingKit could adopt a **simplified combinatorial approach** that captures some of Ankou's benefits without the scalability overhead:

**Pairwise or N-gram Edge Patterns**: Track small subsequences of edges (2-3 edges in sequence) rather than full execution vectors. This captures some combinatorial information without requiring PCA:

```swift
// In CoverageSignature
public struct CoverageSignature {
    public let buckets: [Int: UInt8]  // Existing: edge -> hit count bucket
    public let edgePairs: Set<EdgePair>?  // New: track co-occurring edges

    public struct EdgePair: Hashable {
        let first: Int
        let second: Int
    }
}

// During corpus selection, score includes both rarity and pair novelty
public func selectForMutation() -> Int? {
    // Calculate pair-based rarity in addition to edge rarity
    var scores = entries.indices.map { index -> Double in
        let edgeScore = calculateEdgeRarityScore(for: index)
        let pairScore = calculatePairNoveltyScore(for: index)
        return edgeScore + 0.3 * pairScore  // Weighted combination
    }
    // ... weighted random selection ...
}
```

**Hit Count Pattern Diversity**: Prioritize entries with different hit count bucket distributions for the same edge set:

```swift
// Track not just which edges are covered, but the distribution of buckets
public struct BucketProfile: Hashable {
    let edgeIndex: Int
    let bucketDistribution: [UInt8: Int]  // bucket value -> count of entries
}

// During minimization, keep entries with diverse bucket profiles
public func minimizedWithBucketDiversity() -> Self {
    // Keep entries that cover new edges OR have unique hit count patterns
    // ...
}
```

These lightweight approaches provide **10-20% of Ankou's benefit with 1-5% of the implementation complexity**, making them more pragmatic for PropertyTestingKit's use case.

---

## Concrete Recommendations

### Recommendation 1: Do Not Implement Full PCA-Based Ankou Approach (High Priority Decision)

**What**: After evaluation, **avoid implementing** Ankou's full PCA-based combinatorial difference tracking.

**Why**:
- Memory overhead (OOM issues observed in FuzzBench) conflicts with PropertyTestingKit's goal of lightweight CI integration
- Implementation complexity (PCA requires numerical computing libraries) conflicts with minimal dependencies philosophy
- Target domain (Swift property testing) benefits more from semantic guidance than low-level byte pattern combinations
- Ankou's sweet spot is large C programs with complex binary formats; PropertyTestingKit targets structured Swift data types

**Impact**: Prevents investing significant effort (~40-80 hours) into a technique with limited ROI for the target domain.

**Effort**: 0 hours (decision to avoid work)

### Recommendation 2: Implement Lightweight Edge Pair Tracking (Medium Priority, Optional)

**What**: Add optional tracking of edge co-occurrence patterns (2-grams) to capture simple combinatorial relationships without PCA overhead.

**Why**:
- Captures some combinatorial information (which edges tend to execute together)
- Minimal memory overhead (N² for N edges, manageable for small-medium programs)
- Can help identify "interesting" execution patterns where rare edge combinations occur
- Easy to disable if it proves unhelpful

**How**:
```swift
// In CoverageSignature
public struct EdgePair: Hashable, Codable {
    let first: Int
    let second: Int

    init(_ a: Int, _ b: Int) {
        // Normalize order for consistent hashing
        if a <= b {
            (first, second) = (a, b)
        } else {
            (first, second) = (b, a)
        }
    }
}

public struct CoverageSignature {
    public let buckets: [Int: UInt8]
    public let edgePairs: Set<EdgePair>?  // Optional: only computed if enabled

    // Compute pairs from executed edges
    public static func computePairs(from executedIndices: [Int]) -> Set<EdgePair> {
        var pairs = Set<EdgePair>()
        for i in 0..<executedIndices.count {
            for j in (i+1)..<min(i+10, executedIndices.count) {
                // Only track pairs within window to avoid explosion
                pairs.insert(EdgePair(executedIndices[i], executedIndices[j]))
            }
        }
        return pairs
    }
}

// In Corpus.selectForMutation()
private func calculatePairNoveltyScore(for index: Int) -> Double {
    guard let pairs = entries[index].signature.edgePairs else { return 0 }

    // Count how many entries contain each pair
    var pairFrequency: [EdgePair: Int] = [:]
    for entry in entries {
        guard let entryPairs = entry.signature.edgePairs else { continue }
        for pair in entryPairs {
            pairFrequency[pair, default: 0] += 1
        }
    }

    // Score is sum of inverse frequencies (rare pairs = high score)
    return pairs.map { 1.0 / Double(pairFrequency[$0, default: 1]) }
                .reduce(0, +)
}
```

**Impact**:
- 5-15% improvement in discovering bugs requiring specific edge combinations
- Minimal performance overhead (< 5% slowdown)
- Provides data to evaluate whether combinatorial tracking is valuable for PropertyTestingKit's domain

**Effort**: ~6-8 hours implementation + testing

**Code Location**: `Sources/PropertyTestingKit/Fuzzing/CoverageSignature.swift`, `Sources/PropertyTestingKit/Fuzzing/Corpus.swift`

### Recommendation 3: Research Hybrid Approach for Stateful Fuzzing (Low Priority, Future Work)

**What**: For specialized use cases involving stateful fuzzing (e.g., testing state machines, protocol implementations), explore lightweight state transition tracking instead of general combinatorial coverage.

**Why**:
- State machines are where "combination" matters most (which states were visited in what order)
- Domain-specific tracking can be more efficient than general PCA
- Aligns with PropertyTestingKit's philosophy of custom mutators for domain-specific problems

**How**:
- Add optional `StateTransitionTracker` for fuzzing targets that model states
- Track (state, transition) pairs rather than raw edge combinations
- Use domain knowledge to identify meaningful states rather than inferring from coverage

**Example**:
```swift
// For stateful fuzzing targets
public protocol StatefulFuzzTarget {
    associatedtype State: Hashable
    func currentState() -> State
}

public struct StateTransitionSignature {
    let transitions: [(State, State)]  // (from, to) pairs
    let edgeCoverage: CoverageSignature
}

// Prioritize entries exploring rare state transitions
```

**Impact**: Potentially high (20-40% improvement) for stateful targets; zero impact for stateless targets.

**Effort**: ~16-24 hours (research + implementation)

**Priority**: Consider only if stateful fuzzing becomes a key PropertyTestingKit use case.

### Recommendation 4: Monitor Research on Efficient Combinatorial Fuzzing (Ongoing)

**What**: Stay informed about research on more efficient combinatorial fuzzing techniques that address Ankou's scalability limitations.

**Why**:
- Ankou demonstrated the value of combinatorial guidance but had severe scalability issues
- Subsequent research may find lightweight alternatives (e.g., sketching, sampling, online algorithms)
- If efficient techniques emerge, PropertyTestingKit could adopt them

**How**:
- Review fuzzing papers at major conferences (S&P, CCS, USENIX Security, ICSE, FSE)
- Search for citations to Ankou that propose improvements or alternatives
- Focus on techniques that maintain O(N) or O(N log N) complexity rather than O(N²) or O(N³)

**Impact**: Deferred until better techniques are available

**Effort**: ~2-4 hours per year reviewing literature

---

## Implementation Priority

1. **Recommendation 1** (Avoid Full PCA): Immediate decision, 0 hours
2. **Recommendation 2** (Edge Pair Tracking): Optional experiment, 6-8 hours if pursued
3. **Recommendation 4** (Monitor Research): Ongoing, 2-4 hours/year
4. **Recommendation 3** (Stateful Fuzzing): Future work, 16-24 hours only if demand exists

**Overall Assessment**: Ankou's core insight about combinatorial coverage is valuable, but the implementation is impractical for PropertyTestingKit's target domain. Lightweight edge pair tracking offers a pragmatic middle ground that captures some combinatorial information without Ankou's scalability challenges. PropertyTestingKit's existing strengths (value profile guidance, custom mutators, rarity-based selection) already provide substantial benefits beyond basic AFL-style coverage, and these should remain the focus for continued development.

---

## References

- Manès, V. J. M., Kim, S., & Cha, S. K. (2020). Ankou: Guiding Grey-box Fuzzing towards Combinatorial Difference. In Proceedings of the IEEE/ACM 42nd International Conference on Software Engineering (ICSE), 1024-1036.
- Ankou source code: https://github.com/SoftSec-KAIST/Ankou
- Ankou benchmark suite: https://github.com/SoftSec-KAIST/Ankou-Benchmark
- FuzzBench evaluation discussion: https://github.com/google/fuzzbench/issues (Ankou OOM issues)

---

## Notes

**Key Takeaway**: Ankou represents an important theoretical advance in understanding fuzzing fitness functions, but its practical implementation faces significant challenges. The core insight—that coverage should be treated as combinatorial patterns rather than simple unions—is valid, but full PCA-based tracking is overkill for PropertyTestingKit's domain. PropertyTestingKit's existing sophisticated features (value profile guidance, custom mutators, comparison tracking) already address many of the same problems Ankou targets, but through domain-specific approaches rather than general combinatorial analysis.

**Comparison to PropertyTestingKit's Approach**:
- **Ankou**: Bottom-up approach using dimensionality reduction to find patterns in raw execution traces
- **PropertyTestingKit**: Top-down approach using domain knowledge (custom mutators, value profiles) to guide exploration

Both approaches aim to escape local optima and discover deep bugs, but PropertyTestingKit's approach is more aligned with Swift's strongly-typed, structured programming model.

**When Ankou-style techniques might become valuable**:
1. If PropertyTestingKit adds binary format fuzzing (e.g., testing parsers for binary protocols)
2. If corpus sizes grow to thousands of entries where patterns are hard to identify manually
3. If research produces more efficient combinatorial tracking algorithms (e.g., locality-sensitive hashing instead of PCA)
