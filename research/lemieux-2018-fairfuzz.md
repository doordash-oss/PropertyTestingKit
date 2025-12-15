# FairFuzz: A Targeted Mutation Strategy for Increasing Greybox Fuzz Testing Coverage

**Paper:** Lemieux & Sen, "FairFuzz: A Targeted Mutation Strategy for Increasing Greybox Fuzz Testing Coverage", ASE 2018

**URLs:**
- https://www.carolemieux.com/fairfuzz-ase18.pdf
- https://people.eecs.berkeley.edu/~ksen/papers/fairfuzz.pdf
- https://arxiv.org/abs/1709.07101

**Implementation:** https://github.com/carolemieux/afl-rb

---

## Paper Summary

FairFuzz addresses a fundamental limitation in coverage-guided fuzzing: the unequal distribution of testing effort across program branches. Traditional greybox fuzzers like AFL discover many code paths but allocate fuzzing resources uniformly across all discovered branches. This creates an imbalance where frequently-executed branches receive the majority of fuzzing attempts while rarely-executed branches - which often guard complex logic and are more likely to contain vulnerabilities - remain underexplored. In programs with nested conditional structures, this disparity becomes severe: common error-handling paths may receive thousands of test inputs while deep program logic protected by magic constants or keyword sequences receives only a handful.

FairFuzz introduces a two-pronged approach to rebalance fuzzing effort toward underexplored code. First, it identifies "rare branches" using a dynamic power-of-two threshold based on the minimum hit count across all discovered branches. If the least-covered branch is hit by 19 inputs in the current corpus, any branch hit by ≤32 inputs is classified as rare (the next power of two). Second, FairFuzz employs a novel mutation mask algorithm that biases mutations toward preserving rare branch execution. When mutating an input that hits rare branches, FairFuzz computes a mask indicating which byte positions can be modified (overwritten, deleted, or inserted) while maintaining the rare branch hit. This mask is computed dynamically during fuzzing by testing each byte position to determine whether modifications preserve the target branch execution. During AFL's havoc mutation stage, only positions within the mask are mutated, concentrating fuzzing effort on input regions that directly influence rare branch execution without disrupting the constraints that enable reaching those branches.

Experimental evaluation on nine real-world C programs demonstrates FairFuzz's effectiveness at rapidly increasing branch coverage compared to state-of-the-art AFL variants. On programs with deeply nested conditionals - including packet analyzers (tcpdump), file format parsers (readpng, djpeg), and XML processors (xmllint) - FairFuzz achieves sustained coverage improvements over 24-hour runs with an average 10.6% increase in branch coverage. The approach proves particularly effective at discovering magic strings and keyword sequences: on xmllint, FairFuzz generated 2,124 hits on a specific rare branch compared to only 18 for vanilla AFL, demonstrating superior ability to explore nested program structures. The implementation adds approximately 600 lines of C code to AFL and introduces minimal runtime overhead through efficient incremental mask computation during AFL's existing deterministic mutation stages.

---

## Key Strategies/Techniques

1. **Dynamic Power-of-Two Rare Branch Threshold**: Implements a self-adjusting rarity definition where the threshold is the smallest power of two greater than or equal to the minimum hit count across all discovered branches. This creates a dynamic classification that evolves as fuzzing progresses - early in fuzzing when few inputs exist, more branches are rare; as the corpus grows, the threshold rises, focusing effort on increasingly underexplored code.

2. **Incremental Hit Count Tracking**: Maintains a counter array tracking how many corpus inputs execute each discovered branch. After running each test input, FairFuzz increments counters for all branches executed, enabling O(1) rarity classification without expensive reanalysis. This lightweight tracking adds negligible overhead to AFL's existing branch coverage infrastructure.

3. **Three-Part Mutation Mask Computation**: For each input hitting rare branches, computes a comprehensive mask during AFL's deterministic mutation stages:
   - **Overwritable positions**: Discovered during byte-flip stage by testing whether flipping each byte preserves the target branch hit
   - **Deletable positions**: Computed in a new deterministic stage by testing whether deleting each byte maintains branch coverage
   - **Insertable positions**: Determined by testing whether inserting random bytes at each position preserves the rare branch
   The mask computation piggybacks on AFL's existing deterministic stages, amortizing cost across mutations.

4. **Havoc Stage Mutation Masking**: Restricts all AFL havoc mutations (bit flips, byte swaps, arithmetic operations, block insertions) to positions designated as modifiable by the branch mask. When the mask indicates bytes 10-15 are critical for rare branch execution, havoc mutations avoid those positions entirely, preventing the fuzzer from accidentally destroying the constraints needed to reach rare code.

5. **Dynamic Mask Synchronization**: As mutations insert or delete bytes, FairFuzz updates the branch mask to maintain alignment with the mutated input. Insertions extend the mask to mark new positions as modifiable; deletions compress the mask by removing corresponding regions. This ensures mask validity throughout multi-operation mutation sequences in havoc mode.

6. **Rare-Branch-Only Input Selection**: Modifies AFL's queue processing to prioritize (or exclusively select) inputs hitting rare branches. When an input hits multiple rare branches, FairFuzz designates the rarest one (lowest hit count) as the mutation target, ensuring effort focuses on the most underexplored code first. Inputs hitting no rare branches are skipped during queue traversal unless bootstrap fallback modes are enabled.

7. **Target-Preserving Input Trimming**: Optionally (with `-r` flag) applies AFL's trimming algorithm while preserving target rare branch execution. This produces smaller inputs that maintain rare branch coverage, reducing mutation space and making inputs more amenable to further fuzzing. Unlike vanilla AFL trimming (which preserves full path), FairFuzz trimming only requires preserving the specific rare branch hit.

8. **Bootstrap Fallback Mechanisms**: Provides three bootstrap modes (via `-q` flags) to prevent stalling when rare branch progress plateaus:
   - `-q 1`: Falls back to standard AFL behavior when no new rare branches are discovered for a period
   - `-q 2`: More aggressive time-based switching between FairFuzz and AFL modes
   - `-q 3`: Most aggressive alternation, cycling between focused rare branch targeting and broad exploration
   These modes balance exploration (finding new branches) and exploitation (thoroughly exploring rare branches).

9. **Efficient Mask Representation**: Stores masks as compact bitarrays indicating modifiable positions, enabling O(1) mask lookups during havoc mutations. This representation minimizes memory overhead even for large inputs while maintaining fast mutation operations.

10. **Rarest-Branch Prioritization**: When selecting which rare branch to target for an input hitting multiple rare branches, FairFuzz always chooses the branch with the lowest hit count. This "fairness" principle ensures the most neglected code receives attention first, creating a natural priority queue that equalizes coverage distribution.

---

## Applicability to PropertyTestingKit

**High Applicability with Swift-Specific Adaptations** - FairFuzz's core concepts translate well to PropertyTestingKit's coverage-guided fuzzing, though implementation approaches must account for Swift's type safety and PropertyTestingKit's semantic mutation model.

### Current PropertyTestingKit Architecture Analysis

PropertyTestingKit has several foundations that align with FairFuzz:

**Coverage Infrastructure** (`FuzzEngine.swift`, `Corpus.swift`):
- Coverage signature tracking via LLVM counter indices (`CoverageSignature`)
- Corpus management with deduplication based on coverage uniqueness
- Corpus minimization using greedy set cover algorithm
- Already implements energy-based seed selection (`Corpus.selectForMutation()`) that scores inputs by inverse frequency of covered indices - conceptually similar to FairFuzz but applied at input selection rather than mutation masking

**Advanced Guidance Systems**:
- **Value profile tracking** (`ValueProfile.swift`): Monitors comparison operand distances and prioritizes inputs making progress toward solving comparisons (e.g., getting closer to `x == 12345`)
- **String dictionary capture** (`StringDictionary.swift`): Runtime collection of magic strings for dictionary-based mutation
- **Priority mutation chains** (`FuzzEngine.priorityMutationIndex`): Tracks entries that made value profile progress and prioritizes continued mutation to follow the chain

**Semantic Mutation Model**:
- Type-safe mutations via `Fuzzable` protocol conformance
- Custom mutators with domain-specific strategies (`Mutator` types)
- Multi-component mutations for variadic inputs
- Arithmetic relationship mutations for integer pairs
- String dictionary-based mutations for magic string discovery

### Adaptation Strategies for FairFuzz Concepts

**1. Rare Branch Identification (Direct Translation)**

FairFuzz's rare branch threshold can be directly implemented using PropertyTestingKit's existing `CoverageSignature` infrastructure:

```swift
// Add to FuzzEngine.swift around line 192
public final class FuzzEngine<each Input: Fuzzable & Codable & Sendable>: @unchecked Sendable {
    // ... existing fields ...

    /// Tracks rare branch statistics
    private var rareBranchTracker: RareBranchTracker?

    // In init():
    if config.enableRareBranchTargeting {
        self.rareBranchTracker = RareBranchTracker()
    }
}

// New type (add to Corpus.swift after line 320)
public struct RareBranchTracker: Sendable {
    /// Maps counter index -> number of corpus entries hitting it
    private var indexHitCounts: [Int: Int] = [:]

    /// Current rarity threshold (power of 2)
    private var currentThreshold: Int = 1

    /// Update hit counts from corpus
    public mutating func update<each Input: Codable & Sendable>(
        from corpus: Corpus<repeat each Input>
    ) {
        indexHitCounts.removeAll()
        for entry in corpus.entries {
            for index in entry.signature.executedIndices {
                indexHitCounts[index, default: 0] += 1
            }
        }
        currentThreshold = computeThreshold()
    }

    /// Compute FairFuzz power-of-two threshold
    private func computeThreshold() -> Int {
        guard let minHits = indexHitCounts.values.min(), minHits > 0 else { return 1 }
        var threshold = 1
        while threshold < minHits {
            threshold *= 2
        }
        return threshold
    }

    /// Get set of rare counter indices
    public func rareIndices() -> Set<Int> {
        Set(indexHitCounts.filter { $0.value <= currentThreshold }.keys)
    }

    /// Statistics for reporting
    public func stats() -> (rare: Int, total: Int, threshold: Int) {
        let rare = rareIndices().count
        let total = indexHitCounts.count
        return (rare, total, currentThreshold)
    }
}
```

**Integration Point**: Update tracker after corpus additions in `FuzzEngine.runFuzzing()` around line 743-760.

**2. Rare-Branch-Focused Input Selection (Strategic Enhancement)**

Extend `Corpus.selectForMutation()` with rare branch awareness:

```swift
// Extend Corpus around line 228
extension Corpus {
    /// Select entry for mutation, optionally prioritizing rare branch coverage
    public func selectForMutation(
        rareIndices: Set<Int>? = nil,
        rareBranchProbability: Double = 1.0
    ) -> Int? {
        guard !entries.isEmpty else { return nil }

        // FairFuzz mode: try rare branch selection
        if let rareIndices = rareIndices,
           !rareIndices.isEmpty,
           Double.random(in: 0..<1) < rareBranchProbability {

            // Find entries hitting rare branches
            var scores: [(index: Int, score: Double)] = []
            for (idx, entry) in entries.enumerated() {
                let rareHits = entry.signature.executedIndices.intersection(rareIndices)
                if !rareHits.isEmpty {
                    // Score by number of rare branches (prefer entries hitting more rare branches)
                    // Weight by inverse frequency (prefer rarer branches)
                    let score = Double(rareHits.count)
                    scores.append((idx, score))
                }
            }

            if !scores.isEmpty {
                return weightedRandomSelection(from: scores)
            }
            // Fall through to standard selection if no rare hits
        }

        // Standard energy-based selection
        return energyBasedSelection()
    }

    private func energyBasedSelection() -> Int? {
        // ... existing implementation from line 229-266 ...
    }

    private func weightedRandomSelection(from scores: [(index: Int, score: Double)]) -> Int? {
        let totalScore = scores.reduce(0.0) { $0 + $1.score }
        guard totalScore > 0 else { return scores.randomElement()?.index }

        var random = Double.random(in: 0..<totalScore)
        for (idx, score) in scores.dropLast() {
            random -= score
            if random <= 0 { return idx }
        }
        return scores.last?.index
    }
}
```

**Integration**: Modify seed selection in `FuzzEngine.runFuzzing()` around line 658-666 to pass rare indices.

**3. Semantic Mutation Prioritization (Swift-Adapted Concept)**

Instead of byte-level mutation masking (incompatible with Swift's type safety), implement component-level prioritization:

```swift
// Add to FuzzEngine around line 669
private func mutateInput(
    _ input: (repeat each Input),
    targetingRareIndices rareIndices: Set<Int>? = nil
) -> [(repeat each Input)] {
    var results: [(repeat each Input)] = []

    if let rareIndices = rareIndices, !rareIndices.isEmpty {
        // When targeting rare branches, apply focused mutation strategies:
        // 1. Generate more mutations per component (amplification)
        // 2. Prefer conservative mutations (less likely to break constraints)
        results.append(contentsOf: conservativeMutations(input))
    }

    // Standard mutations (single-component, multi-component, arithmetic, dictionary)
    results.append(contentsOf: standardMutations(input))

    return results
}

private func conservativeMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
    var results: [(repeat each Input)] = []

    // For each component, generate small perturbations
    var componentIndex = 0
    func tryConservativeMutate<U: Fuzzable>(_ value: U, atIndex index: Int) {
        // Generate only the "closest" mutations (±1, flip, etc.)
        let conservativeMutations = value.mutate().prefix(3) // Limit to smallest changes
        for mutated in conservativeMutations {
            if let newTuple = createMutatedTuple(input, mutating: index, with: mutated) {
                results.append(newTuple)
            }
        }
        componentIndex += 1
    }

    componentIndex = 0
    (repeat tryConservativeMutate(each input, atIndex: componentIndex))

    return results
}
```

**4. Rare-Branch Mutation Amplification (Lightweight Enhancement)**

When an input hits rare branches, test multiple mutations instead of just one:

```swift
// Add to FuzzEngine.Config around line 129
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable FairFuzz-style rare branch targeting
    public var enableRareBranchTargeting: Bool

    /// Number of mutations to test when targeting rare branches (vs. 1 normally)
    public var rareBranchMutationAmplification: Int

    /// Probability of selecting rare-branch-hitting inputs
    public var rareBranchSelectionProbability: Double

    public init(
        // ... existing parameters ...
        enableRareBranchTargeting: Bool = false,
        rareBranchMutationAmplification: Int = 5,
        rareBranchSelectionProbability: Double = 0.8
    ) {
        // ... existing assignments ...
        self.enableRareBranchTargeting = enableRareBranchTargeting
        self.rareBranchMutationAmplification = rareBranchMutationAmplification
        self.rareBranchSelectionProbability = rareBranchSelectionProbability
    }
}

// In mutation loop (FuzzEngine.runFuzzing() around line 654-703)
let isTargetingRareBranch = config.enableRareBranchTargeting
    && rareBranchTracker?.let { tracker in
        let rareIndices = tracker.rareIndices()
        !corpus.entries[selectedIndex].signature.executedIndices.intersection(rareIndices).isEmpty
    } ?? false

// Generate and test multiple mutations for rare branch entries
let mutationsToTry = isTargetingRareBranch ? config.rareBranchMutationAmplification : 1
var testedThisEntry = 0

while testedThisEntry < mutationsToTry && iteration < config.maxIterations {
    var mutations = mutatorMutate?(parent) ?? mutateInput(parent, targetingRareIndices: rareIndices)
    guard let mutated = mutations.randomElement() else { break }

    // Test mutation (existing code around line 710-760)
    // ...

    testedThisEntry += 1
    iteration += 1

    // Early exit if we found new coverage
    if addedForCoverage {
        break
    }
}
```

**5. Integration with Value Profile Guidance (Synergistic Combination)**

PropertyTestingKit's value profile and FairFuzz's rare branches address complementary challenges:
- **Value profile**: Solves comparison constraints (`if x == magic_constant`)
- **Rare branches**: Reaches the comparison in the first place by focusing on underexplored paths

Combined strategy:

```swift
// In FuzzEngine.runFuzzing() around line 599-615
let vpImprovements = config.enableValueProfile ? valueProfileTracker.processComparisons() : []

if let beforeSnapshot = before, let afterSnapshot = coverageCounters.snapshot() {
    let diff = afterSnapshot.difference(from: beforeSnapshot)
    let signature = CoverageSignature(diff: diff)
    let addedForCoverage = corpus.addIfInteresting(input: repeat each input, signature: signature)

    // Determine if this input should be prioritized
    let hitsRareBranches = rareBranchTracker.map { tracker in
        !signature.executedIndices.intersection(tracker.rareIndices()).isEmpty
    } ?? false

    let madeVPProgress = !vpImprovements.isEmpty

    if addedForCoverage {
        iterationsSinceNewCoverage = 0
        if config.verbose {
            print("[Fuzz] New coverage: \(corpus.count) entries, rare=\(hitsRareBranches), vp=\(madeVPProgress)")
        }
    } else if madeVPProgress || hitsRareBranches {
        // Input didn't discover new edges but either:
        // - Made progress on comparisons (value profile)
        // - Hit rare branches (FairFuzz)
        // Add to corpus to preserve for targeted mutation
        corpus.add(input: repeat each input, signature: signature)

        // Prioritize based on which guidance triggered
        if madeVPProgress && hitsRareBranches {
            // Highest priority: both value profile and rare branches
            priorityMutationIndex = corpus.count - 1
            savedTargets = valueProfileTracker.extractTargets()
        } else if madeVPProgress {
            // Value profile priority (existing behavior)
            priorityMutationIndex = corpus.count - 1
            savedTargets = valueProfileTracker.extractTargets()
        } else if hitsRareBranches {
            // Rare branch priority (new)
            priorityMutationIndex = corpus.count - 1
        }

        iterationsSinceNewCoverage = 0
    }
}
```

### Techniques That Don't Apply Directly

**1. Byte-Level Mutation Masking**

FairFuzz's core innovation - restricting havoc mutations to byte positions that preserve rare branch hits - doesn't translate to PropertyTestingKit's semantic mutation model. PropertyTestingKit mutates typed Swift values (`String.mutate()`, `Int.mutate()`) rather than raw bytes. Computing equivalent masks would require:
- Testing each component/field mutation individually
- Re-running the test function multiple times per mask computation
- Dealing with side effects in test functions

**Alternative**: Use component-level prioritization (mutate some tuple components more frequently than others) based on heuristics rather than exhaustive masking.

**2. Deterministic Mutation Stage Integration**

AFL's mutation process has distinct deterministic (bit flips, arithmetic, dictionary) and havoc (random stacked) stages. FairFuzz computes masks during deterministic stages to use in havoc. PropertyTestingKit's mutation model is more uniform - all mutations come from `Fuzzable.mutate()` or custom mutators. There's no equivalent "deterministic stage" to piggyback mask computation onto.

**Alternative**: Compute simplified heuristic masks on-demand when selecting rare-branch entries, or skip masking entirely in favor of amplification and selection strategies.

**3. AFL-Specific Bootstrap Modes**

FairFuzz's bootstrap modes (`-q 1/2/3`) are tuned for AFL's specific queue processing and energy scheduling. PropertyTestingKit's fuzzing loop structure is different (no queue cycling, different energy model).

**Alternative**: Implement simpler fallback logic: if no rare branch progress for N iterations, temporarily switch to standard selection.

---

## Concrete Recommendations

### Recommendation 1: Add Rare Branch Tracking and Metrics

**Priority**: High
**Effort**: Low (~100 lines)
**Value**: Provides visibility into coverage imbalance with minimal risk

**Implementation**:

```swift
// Add RareBranchTracker to FuzzEngine (see "Adaptation Strategies" section above)

// Update FuzzEngine.Config to enable tracking
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable rare branch tracking and reporting
    public var trackRareBranches: Bool

    public init(
        // ... existing parameters ...
        trackRareBranches: Bool = false
    ) {
        // ... existing assignments ...
        self.trackRareBranches = trackRareBranches
    }
}

// Initialize tracker in FuzzEngine.init()
if config.trackRareBranches {
    self.rareBranchTracker = RareBranchTracker()
}

// Report statistics in runFuzzing() around line 765-775
if config.verbose && config.trackRareBranches {
    rareBranchTracker?.update(from: corpus)
    if let (rare, total, threshold) = rareBranchTracker?.stats() {
        let pctRare = total > 0 ? (Double(rare) / Double(total) * 100) : 0
        print("[Fuzz] Rare branches: \(rare)/\(total) (\(String(format: "%.1f", pctRare))%, threshold: \(threshold))")
    }
}

// Also report in FuzzStats
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Number of rare branches discovered
    public let rareBranches: Int?

    /// Rare branch threshold used
    public let rareBranchThreshold: Int?
}
```

**Environment Variable**: Add `FUZZ_TRACK_RARE_BRANCHES=1` support.

**Testing**: Run on `StressTests/FuzzerStressTests.swift` to measure rare branch statistics on challenging targets.

### Recommendation 2: Implement Rare-Branch-Preferring Input Selection

**Priority**: High
**Effort**: Medium (~200 lines including configuration)
**Value**: Core FairFuzz technique with proven effectiveness

**Implementation**:

```swift
// Enable rare branch targeting in Config (see "Adaptation Strategies" section)
public var enableRareBranchTargeting: Bool = false
public var rareBranchSelectionProbability: Double = 0.8

// Extend Corpus.selectForMutation() with rare branch support (see above)

// Update FuzzEngine selection logic around line 654-666
else {
    // Mutate existing corpus entry
    let rareIndices = rareBranchTracker?.rareIndices()
    let selectedIndex: Int

    if config.enableRareBranchTargeting {
        // FairFuzz mode: prefer rare-branch-hitting entries
        selectedIndex = corpus.selectForMutation(
            rareIndices: rareIndices,
            rareBranchProbability: config.rareBranchSelectionProbability
        )!
    } else {
        // Standard energy-based selection
        selectedIndex = corpus.selectForMutation()!
    }

    if config.verbose && rareIndices != nil {
        let entry = corpus.entries[selectedIndex]
        let rareHits = entry.signature.executedIndices.intersection(rareIndices!)
        if !rareHits.isEmpty {
            print("[Fuzz] Selected entry hitting \(rareHits.count) rare branches")
        }
    }

    // ... continue with mutation ...
}
```

**Environment Variables**:
- `FUZZ_RARE_BRANCH_TARGETING=1`: Enable feature
- `FUZZ_RARE_BRANCH_PROBABILITY=0.8`: Adjust selection probability

**Validation**: Compare coverage curves with/without rare branch targeting on nested conditional functions.

### Recommendation 3: Add Mutation Amplification for Rare Branch Entries

**Priority**: Medium
**Effort**: Low (~75 lines)
**Value**: Increases exploration from rare-branch seeds without expensive masking

**Implementation**:

```swift
// Configure amplification factor in Config
public var rareBranchMutationAmplification: Int = 5

// In mutation loop (see "Adaptation Strategies" section above)
// Test multiple mutations when targeting rare branches

// Track amplification in FuzzStats
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Mutations performed on rare-branch-hitting entries
    public let rareBranchMutations: Int
}
```

**Rationale**: Testing 5 mutations from a rare-branch seed is more effective than testing 1 mutation from 5 different seeds when trying to explore underexplored code.

### Recommendation 4: Implement Fallback for Rare Branch Plateau

**Priority**: Medium
**Effort**: Low (~50 lines)
**Value**: Prevents pathological cases where rare branch targeting stalls

**Implementation**:

```swift
// Track rare branch progress in FuzzEngine
private var iterationsSinceRareBranchProgress = 0
private var lastRareBranchCount = 0

// After corpus updates around line 745
if config.enableRareBranchTargeting {
    rareBranchTracker?.update(from: corpus)
    let currentRareCount = rareBranchTracker?.rareIndices().count ?? 0

    if currentRareCount < lastRareBranchCount {
        // Made progress (some rare branches crossed threshold)
        iterationsSinceRareBranchProgress = 0
        lastRareBranchCount = currentRareCount
    } else {
        iterationsSinceRareBranchProgress += 1
    }
}

// Disable rare branch targeting temporarily if stalled
let rareBranchStalled = iterationsSinceRareBranchProgress > 2000
if rareBranchStalled && config.verbose {
    print("[Fuzz] Rare branch progress stalled, using standard selection")
}

// Use stall flag in selection logic
if config.enableRareBranchTargeting && !rareBranchStalled {
    // Rare branch selection
} else {
    // Standard selection
}
```

**Threshold**: 2000 iterations without rare branch progress triggers fallback (configurable via environment).

### Recommendation 5: Add Rare Branch Coverage to Test Reports

**Priority**: Low
**Effort**: Low (~30 lines)
**Value**: Makes rare branch coverage visible in CI/test output

**Implementation**:

```swift
// Extend FuzzResult to include rare branch metrics
public struct FuzzResult<each Input: Codable & Sendable>: Sendable {
    // ... existing fields ...

    /// Rare branch statistics (if tracking enabled)
    public let rareBranchStats: (rare: Int, total: Int, threshold: Int)?
}

// Populate in FuzzEngine.runFuzzing()
let rareBranchStats = rareBranchTracker.map { tracker -> (Int, Int, Int) in
    tracker.update(from: finalCorpus)
    return tracker.stats()
}

return FuzzResult(
    // ... existing parameters ...
    rareBranchStats: rareBranchStats
)

// Report in test output
if let stats = result.rareBranchStats {
    print("Rare branches covered: \(stats.rare)/\(stats.total) (threshold: \(stats.threshold))")
}
```

---

## Implementation Priority

**Phase 1: Foundation (Immediate)**
1. **Recommendation 1**: Rare branch tracking - provides metrics without changing fuzzing behavior
2. Enable in CI with `FUZZ_TRACK_RARE_BRANCHES=1` to gather baseline data

**Phase 2: Core Feature (Week 1-2)**
3. **Recommendation 2**: Rare-branch-preferring selection - core FairFuzz algorithm
4. **Recommendation 3**: Mutation amplification - complements selection
5. A/B testing against baseline on stress test suite

**Phase 3: Robustness (Week 3-4)**
6. **Recommendation 4**: Plateau fallback - handles edge cases
7. **Recommendation 5**: Test reporting - makes feature visible

**Phase 4: Refinement (Future)**
- Tune `rareBranchSelectionProbability` based on empirical results
- Explore lightweight component-level masking for structured types
- Integrate rare branch and value profile priorities more tightly

---

## Evaluation Strategy

### Baseline Measurement (Before FairFuzz)

**Test Suite**: `Tests/StressTests/FuzzerStressTests.swift` (if it exists) or create targeted benchmarks:

```swift
@Test func testNestedConditionals() throws {
    try fuzz { (a: Int, b: Int, c: String) in
        // Deeply nested conditionals requiring specific combinations
        if a > 100 {
            if b % 7 == 0 {
                if c.hasPrefix("SECRET_") {
                    if a * 3 + b == 777 {
                        // Rare branch guarded by multiple constraints
                        validate(a, b, c)
                    }
                }
            }
        }
    }
}
```

**Metrics**:
- Total branch coverage (as baseline)
- Rare branch count and percentage
- Time to discover specific rare branches
- Coverage distribution (histogram of hit counts)
- Iteration efficiency (coverage per iteration)

### A/B Comparison

**Control**: `FUZZ_RARE_BRANCH_TARGETING=0` (standard PropertyTestingKit)
**Treatment**: `FUZZ_RARE_BRANCH_TARGETING=1` (FairFuzz-enhanced)

**Hypothesis**: FairFuzz should:
- Discover rare branches faster (lower median time-to-discovery)
- Achieve more uniform coverage distribution (lower variance in hit counts)
- Perform better on deeply nested conditionals

**Statistical Analysis**:
- Run 20 trials per configuration
- Compare coverage curves using Mann-Whitney U test
- Measure rare branch discovery rate using survival analysis

### Real-World Validation

Apply to actual Swift code with complex conditional logic:
- JSON/XML parser validation functions
- Security input validation (URL parsing, SQL injection detection)
- State machine implementations with many states

**Success Criteria**: 10%+ improvement in rare branch coverage within same iteration budget.

---

## Differences from AFL/FairFuzz Context

PropertyTestingKit's design creates both challenges and opportunities compared to AFL:

### Fundamental Differences

**1. Mutation Granularity**
- **AFL**: Byte-level (flip bit, insert byte, splice chunks)
- **PropertyTestingKit**: Type-level (mutate Int, mutate String, mutate struct)
- **Impact**: FairFuzz's byte-level mutation masks don't apply directly. Need semantic component-level masking or selection strategies instead.

**2. Execution Model**
- **AFL**: Forks standalone binaries, tests accept file input
- **PropertyTestingKit**: Runs test functions in Swift Testing framework
- **Impact**: Can't cheaply re-run tests thousands of times for mask computation. Must use lightweight strategies like selection prioritization and amplification.

**3. Coverage Representation**
- **AFL**: Edge coverage with (src, dst) tuples and hit count bucketing
- **PropertyTestingKit**: LLVM counter indices from in-memory instrumentation
- **Impact**: FairFuzz's rare branch identification translates directly - both track per-location hit counts.

**4. Input Structure**
- **AFL**: Unstructured byte arrays
- **PropertyTestingKit**: Structured typed values `(String, Int, CustomType)`
- **Impact**: Advantage for PropertyTestingKit - semantic mutations can preserve structure (valid JSON, proper types) that byte mutations would break. Component-level masking can be more precise than byte-level.

**5. Corpus Size and Iteration Scale**
- **AFL**: Millions of iterations, corpora of thousands of inputs
- **PropertyTestingKit**: Default 10,000 iterations, smaller corpora
- **Impact**: Rare branch targeting may be even more critical given limited iterations. However, power-of-two threshold may need adjustment (could use power of 1.5 or fixed threshold like ≤5 hits).

### Architectural Advantages

**Existing Energy-Based Selection**: PropertyTestingKit already scores corpus entries by inverse frequency (line 240-250 in Corpus.swift), which naturally prefers rare branches. FairFuzz enhances this by:
- Explicitly identifying rare branches with a threshold
- Only selecting rare-branch-hitting entries (more aggressive)
- Amplifying mutations from those entries

**Value Profile Synergy**: PropertyTestingKit's comparison tracking complements FairFuzz:
- Value profile solves `if (x == 12345)` by suggesting mutations toward 12345
- Rare branch targeting ensures the fuzzer reaches that comparison often enough to solve it
- Combined: Select entries hitting rare branches AND making value profile progress

**Type Safety**: Swift's type system prevents many invalid mutations that AFL must deal with (e.g., string length corruption, alignment issues). PropertyTestingKit can focus fuzzing effort on semantically meaningful mutations.

---

## Related Work Synergies

FairFuzz combines well with other fuzzing techniques already present or researched for PropertyTestingKit:

### AFLFast / MOPT (Bohme 2016, Lyu 2019)
- **Synergy**: Adaptive power schedules (how much energy to assign each seed) combined with rare branch targeting (which seeds to assign energy to)
- **Integration**: Use MOPT to learn which mutation operators work best for cracking rare branch constraints
- **Papers**: `bohme-2019-aflfast.md`, `lyu-2019-mopt.md`

### Value Profile (LibFuzzer)
- **Synergy**: Already integrated in PropertyTestingKit - value profile guides comparison solving while rare branches ensure the fuzzer visits those comparisons
- **Integration**: Priority scoring that considers both rare branch hits and value profile progress
- **Current**: `ValueProfile.swift` lines 186-316

### String Dictionary Capture
- **Synergy**: Magic strings discovered by runtime capture help crack rare branch constraints like `if (input == "<!ATTLIST")`
- **Integration**: Combine dictionary mutations with rare branch targeting - use captured strings when mutating rare-branch-hitting entries
- **Current**: `StringDictionary.swift`, integrated in `FuzzEngine` around line 550-585

### Corpus Minimization (Delta Debugging)
- **Synergy**: When minimizing corpus, prioritize keeping inputs that hit rare branches
- **Integration**: Modify `Corpus.minimized()` to preserve rare branch diversity
- **Papers**: `zeller-2002-delta-debugging.md`

### Combined Strategy Example

```swift
// Hypothetical integrated approach in FuzzEngine
let priority = determinePriority(entry: corpusEntry, tracker: rareBranchTracker)

switch priority {
case .rareBranchAndValueProfile:
    // Highest priority: hits rare branches + made VP progress
    // Use value-profile-directed mutations, test 10x
    testMutations(amplification: 10, mutations: valueProfileDirectedMutations)

case .rareBranchOnly:
    // Hit rare branches but no VP progress
    // Use standard mutations, test 5x
    testMutations(amplification: 5, mutations: standardMutations)

case .valueProfileOnly:
    // Made VP progress but no rare branches
    // Use VP-directed mutations, test 3x
    testMutations(amplification: 3, mutations: valueProfileDirectedMutations)

case .standard:
    // No special priority
    // Use standard mutations, test 1x
    testMutations(amplification: 1, mutations: standardMutations)
}
```

---

## Open Questions

### 1. Power-of-Two Threshold Appropriateness

**Question**: FairFuzz's power-of-two threshold works for AFL's millions of iterations. Is it appropriate for PropertyTestingKit's default 10,000 iterations?

**Hypothesis**: May need adjustment:
- Smaller base (power of 1.5 instead of 2)
- Fixed threshold (≤5 hits = rare)
- Adaptive threshold based on iteration count

**Experiment**: Compare coverage distribution with different thresholds on stress tests.

### 2. Component vs. Field Masking Granularity

**Question**: For structured inputs like `(String, Int, Bool)`, is component-level selection sufficient, or do we need finer-grained masking (e.g., character-level for strings)?

**Trade-off**:
- Component-level: Cheap to compute, coarse-grained
- Field/character-level: Expensive (requires re-running tests), fine-grained

**Recommendation**: Start with component-level, evaluate whether fine-grained masking provides enough benefit to justify cost.

### 3. Interaction Between Rare Branch and Value Profile Priorities

**Question**: When an input hits rare branches AND makes value profile progress, which should take priority?

**Current Behavior**: Value profile priority overwrites rare branch priority (line 609 in FuzzEngine.swift).

**Options**:
1. Always prefer value profile (current)
2. Always prefer rare branches
3. Combine priorities (score = rare_branch_score + vp_score)
4. Alternate based on which is making more progress

**Recommendation**: Option 3 with tunable weights.

### 4. Test Execution Cost for Mask Computation

**Question**: PropertyTestingKit tests may have expensive setup (database initialization, network mocks). Is mask computation practical?

**Observation**: Computing byte-level masks requires re-running tests once per byte position. For a 1000-character input, that's 1000 test runs just to compute one mask.

**Recommendation**: Skip expensive mask computation. Use selection and amplification strategies instead (Recommendations 1-4).

### 5. Success Metrics Beyond Total Coverage

**Question**: How should we measure FairFuzz effectiveness? Branch coverage % isn't sufficient (FairFuzz optimizes for coverage uniformity, not just maximum coverage).

**Proposed Metrics**:
- **Coverage distribution entropy**: Higher entropy = more uniform coverage
- **Rare branch coverage rate**: Percentage of total branches that are rare
- **Time-to-rare-branch discovery**: How quickly rare branches are found
- **Hit count variance**: Lower variance = more uniform
- **Gini coefficient**: Measures inequality in coverage distribution (0 = perfect equality, 1 = maximum inequality)

**Recommendation**: Track multiple metrics, with primary focus on rare branch coverage rate and Gini coefficient.

---

## Future Work

### Short-Term (Next Sprint)
- Implement Recommendations 1-3
- Gather empirical data on rare branch distribution in PropertyTestingKit test suite
- Tune `rareBranchSelectionProbability` parameter

### Medium-Term (Next Quarter)
- Explore lightweight heuristic masking for strings (avoid expensive exhaustive testing)
- Integrate rare branch targeting with MOPT-style adaptive mutation scheduling
- Implement rare-branch-aware corpus minimization

### Long-Term (Future)
- Research whether FairFuzz's approach generalizes to other coverage metrics (e.g., path coverage, dataflow coverage)
- Investigate rare branch targeting for grammar-based fuzzing (structured inputs like JSON, SQL)
- Explore ML-based prediction of which mutations preserve rare branch hits (learning-based masks)

---

## Conclusion

FairFuzz's rare branch targeting strategy is highly applicable to PropertyTestingKit with Swift-appropriate adaptations. The core insight - that uniform fuzzing effort across discovered branches leads to coverage imbalance - applies equally to Swift Testing as to AFL's binary fuzzing. PropertyTestingKit's existing energy-based selection provides a foundation, which rare branch targeting enhances by explicitly identifying and prioritizing underexplored code.

The key adaptation is replacing FairFuzz's byte-level mutation masking with semantic strategies appropriate for Swift's type system:
1. **Input selection**: Preferentially choose corpus entries hitting rare branches
2. **Mutation amplification**: Test multiple mutations from rare-branch-hitting seeds
3. **Fallback mechanisms**: Prevent stalling when rare branch progress plateaus

These strategies preserve FairFuzz's benefits (uniform coverage exploration, faster rare branch discovery) while respecting PropertyTestingKit's semantic mutation model and avoiding expensive mask computation.

Implementation should proceed incrementally: first add tracking and metrics (Recommendation 1), then core selection logic (Recommendation 2), then enhancements (Recommendations 3-5). This allows empirical validation at each step and safe rollback if assumptions don't hold.

The combination of FairFuzz's rare branch targeting with PropertyTestingKit's existing value profile guidance and string dictionary capture creates a powerful multi-strategy fuzzer that addresses different aspects of the input space exploration challenge: rare branches ensure thorough exploration, value profiles solve comparison constraints, and string dictionaries crack magic string checks.

---

## Sources

- [FairFuzz: a targeted mutation strategy for increasing greybox fuzz testing coverage (ACM DL)](https://dl.acm.org/doi/10.1145/3238147.3238176)
- [FairFuzz: A Targeted Mutation Strategy for Increasing Greybox (Berkeley)](https://people.eecs.berkeley.edu/~ksen/papers/fairfuzz.pdf)
- [FairFuzz: Targeting Rare Branches to Rapidly Increase Greybox Fuzz Testing Coverage (arXiv)](https://arxiv.org/abs/1709.07101)
- [GitHub - carolemieux/afl-rb: FairFuzz: AFL extension targeting rare branches](https://github.com/carolemieux/afl-rb)
- [FairFuzz-TC: a fuzzer targeting rare branches (Springer)](https://link.springer.com/article/10.1007/s10009-020-00569-w)
