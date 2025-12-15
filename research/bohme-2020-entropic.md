# Entropic: Boosting Fuzzer Efficiency - An Information Theoretic Perspective

**Paper:** Böhme, Manès, & Cha, "Boosting Fuzzer Efficiency: An Information Theoretic Perspective", ESEC/FSE 2020
**URL:** https://mboehme.github.io/paper/FSE20.Entropy.pdf
**Award:** ACM SIGSOFT Distinguished Paper Award

---

## Paper Summary

Entropic addresses a critical inefficiency in coverage-guided fuzzing: traditional power schedules (like AFL and AFLFast) allocate fuzzing energy based on simplistic heuristics that don't accurately reflect how much a test input teaches us about program behavior. AFL uniformly weights all corpus entries, while AFLFast prioritizes recently discovered or rarely-executed paths. Neither approach formally quantifies the *information content* that an input reveals about unexplored program behaviors.

The key insight of Entropic is to frame fuzzing as a learning process viewed through the lens of information theory. Before fuzzing, we know nothing about a program's behaviors. Each test execution reveals some amount of information - either confirming known behaviors or discovering new ones. Entropic uses Shannon entropy to quantify this information: inputs that exercise globally rare features (those appearing in few corpus entries) provide more information than inputs exercising common features. The paper proves theoretically and demonstrates empirically that efficient fuzzers should maximize information gain.

Entropic implements an entropy-based power schedule that assigns higher mutation energy to seeds revealing more information about rare program features. A "feature" is defined as a (branch, hit-count) pair, making it more fine-grained than simple edge coverage. The algorithm tracks global feature frequencies across the entire corpus and local frequencies within each input. Seeds exercising features with low global frequency receive higher priority for mutation, directing fuzzing effort toward underexplored program behaviors. Implemented in LibFuzzer (363 lines of code), Entropic was evaluated on 250+ open-source programs (60M LoC) and achieved the same coverage as baseline LibFuzzer in less than half the time for most subjects. The technique was independently validated, integrated as LibFuzzer's default power schedule, and now runs on 25,000+ machines fuzzing critical infrastructure.

---

## Key Strategies/Techniques

1. **Shannon Entropy for Feature Rarity**: Uses information theory to quantify how much is learned from each test input. Features appearing rarely across the corpus contribute higher entropy, making seeds that exercise them more valuable for mutation.

2. **Feature-Level Tracking Beyond Edge Coverage**: Defines features as (edge, hit-count) pairs rather than just edge coverage. An edge executed 1 time vs 100 times represents different features, enabling finer-grained coverage distinction.

3. **Global vs Local Feature Frequencies**:
   - **Global frequency**: How often a feature appears across all corpus entries (16-bit saturating counter per feature)
   - **Local frequency**: How often a feature appears within a single input (tracked per corpus entry)
   - Energy is assigned based on the entropy of local frequencies relative to global rarity

4. **Entropy-Based Energy Assignment**: Seeds receive energy proportional to the entropy of their feature distributions. Energy formula uses Shannon entropy with add-one smoothing:
   ```
   Energy = -Σ(LocalFreq * log(LocalFreq)) / SumFreq + log(SumFreq)
   ```
   Higher-entropy seeds (exercising rare features) receive more mutation attempts.

5. **Rare Feature Set Maintenance**: Tracks a dynamic set of "rare features" (those below a frequency threshold, default 0xFF). Only features meeting this threshold contribute to entropy calculations, focusing effort on truly underexplored behaviors.

6. **Weighted Corpus Sampling**: Corpus entries are sampled using a weighted distribution proportional to their energy values. High-energy seeds are selected more frequently for mutation, creating an adaptive feedback loop.

7. **Initial Energy Boosting**: New corpus entries receive maximal initial energy (`log(RareFeatures.size())`) to ensure they get explored. Energy is then recalibrated as execution reveals actual feature distributions.

8. **Parameterized by Abundance Threshold (θ)**: The algorithm includes a tunable threshold determining which features are considered "rare." Features observed less frequently than θ are prioritized for exploration.

---

## Applicability to PropertyTestingKit

**Very High Applicability** - Entropic's information-theoretic approach directly addresses PropertyTestingKit's corpus management and seed selection strategy. The core concepts integrate naturally with the existing architecture.

**Key Finding**: PropertyTestingKit already implements the necessary coverage infrastructure for Entropic, including bucketed hit-count tracking (`CoverageSignature.Bucket`) and frequency-based seed selection. The main enhancement is upgrading from inverse-frequency scoring to proper Shannon entropy calculations.

### Current PropertyTestingKit Architecture

PropertyTestingKit already implements several concepts that make Entropic integration straightforward:

- **Coverage-guided corpus management** (`Corpus.swift`): Tracks coverage signatures and maintains inputs discovering new paths
- **Energy-based seed selection** (`Corpus.selectForMutation()`, lines 228-267): Already implements weighted selection based on feature rarity using a `1/frequency` scoring approach
- **Bucketed hit-count tracking** (`CoverageSignature.swift`, lines 21-86): Implements AFL-style bucketing with 9 buckets (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+), enabling fine-grained feature distinction beyond binary edge coverage
- **Corpus minimization** (`Corpus.minimized()`, lines 180-214): Greedy set-cover algorithm to maintain minimal corpus
- **Feature frequency tracking** (lines 232-237): Calculates index frequency across corpus entries

### Key Observation: PropertyTestingKit Already Implements a Simplified Entropic Schedule

Looking at `Corpus.selectForMutation()` (lines 228-267), PropertyTestingKit already implements a frequency-based weighting scheme that's conceptually similar to Entropic:

```swift
// Calculate how rare each index is
var indexFrequency: [Int: Int] = [:]
for entry in entries {
    for index in entry.signature.executedIndices {
        indexFrequency[index, default: 0] += 1
    }
}

// Score each entry by sum of (1 / frequency) for its indices
var scores = Array(repeating: 0.0, count: entries.count)
for (index, freq) in indexFrequency {
    let contribution = 1.0 / Double(freq)
    for (i, entry) in entries.enumerated() {
        if entry.signature.executedIndices.contains(index) {
            scores[i] += contribution
        }
    }
}
```

This is a simplified version of Entropic's approach: it weights seeds by the sum of inverse feature frequencies. Entropic's enhancement would be to use proper Shannon entropy instead of simple inverse frequency, and to distinguish between local and global feature frequencies.

### Differences from LibFuzzer Context

1. **Counter Granularity**: ✓ PropertyTestingKit already implements Entropic-compatible bucketed hit counts via `CoverageSignature.Bucket`. However, `selectForMutation()` currently discards this information by using only `executedIndices` (binary presence). Simple fix: use (index, bucket) pairs as features instead of just indices.

2. **Iteration Budget**: PropertyTestingKit defaults to 10,000 iterations vs LibFuzzer's potentially millions. Entropy calculations are lightweight (O(corpus_size × features_per_entry)) but the benefit-to-overhead ratio should be validated at this scale.

3. **Swift Testing Integration**: PropertyTestingKit targets Swift Testing framework rather than executable fuzzing. Entropy tracking can be per-test-function rather than per-binary.

4. **No Deterministic Stage**: PropertyTestingKit uses only coverage-guided mutation (no AFL-style deterministic bit flipping stage). Entropic applies to all seed selection decisions.

---

## Concrete Recommendations

### Recommendation 1: Implement True Shannon Entropy for Seed Selection

**Priority: HIGH** - This is the core Entropic contribution and would replace the current simplified frequency-based scoring.

**Current Implementation** (`Corpus.swift`, lines 228-267):
```swift
// Score = Σ(1/frequency) across all features in seed
scores[i] += 1.0 / Double(freq)
```

**Entropic Implementation**:
```swift
// Add to CorpusEntry or Corpus tracking
public struct FeatureProfile: Codable, Sendable {
    /// Local feature frequencies: how often each counter index appears in this input
    public let localFrequencies: [Int: UInt16]

    /// Cached entropy value for this entry
    public private(set) var entropy: Double

    public init(signature: CoverageSignature) {
        // Extract hit counts from signature (currently binary, needs enhancement)
        self.localFrequencies = signature.buckets.mapValues { UInt16($0) }
        self.entropy = 0.0  // Computed later with global context
    }
}

// Enhance Corpus to track global feature frequencies
public struct Corpus<each Input: Codable & Sendable>: Sendable, Codable {
    // ... existing fields ...

    /// Global feature frequency across all corpus entries (saturating 16-bit counters)
    private var globalFeatureFrequency: [Int: UInt16] = [:]

    /// Rare features set (features with frequency < threshold)
    private var rareFeatures: Set<Int> = []

    /// Abundance threshold for rare feature detection (default: 0xFF)
    public var abundanceThreshold: UInt16 = 0xFF

    /// Recompute entropy for all entries based on current global frequencies
    private mutating func recomputeEntropies() {
        // Update rare features set
        rareFeatures = Set(
            globalFeatureFrequency
                .filter { $0.value < abundanceThreshold }
                .keys
        )

        // Recompute entropy for each entry
        for i in entries.indices {
            entries[i].entropy = computeEntropy(
                localFreqs: entries[i].featureProfile.localFrequencies,
                globalFreqs: globalFeatureFrequency,
                rareFeatures: rareFeatures
            )
        }
    }

    /// Compute Shannon entropy with add-one smoothing
    private func computeEntropy(
        localFreqs: [Int: UInt16],
        globalFreqs: [Int: UInt16],
        rareFeatures: Set<Int>
    ) -> Double {
        // Filter to only rare features for efficiency
        let relevantFeatures = localFreqs.keys.filter { rareFeatures.contains($0) }
        guard !relevantFeatures.isEmpty else { return 1.0 }

        var sumIncidence: UInt32 = 0
        var entropyAccum: Double = 0.0

        for featureIdx in relevantFeatures {
            let localCount = UInt32(localFreqs[featureIdx] ?? 0)
            // Add-one smoothing
            let smoothedCount = localCount + 1
            sumIncidence += smoothedCount
        }

        guard sumIncidence > 0 else { return 1.0 }

        // Shannon entropy: -Σ(p_i * log(p_i))
        for featureIdx in relevantFeatures {
            let localCount = UInt32(localFreqs[featureIdx] ?? 0)
            let smoothedCount = Double(localCount + 1)
            let probability = smoothedCount / Double(sumIncidence)
            if probability > 0 {
                entropyAccum -= probability * log2(probability)
            }
        }

        // Add log(sumIncidence) term for normalization
        return entropyAccum + log2(Double(sumIncidence))
    }

    /// Enhanced selection using entropy-based weights
    public func selectForMutation() -> Int? {
        guard !entries.isEmpty else { return nil }

        // Use entropy values as selection weights
        let weights = entries.map { max($0.entropy, 0.1) }  // Min weight for exploration
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return entries.indices.randomElement() }

        var random = Double.random(in: 0..<totalWeight)
        for (i, weight) in weights.dropLast().enumerated() {
            random -= weight
            if random <= 0 {
                return i
            }
        }
        return weights.count - 1
    }
}
```

**Integration**: Modify `Corpus.addIfInteresting()` and `Corpus.add()` to update global feature frequencies and recompute entropies after each addition. Use sparse updates (only recompute every N additions) to manage overhead.

### Recommendation 2: Leverage Existing Hit-Count Tracking in CoverageSignature

**Priority: HIGH** - Entropic requires (edge, hit-count) pairs, not just binary coverage.

**Status: ALREADY IMPLEMENTED** ✓ - PropertyTestingKit already tracks hit counts through bucketed counters!

**Current Implementation**: `CoverageSignature` in `CoverageSignature.swift` (lines 21-86) already implements AFL-style bucketed hit counts with 9 buckets (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+). Features are implicitly (index, bucket) pairs stored in the `buckets` dictionary.

**What's Available**: The infrastructure is in place. The main adjustment needed is to:

```swift
// In Corpus.swift - Modify selectForMutation() to use (index, bucket) pairs as features
// instead of just index presence

public func selectForMutation() -> Int? {
    guard !entries.isEmpty else { return nil }

    // Calculate how rare each (index, bucket) feature is
    var featureFrequency: [Feature: Int] = [:]
    for entry in entries {
        for (index, bucket) in entry.signature.buckets {
            let feature = Feature(index: index, bucket: bucket)
            featureFrequency[feature, default: 0] += 1
        }
    }

    // Score each entry by sum of (1 / frequency) for its features
    var scores = Array(repeating: 0.0, count: entries.count)
    for (feature, freq) in featureFrequency {
        let contribution = 1.0 / Double(freq)
        for (i, entry) in entries.enumerated() {
            if let bucket = entry.signature.buckets[feature.index], bucket == feature.bucket {
                scores[i] += contribution
            }
        }
    }

    // ... rest of weighted selection logic unchanged ...
}

// Feature type for tracking (index, bucket) pairs
private struct Feature: Hashable {
    let index: Int
    let bucket: CoverageSignature.Bucket
}
```

**Impact**: This simple change leverages the existing hit-count infrastructure to distinguish between "edge executed once" vs "edge executed in loop 100 times" as different program behaviors. Currently, `selectForMutation()` only uses `executedIndices` (line 234), which discards the bucket information.

### Recommendation 3: Add Entropy-Based Configuration Options

**Priority: MEDIUM** - Allow users to tune Entropic parameters.

```swift
// Add to FuzzEngine.Config (around line 129 in FuzzEngine.swift)
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable Entropic power schedule (entropy-based seed selection)
    /// When disabled, falls back to simple frequency-based selection
    public var enableEntropic: Bool

    /// Abundance threshold for rare feature detection
    /// Features observed less than this many times are considered "rare"
    /// Default: 0xFF (255) matches LibFuzzer's implementation
    public var entropicAbundanceThreshold: UInt16

    /// How often to recompute entropy values (every N corpus additions)
    /// Lower = more accurate, higher = less overhead
    /// Default: 100 (recompute after every 100 new corpus entries)
    public var entropicUpdateInterval: Int

    public init(
        // ... existing parameters ...
        enableEntropic: Bool = true,
        entropicAbundanceThreshold: UInt16 = 0xFF,
        entropicUpdateInterval: Int = 100
    ) {
        // ... existing assignments ...
        self.enableEntropic = enableEntropic
        self.entropicAbundanceThreshold = entropicAbundanceThreshold
        self.entropicUpdateInterval = entropicUpdateInterval
    }
}
```

### Recommendation 4: Implement Sparse Entropy Updates

**Priority: MEDIUM** - Manage computational overhead of entropy recalculation.

**Implementation**: Track corpus additions and only recompute entropy periodically:

```swift
// Add to Corpus
private var additionsSinceLastEntropyUpdate = 0

public mutating func addIfInteresting(
    input: repeat each Input,
    signature: CoverageSignature,
    parentIndex: Int? = nil
) -> Bool {
    guard signature.hasUniqueCoverage(comparedTo: totalCoverage) else {
        return false
    }

    let entry = CorpusEntry(
        input: repeat each input,
        signature: signature,
        featureProfile: FeatureProfile(signature: signature),
        parentIndex: parentIndex
    )
    entries.append(entry)

    // Update global feature frequencies
    for (featureIdx, count) in signature.buckets {
        let currentFreq = globalFeatureFrequency[featureIdx] ?? 0
        // Saturating increment (cap at UInt16.max)
        globalFeatureFrequency[featureIdx] = min(currentFreq + 1, UInt16.max)
    }

    totalCoverage = totalCoverage.union(with: signature)
    updatedAt = Date()
    additionsSinceLastEntropyUpdate += 1

    // Sparse entropy updates: only recompute every N additions
    if additionsSinceLastEntropyUpdate >= entropicUpdateInterval {
        recomputeEntropies()
        additionsSinceLastEntropyUpdate = 0
    }

    return true
}
```

**Rationale**: Entropy recalculation is O(corpus_size × features_per_entry). For large corpora, computing after every addition is wasteful. LibFuzzer uses lazy updates with similar logic.

### Recommendation 5: Add Entropy Statistics and Logging

**Priority: LOW** - Visibility into Entropic's effectiveness.

```swift
// Add to FuzzEngine verbose logging (around line 747 in FuzzEngine.swift)
if config.verbose && config.enableEntropic {
    let avgEntropy = corpus.entries.map(\.entropy).reduce(0, +) / Double(corpus.count)
    let maxEntropy = corpus.entries.map(\.entropy).max() ?? 0
    let rareFeatureCount = corpus.rareFeatures.count

    print("[Fuzz] Entropic stats:")
    print("[Fuzz]   Rare features: \(rareFeatureCount)")
    print("[Fuzz]   Avg entropy: \(String(format: "%.2f", avgEntropy))")
    print("[Fuzz]   Max entropy: \(String(format: "%.2f", maxEntropy))")
}
```

---

## Implementation Priority

**Phase 1: Core Entropic (Immediate Value)**
1. **Recommendation 2**: Use (index, bucket) pairs as features in `selectForMutation()` - leverages existing hit-count infrastructure (simple change to line 234-236 in Corpus.swift)
2. **Recommendation 1**: Shannon entropy calculation for seed selection - core algorithm

**Phase 2: Optimization (After Initial Validation)**
3. **Recommendation 4**: Sparse entropy updates - manage overhead
4. **Recommendation 3**: Configuration options - tuning knobs

**Phase 3: Observability (Nice to Have)**
5. **Recommendation 5**: Entropy statistics logging - debugging and analysis

**Note**: Hit-count tracking is already implemented via `CoverageSignature.Bucket`, making Entropic integration much simpler than initially anticipated. The main work is adding proper Shannon entropy calculations rather than building new coverage infrastructure.

---

## Expected Benefits

Based on Entropic's published results and PropertyTestingKit's architecture:

1. **Faster Coverage Discovery**: Entropic achieved same coverage as baseline LibFuzzer in < 50% of the time. PropertyTestingKit's 10k iteration / 60s time budget means this could translate to discovering the same paths in ~30s or 5k iterations.

2. **Better Corpus Quality**: Entropy-based selection naturally prioritizes diverse behaviors over redundant paths, leading to higher-quality corpus entries that cover different program states.

3. **Improved Bug Finding**: By focusing on rare features (underexplored program regions), Entropic tends to discover more crashes and edge cases in less time.

4. **Complementary to Existing Features**: Entropic works alongside PropertyTestingKit's existing value profile guidance, string dictionaries, and arithmetic mutations. These features generate interesting mutations; Entropic ensures we explore them efficiently.

5. **Minimal Overhead**: LibFuzzer's Entropic implementation added only 363 lines of code and < 5% runtime overhead. PropertyTestingKit should see similar efficiency.

---

## Potential Challenges

1. **Hit-Count Extraction**: ✓ RESOLVED - PropertyTestingKit already implements bucketed hit-count tracking through `CoverageSignature.Bucket` enum with 9 buckets (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+). The infrastructure is in place; we just need to use the (index, bucket) pairs instead of just indices.

2. **Feature Space Size**: Using (edge, hit-count) pairs increases feature space by ~9x due to bucket count. With 9 buckets per edge, a program with 10k edges has 90k potential features. However, PropertyTestingKit already stores this data efficiently (sparse `[Int: Bucket]` dictionary in each signature). Global frequency tracking will need similar sparse storage with saturating counters.

3. **Corpus Serialization**: Adding `FeatureProfile` and entropy values to `CorpusEntry` increases corpus.json file size. Consider separate metadata files or compressed storage for large corpora.

4. **Entropy Computation Cost**: Shannon entropy requires logarithms and floating-point operations. With sparse updates (Recommendation 4), this should be negligible, but profiling is recommended.

5. **Integration with Value Profile**: PropertyTestingKit already prioritizes inputs making comparison progress (`priorityMutationIndex`, lines 199-203). Need to decide interaction: should value profile override entropy weighting? Combine scores? Current approach of "prioritize VP progress when available, otherwise use entropy" is probably correct.

6. **Small Iteration Budgets**: With only 10k iterations, PropertyTestingKit spends less total time fuzzing than LibFuzzer campaigns. Entropy calculation overhead as a % of total runtime may be higher. Mitigation: use sparse updates (every 100 additions) and lazy entropy recalculation.

---

## Synergy with Existing PropertyTestingKit Features

Entropic complements PropertyTestingKit's existing advanced features:

1. **Value Profile Guidance** (lines 149-151, 545-548 in `FuzzEngine.swift`): Value profile tracks comparison distances and generates target-directed mutations. Entropic handles *which seed to mutate*, value profile handles *how to mutate it*. These are orthogonal and synergistic.

2. **String Dictionary Capture** (lines 154-156, 1079-1135): Captures magic strings at runtime for dictionary-based mutations. Entropic ensures seeds exercising code paths that check magic strings get prioritized, while string dictionary provides the actual values to satisfy those checks.

3. **Arithmetic Relationship Mutations** (lines 993-1047): Generates mutations solving constraints like `a + b == target`. Entropic prioritizes seeds that exercise the branches containing such constraints, directing arithmetic mutations toward relevant code paths.

4. **Corpus Minimization** (lines 180-214): Greedy set-cover to maintain minimal corpus. This is *complementary* to Entropic - minimization reduces corpus size, Entropic ensures each remaining entry is selected with appropriate probability. Both improve efficiency.

---

## References

- Böhme, M., Manès, V.J.M., and Cha, S.K., "Boosting Fuzzer Efficiency: An Information Theoretic Perspective", ESEC/FSE 2020
- LLVM LibFuzzer Entropic Implementation: https://github.com/llvm/llvm-project/commit/e2e38fca64e49d684de0b100437fe2f227f8fcdd
- LLVM Review (D73776): https://reviews.llvm.org/D73776
- Paper PDF: https://mboehme.github.io/paper/FSE20.Entropy.pdf
- FigShare Dataset: https://figshare.com/articles/dataset/FSE2020_-_Boosting_Fuzzer_Efficiency_An_Information-Theoretic_Perspective/12415622
