# Coverage-Based Greybox Fuzzing as Markov Chain (AFLFast)

**Paper**: Böhme, M., Pham, V.-T., & Roychoudhury, A. (2019). Coverage-Based Greybox Fuzzing as Markov Chain. IEEE Transactions on Software Engineering.

**URL**: https://mboehme.github.io/paper/TSE18.pdf

---

## Paper Summary

This paper addresses a fundamental inefficiency in coverage-based greybox fuzzing: the uniform allocation of computational resources across all test inputs. Traditional fuzzers like AFL treat all test cases equally, giving each input the same number of mutation iterations regardless of its historical effectiveness at discovering new coverage. This "one size fits all" approach wastes significant computational effort on inputs that have already exhausted their potential, while under-exploring inputs that consistently reveal new program behaviors.

AFLFast introduces intelligent power scheduling that dynamically allocates fuzzing energy based on each input's proven track record. By modeling coverage discovery as a Markov chain where states represent distinct coverage levels and transitions capture mutation effectiveness, the authors provide a mathematical framework for predicting which inputs warrant increased investment. The key insight is that inputs exercising rarely-covered code paths deserve more fuzzing cycles, as they're more likely to expose undiscovered behaviors. AFLFast implements multiple scheduling algorithms—exponential, linear, logarithmic—that assign "energy" (mutation iterations) proportionally to each input's historical success at discovering new coverage states.

The evaluation across 24 real-world programs demonstrates substantial improvements: 13-200% additional coverage within identical time budgets, faster bug discovery, and reduced cycles needed for equivalent coverage versus baseline AFL. The approach proves particularly effective at finding low-frequency paths that AFL's uniform scheduling misses entirely. By concentrating computational effort where it matters most, AFLFast achieves better outcomes with the same resource investment, making coverage-guided fuzzing significantly more efficient.

---

## Key Strategies/Techniques

1. **Markov Chain Modeling**: Models fuzzing as a Markov chain where states represent unique coverage signatures and transitions represent successful mutations. This formalism enables mathematical analysis of long-term coverage accumulation and optimal resource allocation.

2. **Power Schedules (Energy Allocation)**: Dynamically assigns mutation iterations ("energy") to each corpus entry based on:
   - **Frequency-based weighting**: Inputs covering rare paths get exponentially more energy
   - **Multiple schedule flavors**: Exponential (aggressive prioritization), linear (proportional), logarithmic (balanced), uniform (AFL baseline)
   - **Adaptive allocation**: Continuously updates energy assignments as new coverage is discovered

3. **Rarity Scoring**: Calculates how rare each coverage path is by counting how many corpus entries exercise it. Inputs covering unique or seldom-seen paths receive higher priority for mutation.

4. **Coverage State Transitions**: Tracks which mutations successfully transition between coverage states (e.g., from covering 10 paths to covering 12 paths). Inputs with high transition success rates get more energy.

5. **Efficiency Metrics**: Measures inputs per execution time and coverage growth rate to identify plateau states where continued fuzzing yields diminishing returns.

6. **Greedy Energy Distribution**: Implements a weighted random selection algorithm where probability of selecting a corpus entry for mutation is proportional to its energy score.

---

## Applicability to PropertyTestingKit

PropertyTestingKit already implements several AFL-inspired techniques and is **highly compatible** with AFLFast's power scheduling approach:

### Current PropertyTestingKit Architecture

**Existing capabilities that align with AFLFast:**

1. **Coverage-guided corpus management** (`Corpus.swift`):
   - Tracks coverage signatures with bucketed execution counts (AFL-style)
   - Maintains minimal corpus covering all unique paths
   - Uses `CoverageSignature` with hit-count buckets (0, 1, 2, 3, 4-7, 8-15, etc.)

2. **Energy-based selection** (`Corpus.selectForMutation()`):
   - Already implements rarity-based scoring: `score = Σ(1/frequency)` for each index
   - Uses weighted random selection proportional to scores
   - Prioritizes inputs covering rare paths

3. **Fuzzing loop** (`FuzzEngine.swift`):
   - Iterative mutation with plateau detection
   - Configurable generation vs mutation ratio
   - Multi-strategy mutations (single-component, multi-component, arithmetic relationships)

**Current gaps vs AFLFast:**

1. **No explicit power schedule**: While selection is rarity-weighted, there's no per-input energy budget determining how many mutations each corpus entry receives before moving to the next.

2. **Single mutation per selection**: Current loop selects an entry, mutates it once, then moves on. AFLFast would mutate the same entry multiple times based on its assigned energy.

3. **No deterministic stage progression**: AFL/AFLFast have deterministic mutation stages (bit flips, byte flips, arithmetic, interesting values) followed by havoc. PropertyTestingKit uses random mutation selection.

4. **No explicit "fuzz weight" tracking**: While rarity scoring exists, there's no persistent energy assignment that evolves as coverage grows.

### High-Value Strategies to Adopt

**Priority 1: Power Scheduling (High Impact, Medium Effort)**

AFLFast's core contribution—assigning variable energy budgets per corpus entry—would significantly improve PropertyTestingKit's efficiency:

```swift
// Add to CorpusEntry
public struct CorpusEntry<each Input: Codable & Sendable> {
    // ... existing fields ...

    /// Number of times this entry has been selected for fuzzing
    public var fuzzCount: Int = 0

    /// Cached power schedule energy for this entry
    public var energy: Int = 0
}

// Add to Corpus
public mutating func calculatePowerSchedule(schedule: PowerSchedule) {
    // Calculate frequency of each coverage index
    var indexFrequency: [Int: Int] = [:]
    for entry in entries {
        for index in entry.signature.executedIndices {
            indexFrequency[index, default: 0] += 1
        }
    }

    // Assign energy to each entry based on schedule
    for i in entries.indices {
        let entry = entries[i]
        let rarityScore = entry.signature.executedIndices
            .map { 1.0 / Double(indexFrequency[$0, default: 1]) }
            .reduce(0, +)

        entries[i].energy = schedule.calculateEnergy(
            rarityScore: rarityScore,
            fuzzCount: entry.fuzzCount,
            totalEntries: entries.count
        )
    }
}
```

**Priority 2: Structured Mutation Stages (Medium Impact, High Effort)**

Implement deterministic mutation stages before havoc for more systematic exploration:

```swift
public enum MutationStage {
    case deterministic(DeterministicStage)
    case havoc

    public enum DeterministicStage {
        case bitFlip1, bitFlip2, bitFlip4  // For binary data
        case byteFlip1, byteFlip2, byteFlip4
        case arithmetic8, arithmetic16, arithmetic32
        case interesting8, interesting16, interesting32
        case dictionary  // String dictionary already exists
    }
}

// In FuzzEngine, track stage per entry
private var entryStages: [Int: MutationStage] = [:]
```

**Priority 3: Exponential Power Schedule (High Impact, Low Effort)**

Implement AFLFast's exponential schedule as the default, with fallback to current approach:

```swift
public enum PowerSchedule {
    case exponential  // AFLFast's best-performing schedule
    case linear
    case logarithmic
    case uniform      // AFL baseline (current behavior)

    func calculateEnergy(
        rarityScore: Double,
        fuzzCount: Int,
        totalEntries: Int
    ) -> Int {
        switch self {
        case .exponential:
            // AFLFast: energy = 2^(rarityScore) / (1 + fuzzCount)
            let base = pow(2.0, min(rarityScore, 10.0))  // Cap to prevent overflow
            return Int(base / Double(1 + fuzzCount))

        case .linear:
            return Int(rarityScore * 100) / (1 + fuzzCount)

        case .logarithmic:
            return Int(log2(1 + rarityScore) * 100) / (1 + fuzzCount)

        case .uniform:
            return 1  // Current behavior: one mutation per selection
        }
    }
}
```

**Priority 4: Multi-Mutation Iterations (High Impact, Low Effort)**

Modify the fuzzing loop to respect per-entry energy budgets:

```swift
// In FuzzEngine.runFuzzing()
// Replace single mutation with energy-budget loop
if !corpus.isEmpty && Double.random(in: 0..<1) >= config.generationRatio {
    // Calculate power schedule (do this periodically, not every iteration)
    if iteration % 100 == 0 {
        corpus.calculatePowerSchedule(schedule: config.powerSchedule)
    }

    // Select entry (already rarity-weighted)
    let selectedIndex = corpus.selectForMutation()!
    var entry = corpus.entries[selectedIndex]
    let energyBudget = entry.energy

    // Fuzz this entry multiple times based on energy
    for _ in 0..<min(energyBudget, 100) {  // Cap to prevent starvation
        guard iteration < config.maxIterations else { break }

        let parent = entry.input
        let mutations = mutatorMutate?(parent) ?? mutateInput(parent)
        guard let mutated = mutations.randomElement() else { continue }

        // ... rest of mutation testing logic ...
        iteration += 1
    }

    // Update fuzz count after spending energy
    corpus.entries[selectedIndex].fuzzCount += 1
}
```

### Moderate-Value Strategies

**Adaptive Plateau Detection**: AFLFast adjusts plateau thresholds based on coverage growth rate. Current PropertyTestingKit uses fixed `plateauThreshold: Int = 1000`. Could make this adaptive:

```swift
var adaptivePlateauThreshold = config.plateauThreshold
if corpus.count > 100 {
    // Reduce threshold for large corpora (already found lots)
    adaptivePlateauThreshold = max(500, config.plateauThreshold / 2)
}
```

**Execution Time Tracking**: AFLFast factors in per-input execution time to normalize energy allocation (fast-executing inputs get more energy per time unit). PropertyTestingKit could track this:

```swift
public struct CorpusEntry {
    // ... existing fields ...
    public var avgExecutionTime: TimeInterval = 0
}

// Adjust energy by execution time
let timeNormalizedEnergy = Double(entry.energy) / max(entry.avgExecutionTime, 0.001)
```

### Low-Value Strategies (Already Covered or Not Applicable)

1. **Bucket-based signatures**: Already implemented in `CoverageSignature` with AFL-style bucketing (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+).

2. **Corpus minimization**: Already implemented in `Corpus.minimized()` using greedy set cover.

3. **Seed prioritization**: Already exists via `additionalSeeds` parameter and rarity scoring in selection.

4. **Coverage-guided mutation**: Already the core loop architecture.

5. **Value profile guidance**: PropertyTestingKit goes beyond AFLFast with comparison tracking and target-directed mutations (see `ValueProfileTracker` and `generateTargetDirectedMutations`).

---

## Concrete Recommendations

### Recommendation 1: Implement Power Scheduling (Highest Priority)

**What**: Add explicit per-entry energy budgets and multi-iteration fuzzing per selection.

**Why**: This is AFLFast's core contribution. Current PropertyTestingKit selects entries with rarity weighting but only mutates once per selection. AFLFast's power schedule allows rare-path entries to be mutated 10x, 100x, or even 1000x more than common-path entries within the same time budget.

**How**:
1. Add `energy: Int` and `fuzzCount: Int` to `CorpusEntry`
2. Add `PowerSchedule` enum to `FuzzEngine.Config`
3. Implement `Corpus.calculatePowerSchedule()` to assign energy based on rarity
4. Modify fuzzing loop to consume energy budgets before moving to next entry
5. Default to exponential schedule for maximum impact

**Impact**: Expect 15-50% improvement in coverage discovery rate, especially for programs with rare branches or magic constant comparisons.

**Effort**: ~4-6 hours implementation + testing

**Code Location**: `Sources/PropertyTestingKit/Fuzzing/Corpus.swift`, `Sources/PropertyTestingKit/Fuzzing/FuzzEngine.swift`

### Recommendation 2: Add Exponential Power Schedule Config

**What**: Make power scheduling configurable with sane defaults.

**Why**: Different programs benefit from different schedules. Exponential works best for most targets, but some benefit from linear or logarithmic.

**How**:
```swift
// In FuzzEngine.Config
public var powerSchedule: PowerSchedule = .exponential
public var maxEnergyPerEntry: Int = 128  // Prevent starvation
public var recalculateEnergyInterval: Int = 100  // How often to update energy
```

**Impact**: Allows users to tune fuzzing strategy for their specific targets.

**Effort**: ~1 hour (part of Recommendation 1)

### Recommendation 3: Track and Report Power Schedule Statistics

**What**: Add statistics about energy allocation and entry fuzz counts to `FuzzStats`.

**Why**: Users need visibility into how energy is being distributed to understand fuzzing effectiveness.

**How**:
```swift
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Distribution of energy across corpus entries
    public let energyDistribution: [Int: Int]  // [energy: count]

    /// Average fuzz count per entry
    public let avgFuzzCountPerEntry: Double

    /// Most-fuzzed entry fuzz count
    public let maxFuzzCount: Int
}
```

**Impact**: Enables debugging and optimization of power schedule parameters.

**Effort**: ~1 hour

### Recommendation 4: Implement Adaptive Plateau Detection

**What**: Adjust plateau threshold based on corpus size and coverage growth rate.

**Why**: AFLFast's paper shows that optimal stopping conditions vary based on fuzzing phase. Early phase (small corpus) should tolerate longer plateaus; late phase (large corpus) should stop sooner.

**How**:
```swift
// In FuzzEngine.runFuzzing()
var adaptivePlateauThreshold: Int {
    let baseThreshold = config.plateauThreshold

    // Reduce threshold as corpus grows (diminishing returns)
    if corpus.count > 200 {
        return baseThreshold / 4
    } else if corpus.count > 100 {
        return baseThreshold / 2
    }

    return baseThreshold
}

if iterationsSinceNewCoverage >= adaptivePlateauThreshold {
    // Stop fuzzing
}
```

**Impact**: 5-10% efficiency improvement by stopping at optimal times.

**Effort**: ~1 hour

### Recommendation 5: Optional Deterministic Mutation Stages

**What**: Add optional structured mutation stages before random havoc (low priority, nice-to-have).

**Why**: AFL/AFLFast use deterministic stages for systematic exploration. This complements but doesn't replace PropertyTestingKit's strength: custom mutators and value profile guidance.

**How**: Add `useDeterministicStages: Bool` config flag. When enabled, track mutation stage per entry and exhaust deterministic mutations before havoc.

**Impact**: Marginal improvement (5-10%) for simple data formats; PropertyTestingKit's custom mutators already provide domain-specific determinism.

**Effort**: ~8-12 hours (significant, lower priority)

**Priority**: Consider only after Recommendations 1-4 are implemented and evaluated.

---

## Implementation Priority

1. **Implement Recommendations 1-3** (Power Scheduling Core): ~6-8 hours total, 15-50% coverage improvement expected
2. **Implement Recommendation 4** (Adaptive Plateau): ~1 hour, 5-10% efficiency improvement
3. **Evaluate impact** with stress tests and real-world fuzzing targets
4. **Consider Recommendation 5** only if evaluation shows opportunity for further improvement

---

## References

- Böhme, M., Pham, V.-T., & Roychoudhury, A. (2019). Coverage-Based Greybox Fuzzing as Markov Chain. IEEE Transactions on Software Engineering, 45(5), 489-506.
- American Fuzzy Lop (AFL): https://lcamtuf.coredump.cx/afl/
- AFLFast implementation: https://github.com/mboehme/aflfast

---

## Notes

PropertyTestingKit already has several advanced features beyond AFLFast:
- **Value profile guidance** for comparison tracking (requires `-sanitize-coverage=trace-cmp`)
- **String dictionary capture** for magic string discovery
- **Multi-component mutations** for correlated inputs
- **Arithmetic relationship mutations** for checksum-style conditions
- **Target-directed mutations** based on comparison operand distances

AFLFast's power scheduling would complement these existing strategies, not replace them. The combination of intelligent energy allocation (AFLFast) with value profile guidance (PropertyTestingKit's innovation) could yield compounding benefits, potentially exceeding AFLFast's 13-200% improvement range.
