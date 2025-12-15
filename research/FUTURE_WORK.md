# PropertyTestingKit Future Work: Prioritized Research-Based Recommendations

This document synthesizes recommendations from 40+ research papers and blog posts analyzed in the `research/` directory. Recommendations are categorized by implementation priority based on:
- Expected impact on fuzzing effectiveness
- Implementation complexity
- Alignment with PropertyTestingKit's existing architecture
- Practical value for Swift developers

---

## High Priority

These features offer significant impact with reasonable implementation effort and strong architectural fit.

### 1. Entropic Seed Selection (Shannon Entropy)
**Source:** [bohme-2020-entropic.md](bohme-2020-entropic.md)

**What:** Use information-theoretic scheduling where seeds with higher entropy (more information gain) are prioritized for mutation. Track (edge, hit-count bucket) pairs as features and compute Shannon entropy for each seed's global rarity.

**Why High Priority:**
- Default in libFuzzer since 2020 with proven effectiveness
- 1.63x improvement in code coverage over baseline
- Directly addresses coverage plateau problem
- Compatible with existing corpus infrastructure

**Implementation Sketch:**
```swift
struct FeatureProfile {
    var globalFeatureCounts: [Feature: Int] = [:]  // (edge, bucket) -> count

    struct Feature: Hashable {
        let edgeIndex: Int
        let hitCountBucket: UInt8
    }

    func computeEntropy(for entry: CorpusEntry) -> Double {
        var entropy = 0.0
        for feature in entry.features {
            let frequency = Double(globalFeatureCounts[feature] ?? 1)
            let probability = 1.0 / frequency
            entropy -= probability * log2(probability)
        }
        return entropy
    }
}
```

**Effort:** 2-3 weeks

---

### 2. Test Case Shrinking / Minimization (Delta Debugging)
**Sources:** [zeller-2002-delta-debugging.md](zeller-2002-delta-debugging.md), [maciver-2020-hypothesis-reducer.md](maciver-2020-hypothesis-reducer.md)

**What:** When a test fails, automatically reduce the failing input to its minimal form using ddmin algorithm. Produces small, understandable reproducers.

**Why High Priority:**
- Critical for developer experience - large failing inputs are hard to debug
- Fundamental feature in Hypothesis that PropertyTestingKit lacks
- Makes bug reports actionable
- Reduces corpus storage and speeds replay

**Implementation Approach:**
- Structure-aware splitting (array elements, string characters, struct fields)
- Hierarchical minimization for nested types
- Cache test results during minimization

```swift
protocol TestCaseMinimizer {
    func minimize<T>(
        input: T,
        test: (T) -> TestResult,
        splitter: InputSplitter<T>
    ) -> T
}

enum TestResult {
    case pass, fail, unresolved
}
```

**Effort:** 3-4 weeks

---

### 3. Swarm Testing (Mutator Subset Selection)
**Source:** [groce-2012-swarm-testing.md](groce-2012-swarm-testing.md)

**What:** Instead of using all mutation strategies for every input, randomly select a subset of mutators per "swarm configuration." Each configuration explores a different region of the mutation space.

**Why High Priority:**
- Simple to implement, proven effective (reaches 2% more functions)
- Diversifies exploration without complex scheduling
- Particularly valuable when PropertyTestingKit has many mutation strategies
- Zero learning overhead - pure stochastic diversification

**Implementation:**
```swift
struct SwarmConfig {
    let activeMutators: Set<MutatorID>
    let configurationWindow: Int = 100  // Re-sample every N iterations

    static func randomConfiguration(from all: [MutatorID]) -> SwarmConfig {
        // Each mutator has 50% probability of inclusion
        let active = all.filter { _ in Bool.random() }
        return SwarmConfig(activeMutators: Set(active.isEmpty ? [all.randomElement()!] : active))
    }
}
```

**Effort:** 1-2 weeks

---

### 4. Adaptive Mutation Scheduling (MOPT/PSO-Inspired)
**Source:** [lyu-2019-mopt.md](lyu-2019-mopt.md)

**What:** Track which mutation operators are most effective at finding new coverage and dynamically adjust their selection probabilities using Particle Swarm Optimization.

**Why High Priority:**
- MOPT outperformed baseline AFL by finding 170% more unique crashes
- Addresses the "operator scheduling problem" - some operators are more effective on certain targets
- Complements swarm testing with adaptive learning
- Already have per-operator tracking infrastructure

**Implementation:**
```swift
struct MutationScheduler {
    var operatorWeights: [MutatorID: Double]
    var operatorHistory: [MutatorID: (uses: Int, successes: Int)]

    mutating func updateWeights() {
        // PSO-inspired: Move weights toward successful configurations
        for (op, history) in operatorHistory {
            let successRate = Double(history.successes) / Double(max(1, history.uses))
            operatorWeights[op] = lerp(operatorWeights[op]!, toward: successRate, factor: 0.1)
        }
    }

    func selectOperator() -> MutatorID {
        weightedRandomSelection(weights: operatorWeights)
    }
}
```

**Effort:** 2-3 weeks

---

### 5. Coverage Plateau Detection with Early Stopping
**Source:** [elhage-2020-property-testing-blogs.md](elhage-2020-property-testing-blogs.md)

**What:** Track coverage growth rate over time and stop fuzzing early when discovery rate drops below threshold.

**Why High Priority:**
- Directly improves developer experience - no wasted fuzzing time
- Simple to implement
- Aligns with Elhage's workflow recommendations
- Makes 60-second default duration adaptive

**Implementation:**
```swift
struct CoveragePlateauDetector {
    var recentCoverageGrowth: [Int] = []  // Coverage deltas for last N iterations
    let windowSize: Int = 1000
    let minGrowthRate: Double = 0.001  // 0.1% per iteration

    mutating func record(newCoverage: Int) {
        recentCoverageGrowth.append(newCoverage)
        if recentCoverageGrowth.count > windowSize {
            recentCoverageGrowth.removeFirst()
        }
    }

    var shouldStop: Bool {
        guard recentCoverageGrowth.count >= windowSize else { return false }
        let growthRate = Double(recentCoverageGrowth.reduce(0, +)) / Double(windowSize)
        return growthRate < minGrowthRate
    }
}
```

**Effort:** 1 week

---

### 6. Rare Branch Targeting (FairFuzz-Inspired)
**Source:** [lemieux-2018-fairfuzz.md](lemieux-2018-fairfuzz.md)

**What:** Track which branches are rarely hit across corpus and prioritize mutations targeting those branches. Inputs that hit rare branches receive higher energy.

**Why High Priority:**
- FairFuzz showed 20% more coverage on some benchmarks
- Directly addresses "easy path saturation" problem
- Already have branch-level coverage tracking
- Natural extension of rarity-based corpus selection

**Implementation:**
```swift
// Extend CoverageSignature to track branch frequencies
struct BranchRarityTracker {
    var branchHitCounts: [Int: Int] = [:]  // branch index -> total corpus hits

    func rarityScore(for signature: CoverageSignature) -> Double {
        signature.buckets.map { branch, _ in
            1.0 / Double(branchHitCounts[branch] ?? 1)
        }.reduce(0, +)
    }

    func selectForMutation(corpus: [CorpusEntry]) -> Int {
        let scores = corpus.map { rarityScore(for: $0.signature) }
        return weightedRandomIndex(scores)
    }
}
```

**Effort:** 1-2 weeks

---

### 7. Failure Preservation and Reporting
**Source:** [elhage-2020-property-testing-blogs.md](elhage-2020-property-testing-blogs.md), [miller-1990-fuzz.md](miller-1990-fuzz.md)

**What:** Explicitly tag failure-inducing corpus entries, prevent minimization from removing them, and generate copy-paste Swift code for regression tests.

**Why High Priority:**
- Core to regression testing workflow
- Makes fuzzer findings actionable
- Low implementation effort
- Addresses gap in current corpus management

**Implementation:**
```swift
struct CorpusEntry<Input> {
    let input: Input
    let coverage: CoverageSignature
    let triggeredFailure: Bool
    let failureInfo: FailureInfo?
}

struct FailureInfo: Codable {
    let errorType: String
    let message: String
    let discoveredAt: Date
}

// Generate copy-paste test code on failure
func generateRegressionTest(input: Input, error: Error) -> String {
    """
    @Test func testRegression_\(Date().formatted())() throws {
        let input = \(input.debugDescription)
        #expect(throws: \(type(of: error)).self) {
            try targetFunction(input)
        }
    }
    """
}
```

**Effort:** 1-2 weeks

---

### 8. Per-Execution Timeout / Hang Detection
**Source:** [miller-1990-fuzz.md](miller-1990-fuzz.md)

**What:** Add per-input timeout to detect hangs (infinite loops, deadlocks) separate from overall campaign duration.

**Why High Priority:**
- Fundamental fuzzing capability from the original 1990 paper
- Detects bugs that crash detection misses
- Simple to implement with Swift concurrency

**Implementation:**
```swift
try fuzz(perInputTimeout: 0.5) { input in
    // Times out after 500ms per execution
}

// In FuzzEngine
func runTest(input: Input, timeout: TimeInterval) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await Task.sleep(for: .seconds(timeout))
            throw HangDetectedError()
        }
        group.addTask {
            try testBody(input)
        }
        try await group.next()
        group.cancelAll()
    }
}
```

**Effort:** 1 week

---

## Medium Priority

These features offer good value but require more effort or have narrower applicability.

### 9. Stagnation Detection with Adaptive Reset (FuzzChick)
**Source:** [lampropoulos-2019-fuzzchick.md](lampropoulos-2019-fuzzchick.md)

**What:** When mutation-based fuzzing stops finding new coverage, increase the generation ratio temporarily to escape local optima.

**Implementation:**
```swift
struct AdaptiveGenerationRatio {
    var stagnationCounter: Int = 0
    var baseRatio: Double = 0.3
    let stagnationThreshold: Int = 500

    var currentRatio: Double {
        let factor = min(Double(stagnationCounter) / Double(stagnationThreshold), 3.0)
        return min(baseRatio * pow(2.0, factor), 0.9)
    }

    mutating func recordCoverageGain() { stagnationCounter = 0 }
    mutating func recordIteration() { stagnationCounter += 1 }
}
```

**Effort:** 1 week

---

### 10. Corpus Mutation Genealogy Tracking
**Source:** [lampropoulos-2019-fuzzchick.md](lampropoulos-2019-fuzzchick.md)

**What:** Track which corpus entries produced which descendants. Prioritize mutating "fertile" lineages that frequently discover new coverage.

**Implementation:**
```swift
struct CorpusEntry<Input> {
    let id: UUID
    let parentID: UUID?
    let generationDepth: Int
    var descendantSuccesses: Int = 0
}

func updateGenealogyOnSuccess(childID: UUID) {
    var current = childID
    while let parentID = entries[current]?.parentID {
        entries[parentID]?.descendantSuccesses += 1
        current = parentID
    }
}
```

**Effort:** 2-3 weeks

---

### 11. Behavioral Diversity Metrics (Hill Numbers / MAP-Elites)
**Sources:** [nguyen-2022-bedivfuzz.md](nguyen-2022-bedivfuzz.md), [mouret-2015-map-elites.md](mouret-2015-map-elites.md)

**What:** Measure corpus diversity using Hill numbers (effective number of distinct behaviors) and maintain a behavioral archive for illumination-style exploration.

**Implementation:**
```swift
struct BehavioralDiversityTracker {
    var branchExecutionCounts: [Int: Int] = [:]  // branch -> execution count

    // Hill number of order q (q=0: species richness, q=1: Shannon diversity, q=2: Simpson diversity)
    func effectiveBehaviors(q: Double) -> Double {
        let total = Double(branchExecutionCounts.values.reduce(0, +))
        let proportions = branchExecutionCounts.values.map { Double($0) / total }

        if q == 1 {
            // Shannon entropy
            return exp(-proportions.map { $0 * log($0) }.reduce(0, +))
        } else {
            let sum = proportions.map { pow($0, q) }.reduce(0, +)
            return pow(sum, 1.0 / (1.0 - q))
        }
    }
}
```

**Effort:** 2-3 weeks

---

### 12. Multi-Armed Bandit Strategy Selection (RLCheck)
**Source:** [reddy-2020-rlcheck.md](reddy-2020-rlcheck.md)

**What:** Use Thompson Sampling to dynamically select between mutation strategies based on observed coverage rewards.

**Implementation:**
```swift
struct ThompsonSampler {
    var arms: [String: (successes: Int, failures: Int)]

    func selectArm() -> String {
        arms.map { name, stats in
            let sample = BetaDistribution(alpha: stats.successes + 1, beta: stats.failures + 1).sample()
            return (name, sample)
        }
        .max(by: { $0.1 < $1.1 })!.0
    }

    mutating func update(arm: String, success: Bool) {
        if success {
            arms[arm]!.successes += 1
        } else {
            arms[arm]!.failures += 1
        }
    }
}
```

**Effort:** 2 weeks

---

### 13. Differential Testing Utilities
**Source:** [yang-2011-csmith.md](yang-2011-csmith.md)

**What:** Provide first-class support for comparing multiple implementations on fuzzed inputs.

**Implementation:**
```swift
public func differentialFuzz<Input: Fuzzable, Output: Equatable>(
    reference: (Input) throws -> Output,
    implementation: (Input) throws -> Output
) throws {
    try fuzz { input in
        let refOut = try reference(input)
        let implOut = try implementation(input)
        #expect(refOut == implOut, "Diverged on: \(input)")
    }
}
```

**Effort:** 1 week

---

### 14. Uncommon Value Generation (Inputs from Hell)
**Source:** [soremekun-2020-inputs-from-hell.md](soremekun-2020-inputs-from-hell.md)

**What:** Learn value distributions from corpus and generate deliberately uncommon values to exercise edge cases.

**Implementation:**
```swift
struct CorpusDistributionLearner {
    var intHistogram: [Int: Int] = [:]

    func generateUncommonInt() -> Int {
        // If corpus mostly uses small positive ints, return extremes
        if intHistogram.keys.allSatisfy({ $0 > 0 && $0 < 1000 }) {
            return [Int.min, Int.max, -1, 0].randomElement()!
        }
        // Otherwise return least common value bucket
        return intHistogram.min(by: { $0.value < $1.value })?.key ?? 0
    }
}
```

**Effort:** 2 weeks

---

### 15. Corpus Statistics and Metrics
**Source:** [elhage-2020-property-testing-blogs.md](elhage-2020-property-testing-blogs.md)

**What:** Report detailed fuzzing statistics: iterations, duration, coverage discovered, corpus size, validity rate, regressions prevented.

**Implementation:**
```swift
struct FuzzStatistics {
    var iterations: Int
    var duration: TimeInterval
    var coverageDiscovered: Int
    var corpusSize: Int
    var corpusSizeBeforeMinimization: Int
    var failuresFound: Int
    var regressionssPrevented: Int

    var summary: String {
        """
        Fuzzing Statistics:
        - Iterations: \(iterations) (stopped at coverage plateau)
        - Duration: \(duration.formatted())
        - Coverage: \(coverageDiscovered) unique paths
        - Corpus: \(corpusSize) inputs (minimized from \(corpusSizeBeforeMinimization))
        - Failures: \(failuresFound)
        - Regressions prevented: \(regressionsPrevented)
        """
    }
}
```

**Effort:** 1 week

---

### 16. Cross-Variant Enum Mutations (FuzzChick)
**Source:** [lampropoulos-2019-fuzzchick.md](lampropoulos-2019-fuzzchick.md)

**What:** For enums, implement mutations that switch between cases while preserving associated value structure where possible.

**Implementation:**
```swift
protocol CrossMutable {
    func crossMutate() -> [Self]
}

// For enum Tree { case leaf(Int); case node(Tree, Tree) }
extension Tree: CrossMutable {
    func crossMutate() -> [Tree] {
        switch self {
        case .leaf(let v):
            return [.node(.leaf(v), .leaf(v))]  // Promote to node
        case .node(let l, _):
            return [l]  // Collapse to first child
        }
    }
}
```

**Effort:** 2-3 weeks (needs macro support for automatic derivation)

---

### 17. Mutation Testing Integration (Mu2-Inspired)
**Source:** [padhye-2023-mu2.md](padhye-2023-mu2.md)

**What:** Add mutation-killing as a secondary guidance metric. Inputs that detect more semantic differences (via differential testing) receive higher priority.

**Why Medium:**
- Full mutation testing is complex in Swift (no runtime class loading)
- Can approximate via differential testing mode
- High value for semantic bug finding

**Implementation:**
Start with differential testing API, then expand to symbolic mutation detection.

**Effort:** 3-4 weeks

---

### 18. Value Profile Distance-Based Energy
**Source:** [pham-2019-aflsmart.md](pham-2019-aflsmart.md)

**What:** Allocate more mutation energy to inputs that are "close" to solving comparison constraints (low distance to target values).

**Implementation:**
```swift
func calculateComparisonProgress(valueProfile: ValueProfile) -> Double {
    let solved = valueProfile.solvedComparisons.count
    let total = valueProfile.trackedComparisons.count
    return Double(solved) / Double(max(1, total))
}

// Higher progress = more energy
entry.energy = baseEnergy * (1.0 + progress * 5.0)
```

**Effort:** 2 weeks

---

## Low Priority

These features are either highly specialized, require significant effort for limited applicability, or are already well-addressed by existing architecture.

### 19. Full PCA-Based Combinatorial Coverage (Ankou)
**Source:** [manes-2020-ankou.md](manes-2020-ankou.md)

**What:** Use Principal Component Analysis to identify combinatorial patterns in execution traces.

**Why Low Priority:**
- Memory-intensive (OOM issues observed in benchmarks)
- PropertyTestingKit targets short fuzz runs, not hours of execution
- Limited benefit for structured Swift types vs. binary formats

**Alternative:** Lightweight edge pair tracking (see Ankou analysis)

**Effort:** 4-6 weeks

---

### 20. Constraint Solving (DART/SAGE-Inspired)
**Sources:** [godefroid-2005-dart.md](godefroid-2005-dart.md), [godefroid-2008-sage.md](godefroid-2008-sage.md)

**What:** Use SMT solvers (Z3) to generate inputs satisfying path constraints.

**Why Low Priority:**
- Swift lacks symbolic execution infrastructure
- Complex Swift types (classes, protocols) are hard to model symbolically
- Value profile guidance already addresses comparison constraints

**Alternative:** Comparison tracking with distance-guided mutations

**Effort:** 6-8 weeks

---

### 21. Binary Format Fuzzing (AFLSmart-Inspired)
**Source:** [pham-2019-aflsmart.md](pham-2019-aflsmart.md)

**What:** Support chunk-based mutations for binary file formats using format specifications.

**Why Low Priority:**
- PropertyTestingKit targets Swift application logic, not binary parsers
- Swift's type system provides structure awareness for most use cases
- Niche use case with limited adoption

**Alternative:** Add Data/[UInt8] Fuzzable conformance with basic byte mutations if needed.

**Effort:** 3-4 weeks

---

### 22. Program Generation (CSmith-Inspired)
**Source:** [yang-2011-csmith.md](yang-2011-csmith.md)

**What:** Generate random Swift programs to test compilers or macro systems.

**Why Low Priority:**
- Different domain (compiler testing vs. application testing)
- Would require full SwiftSyntax integration
- Very specialized use case

**Alternative:** Focus on structured input generation, not program generation.

**Effort:** 6-8 weeks

---

### 23. Directed Fuzzing (AFLGo-Inspired)
**Source:** [bohme-2017-aflgo.md](bohme-2017-aflgo.md)

**What:** Direct fuzzing toward specific code locations (e.g., recently changed functions, known vulnerable code).

**Why Low Priority:**
- Requires source-to-coverage mapping (complex in Swift)
- Most PropertyTestingKit users want general fuzzing, not targeted
- Symbol resolution in Swift is complex (name mangling, generics)

**Alternative:** Rare branch targeting provides similar benefits with simpler implementation.

**Effort:** 4-6 weeks

---

## Not Recommended

These approaches are not applicable to PropertyTestingKit's domain.

### Pointer/Memory Reasoning (DART)
Swift's memory safety eliminates this concern.

### Signal Handler Race Conditions (Miller 1990)
Swift's structured concurrency model doesn't use signals.

### Core Dump Analysis (Miller 1990)
Swift Testing produces assertion failures, not crashes.

### Grammar-Based Text Fuzzing (Inputs from Hell)
PropertyTestingKit uses type-safe structured inputs, not grammar-based text generation.

---

## Implementation Roadmap

### Phase 1: Core Workflow (Weeks 1-4)
1. Coverage plateau detection with early stopping
2. Per-execution timeout / hang detection
3. Failure preservation and reporting
4. Corpus statistics and metrics

### Phase 2: Seed Selection & Scheduling (Weeks 5-8)
5. Entropic seed selection
6. Rare branch targeting
7. Swarm testing
8. Stagnation detection with adaptive reset

### Phase 3: Shrinking & Minimization (Weeks 9-12)
9. Delta debugging for test case shrinking
10. Hierarchical structure-aware minimization
11. Corpus simplification

### Phase 4: Advanced Features (Weeks 13-20)
12. Adaptive mutation scheduling (MOPT)
13. Behavioral diversity metrics
14. Corpus mutation genealogy
15. Multi-armed bandit strategy selection

### Phase 5: Extensions (Future)
16. Differential testing utilities
17. Uncommon value generation
18. Cross-variant enum mutations
19. Mutation testing integration

---

## Research Sources

All recommendations are derived from analysis in the `research/` directory. Key papers:

**Seed Selection:**
- Böhme 2020 - Entropic (libFuzzer default)
- Lemieux 2018 - FairFuzz (rare branch targeting)
- Böhme 2019 - AFLFast (coverage-based power schedules)

**Mutation Strategies:**
- Lyu 2019 - MOPT (PSO-based scheduling)
- Groce 2012 - Swarm Testing (feature omission)
- Lampropoulos 2019 - FuzzChick (type-aware mutations)

**Shrinking:**
- Zeller 2002 - Delta Debugging
- MacIver 2020 - Hypothesis Reducer (internal shrinking)

**Diversity:**
- Nguyen 2022 - BeDivFuzz (Hill numbers)
- Mouret 2015 - MAP-Elites (illumination)

**Workflow:**
- Elhage 2020 - Property Testing blogs (corpus-based CI)
- Miller 1990 - Original fuzzing paper (timeout detection)

**Evaluation:**
- Klees 2018 - Evaluating Fuzz Testing
- Groce 2014 - Coverage and Its Discontents
