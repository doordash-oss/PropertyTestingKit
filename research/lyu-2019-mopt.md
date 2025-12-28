# MOPT: Optimized Mutation Scheduling for Fuzzers

**Paper:** Lyu et al., "MOPT: Optimized Mutation Scheduling for Fuzzers", USENIX Security 2019
**URL:** https://www.usenix.org/system/files/sec19-lyu.pdf

---

## Paper Summary

MOPT addresses a fundamental inefficiency in mutation-based fuzzing: traditional fuzzers like AFL apply mutation operators uniformly without learning which operators are most effective for discovering new coverage in a specific target program. AFL uses a fixed probability distribution across its mutation strategies (bit flips, byte flips, arithmetic mutations, etc.), treating all operators equally regardless of their effectiveness. This one-size-fits-all approach wastes fuzzing cycles on unproductive mutations while underutilizing the most valuable ones.

MOPT introduces an adaptive mutation scheduling system that dynamically adjusts operator selection probabilities during fuzzing. The key insight is that different programs respond differently to different mutation strategies - some targets may be more sensitive to arithmetic mutations while others respond better to bit-level changes. MOPT employs Particle Swarm Optimization (PSO) to model this as a dynamic optimization problem where each "particle" represents a probability distribution over available mutation operators. The system runs in three phases: (1) a pilot phase with uniform probabilities to gather initial data, (2) a core phase where PSO optimizes operator selection based on which strategies generate high-value test cases, and (3) continued adaptive scheduling with the learned distributions.

Experimental results demonstrate substantial improvements over vanilla AFL across diverse benchmarks. MOPT discovers significantly more unique crashes, achieves faster path coverage, and shows consistent improvements on both synthetic test programs and real-world binaries. The framework integrates cleanly with AFL's existing infrastructure, replacing only the mutation selection mechanism while preserving other components like coverage tracking and corpus management.

---

## Key Strategies/Techniques

1. **Particle Swarm Optimization (PSO) for Mutation Scheduling**: Models mutation operator effectiveness as a multi-dimensional optimization problem. Each particle maintains a probability distribution vector over available operators, and the swarm iteratively explores the space to find optimal distributions.

2. **Three-Phase Fuzzing Pipeline**:
   - **Pilot Phase**: Initial exploration with uniform operator probabilities to establish baseline performance
   - **Core Phase**: PSO-driven optimization where successful operators receive increased selection probability
   - **Pacemaker Mode**: Periodic switching between learned distributions and uniform distribution to prevent premature convergence

3. **Feedback Loop Based on Test Case Value**: Operators that generate inputs discovering new coverage or triggering crashes receive higher weights in the probability distribution, creating a reinforcement learning-style feedback mechanism.

4. **Swarm-Based Exploration**: Multiple particles (probability distributions) explore the operator space simultaneously, with particles influenced by both their own best-found distribution and the global best across all particles.

5. **Dynamic Adaptation**: Continuously updates operator probabilities throughout the fuzzing campaign rather than using a fixed schedule, allowing the fuzzer to adapt as it explores different regions of the program.

6. **Integration with AFL's Havoc Stage**: MOPT specifically targets AFL's "havoc" mutation stage where operators are applied in sequence, making it compatible with AFL's existing deterministic mutation stages.

---

## Applicability to PropertyTestingKit

**High Applicability** - MOPT's core concepts translate well to PropertyTestingKit's architecture, though implementation approaches differ from AFL's C-based design.

### Current PropertyTestingKit Architecture

PropertyTestingKit already implements several coverage-guided fuzzing concepts similar to AFL:

- **Coverage-guided corpus management** (`Corpus.swift`): Tracks coverage signatures and maintains inputs that discover new paths
- **Energy-based input selection** (`Corpus.selectForMutation()`): Prioritizes rare coverage paths when selecting inputs to mutate
- **Multiple mutation strategies**: Supports both `Fuzzable` protocol-based mutations and composable `Mutator` types with domain-specific strategies (phone numbers, SQL injection, XSS, etc.)
- **Value profile guidance** (`FuzzEngine.swift` lines 149-151, 545-548): Already tracks comparison operands and prioritizes inputs that make progress toward solving comparisons
- **String dictionary capture** (lines 154-156): Captures magic strings at runtime for dictionary-based mutations

### Where MOPT Can Be Applied

**1. Mutation Operator Scheduling** (Direct Application)

PropertyTestingKit currently applies all mutations from a `Mutator` uniformly:

```swift
// Current: Mutator.mutate() returns all mutations equally
func mutate(_ value: Value) -> [Value]

// In FuzzEngine (line 669):
var mutations = mutatorMutate?(parent) ?? mutateInput(parent)
guard let m = mutations.randomElement() else { continue }
```

MOPT's approach suggests tracking which mutation strategies discover new coverage most frequently and adjusting their selection probability. For example, if `IntBoundaryMutator` consistently finds more coverage than `PowerOfTwoMutator`, it should be selected more often.

**2. Per-Type Strategy Learning**

PropertyTestingKit's `ComposedMutator` (lines 64-81 in `Mutator.swift`) combines multiple strategies but treats them equally:

```swift
public func mutate(_ value: Value) -> [Value] {
    mutators.flatMap { $0.mutate(value) }  // All strategies equally weighted
}
```

An MOPT-inspired enhancement would track success rates per sub-mutator and implement weighted sampling when selecting which mutation to apply.

**3. Multi-Component Mutation Strategy Selection**

`FuzzEngine` already implements multiple mutation strategies (lines 936-964):
- Single-component mutations (original Fuzzable behavior)
- Multi-component mutations (lines 967-991)
- Arithmetic relationship mutations (lines 993-1047)
- String dictionary mutations (lines 1079-1135)
- Target-directed mutations from value profiling (lines 1143-1223)

These strategies are currently applied with fixed logic. MOPT suggests learning which strategy classes work best for the current target and adapting the mix dynamically.

**4. Value Profile Mutation Selection**

PropertyTestingKit's value profiling (lines 672-680) already prioritizes inputs that make comparison progress, but MOPT's approach could enhance this by tracking which *types of mutations* (arithmetic vs. bitwise vs. dictionary-based) most effectively solve comparison constraints.

---

## Concrete Recommendations

### Recommendation 1: Add Mutation Strategy Effectiveness Tracking

**Implementation**: Extend `FuzzEngine` to track per-strategy coverage discovery rates.

```swift
// New type to track mutation effectiveness
private struct MutationStrategyTracker {
    enum Strategy: Hashable {
        case singleComponent(type: String)
        case multiComponent
        case arithmetic
        case stringDictionary
        case valueProfileDirected
        case mutatorBased(name: String)  // For custom Mutators
    }

    // Track: (new coverage discovered, total attempts)
    private var stats: [Strategy: (hits: Int, attempts: Int)] = [:]

    mutating func recordAttempt(_ strategy: Strategy, discoveredNewCoverage: Bool) {
        let (hits, attempts) = stats[strategy, default: (0, 0)]
        stats[strategy] = (
            hits: hits + (discoveredNewCoverage ? 1 : 0),
            attempts: attempts + 1
        )
    }

    func successRate(for strategy: Strategy) -> Double {
        guard let (hits, attempts) = stats[strategy], attempts > 0 else { return 0.0 }
        return Double(hits) / Double(attempts)
    }

    // PSO-inspired: compute selection weights with exploration bonus
    func weights(explorationFactor: Double = 0.1) -> [Strategy: Double] {
        var weights: [Strategy: Double] = [:]
        for strategy in stats.keys {
            let successRate = self.successRate(for: strategy)
            // Add exploration bonus to prevent premature convergence
            weights[strategy] = successRate + explorationFactor
        }
        return weights
    }
}
```

**Integration Point**: Add to `FuzzEngine` around line 190 with other tracking state:

```swift
private let mutationStrategyTracker = MutationStrategyTracker()
```

Update mutation selection (around line 669) to use weighted sampling instead of uniform random:

```swift
// Instead of: mutations.randomElement()
// Use: weightedRandomSelection(mutations, weights: strategyWeights)
```

### Recommendation 2: Implement Adaptive Mutation Strategy Selection

**Implementation**: Add a configuration option and three-phase pipeline similar to MOPT.

```swift
// Add to FuzzEngine.Config (around line 129)
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable adaptive mutation scheduling (MOPT-style)
    public var enableAdaptiveMutation: Bool

    /// Pilot phase iterations before starting adaptation
    public var pilotPhaseIterations: Int

    /// Exploration bonus to prevent premature convergence (0.0-1.0)
    public var mutationExplorationFactor: Double

    public init(
        // ... existing parameters ...
        enableAdaptiveMutation: Bool = true,
        pilotPhaseIterations: Int = 1000,
        mutationExplorationFactor: Double = 0.1
    ) {
        // ... existing assignments ...
        self.enableAdaptiveMutation = enableAdaptiveMutation
        self.pilotPhaseIterations = pilotPhaseIterations
        self.mutationExplorationFactor = mutationExplorationFactor
    }
}
```

**Three-Phase Implementation** (modify `runFuzzing` around line 624):

```swift
// Phase 2: Coverage-guided fuzzing with adaptive mutation
var iteration = seedInputs.count
var isInPilotPhase = config.enableAdaptiveMutation && iteration < config.pilotPhaseIterations

while iteration < config.maxIterations {
    // ... existing stopping conditions ...

    if config.enableAdaptiveMutation && iteration == config.pilotPhaseIterations {
        isInPilotPhase = false
        if config.verbose {
            print("[Fuzz] Pilot phase complete, enabling adaptive mutation")
            // Print strategy effectiveness stats
            for (strategy, rate) in mutationStrategyTracker.successRates() {
                print("[Fuzz]   \(strategy): \(rate * 100)% success rate")
            }
        }
    }

    // Mutate existing corpus entry
    let selectedIndex = /* existing selection logic */
    let parent = corpus.entries[selectedIndex].input

    // Select mutation strategy adaptively
    let strategy: MutationStrategy
    let mutations: [(repeat each Input)]

    if isInPilotPhase {
        // Pilot phase: try all strategies uniformly
        strategy = allStrategies.randomElement()!
        mutations = applyStrategy(strategy, to: parent)
    } else {
        // Core phase: use weighted selection based on learned effectiveness
        let weights = mutationStrategyTracker.weights(
            explorationFactor: config.mutationExplorationFactor
        )
        strategy = weightedRandomSelection(from: weights)
        mutations = applyStrategy(strategy, to: parent)
    }

    guard let mutated = mutations.randomElement() else { continue }

    // ... run test, capture coverage ...

    // Record strategy effectiveness
    if config.enableAdaptiveMutation {
        mutationStrategyTracker.recordAttempt(strategy, discoveredNewCoverage: addedForCoverage)
    }
}
```

### Recommendation 3: Track Per-Mutator Effectiveness in ComposedMutator

**Implementation**: Enhance `ComposedMutator` to track which sub-mutators are most effective.

```swift
// New adaptive version of ComposedMutator
public struct AdaptiveComposedMutator<Value: Sendable>: Mutator, Sendable {
    private let mutators: [AnyMutator<Value>]
    private var effectiveness: [Int: (hits: Int, attempts: Int)] = [:]

    public var seeds: [Value] {
        mutators.flatMap(\.seeds)
    }

    public func mutate(_ value: Value) -> [Value] {
        // Instead of returning all mutations, return tagged mutations
        // that can be tracked back to their source mutator
        var tagged: [(mutatorIndex: Int, mutation: Value)] = []
        for (index, mutator) in mutators.enumerated() {
            let mutations = mutator.mutate(value)
            for mutation in mutations {
                tagged.append((index, mutation))
            }
        }

        // Return mutations with tracking metadata
        // (This requires changes to the mutation pipeline to support tracking)
        return tagged.map(\.mutation)
    }

    // New: Select mutation based on effectiveness
    public func selectAdaptiveMutation(_ value: Value) -> Value? {
        // Compute weights based on past success
        let weights = mutators.indices.map { index -> Double in
            guard let (hits, attempts) = effectiveness[index], attempts > 0 else {
                return 1.0  // Uniform weight for unexplored mutators
            }
            return Double(hits) / Double(attempts) + 0.1  // Exploration bonus
        }

        // Weighted selection of mutator
        guard let selectedIndex = weightedRandomIndex(weights: weights) else {
            return nil
        }

        let mutations = mutators[selectedIndex].mutate(value)
        return mutations.randomElement()
    }

    // Called by FuzzEngine to update effectiveness stats
    public mutating func recordResult(mutatorIndex: Int, discoveredNewCoverage: Bool) {
        let (hits, attempts) = effectiveness[mutatorIndex, default: (0, 0)]
        effectiveness[mutatorIndex] = (
            hits: hits + (discoveredNewCoverage ? 1 : 0),
            attempts: attempts + 1
        )
    }
}
```

### Recommendation 4: Extend Value Profile with Mutation Type Tracking

**Implementation**: Track which mutation types most effectively solve comparison constraints.

```swift
// Add to ValueProfileTracker (or create new ComparisonSolvingTracker)
private struct ComparisonSolvingTracker {
    enum MutationType {
        case targetDirected      // Mutations toward specific target values
        case arithmetic          // Relationship-based Int mutations
        case dictionary          // String dictionary substitutions
        case random              // Standard Fuzzable mutations
    }

    // Track: which mutation types solved which comparison types
    private var solveHistory: [(comparisonId: UInt64, solvedBy: MutationType)] = []

    mutating func recordSolve(comparisonId: UInt64, solvedBy: MutationType) {
        solveHistory.append((comparisonId, solvedBy))
    }

    func effectiveness(for mutationType: MutationType) -> Double {
        let solved = solveHistory.filter { $0.solvedBy == mutationType }.count
        let total = solveHistory.count
        return total > 0 ? Double(solved) / Double(total) : 0.0
    }

    // Recommend mutation mix for current comparison targets
    func recommendedMix() -> [MutationType: Double] {
        // Recent history matters more
        let recentHistory = solveHistory.suffix(100)
        var counts: [MutationType: Int] = [:]
        for record in recentHistory {
            counts[record.solvedBy, default: 0] += 1
        }

        // Convert to normalized weights
        let total = Double(recentHistory.count)
        var mix: [MutationType: Double] = [:]
        for (type, count) in counts {
            mix[type] = (Double(count) / total) + 0.1  // Exploration bonus
        }
        return mix
    }
}
```

### Recommendation 5: Add Pacemaker Mode

**Implementation**: Periodically switch between learned distribution and uniform distribution to prevent local optima.

```swift
// Add to FuzzEngine (around mutation selection logic, line 654)
private var iterationsSinceLastPacemaker = 0
private let pacemakerInterval = 500  // Switch to uniform every 500 iterations

// In mutation selection logic:
let usePacemakerMode = config.enableAdaptiveMutation
    && !isInPilotPhase
    && iterationsSinceLastPacemaker >= pacemakerInterval

if usePacemakerMode {
    // Pacemaker: use uniform random selection
    strategy = allStrategies.randomElement()!
    iterationsSinceLastPacemaker = 0
    if config.verbose {
        print("[Fuzz] Pacemaker mode: uniform exploration")
    }
} else {
    // Normal: use learned weights
    strategy = weightedRandomSelection(from: mutationStrategyTracker.weights())
    iterationsSinceLastPacemaker += 1
}
```

---

## Implementation Priority

**High Priority** (immediate value):
1. **Recommendation 1**: Mutation strategy effectiveness tracking - provides visibility into what's working
2. **Recommendation 2**: Basic adaptive selection with pilot/core phases - core MOPT functionality

**Medium Priority** (incremental improvements):
3. **Recommendation 3**: Per-mutator tracking in composed mutators - helps users optimize custom mutators
4. **Recommendation 5**: Pacemaker mode - prevents premature convergence

**Lower Priority** (nice to have):
5. **Recommendation 4**: Value profile mutation type tracking - already have good value profiling, this is optimization

---

## Notes on Differences from AFL

PropertyTestingKit's architecture differs from AFL in ways that affect MOPT adoption:

1. **Type-Safe Mutations**: Swift's strong typing and PropertyTestingKit's `Mutator` protocol provide more structured mutation strategies than AFL's byte-level operations. This is actually an *advantage* for MOPT - it's easier to track effectiveness of semantic mutations (e.g., "SQL injection strategy") than low-level bit flips.

2. **Composable Mutators**: PropertyTestingKit's `ComposedMutator` already provides infrastructure for combining strategies. MOPT's weighted selection integrates naturally here.

3. **Value Profile Integration**: PropertyTestingKit already has comparison tracking (something AFL requires compiler instrumentation for). MOPT's mutation scheduling can leverage this existing infrastructure.

4. **Swift Testing Integration**: PropertyTestingKit targets Swift Testing framework rather than executable fuzzing. This means mutation effectiveness can be measured per-test-function rather than per-binary, potentially enabling more fine-grained adaptation.

5. **No Deterministic Stage**: AFL has separate deterministic and havoc stages. PropertyTestingKit uses only coverage-guided mutation. MOPT can apply more broadly across all mutation decisions rather than just the havoc stage.

---

## Potential Challenges

1. **Smaller Iteration Counts**: PropertyTestingKit defaults to 10,000 iterations vs AFL's millions. The pilot phase may consume a larger proportion of the fuzzing budget. Consider shorter pilot phases (500-1000 iterations) or adaptive pilot phase termination.

2. **Multiple Input Types**: PropertyTestingKit supports variadic input types `(repeat each Input)`. Tracking strategy effectiveness across different type combinations may require per-parameter-pack strategy tracking rather than global tracking.

3. **Overhead**: Strategy tracking adds computational overhead. Ensure this is measured and kept below 5% of total fuzzing time.

4. **Integration with Existing Features**: PropertyTestingKit already has value profile guidance, string dictionaries, and relationship mutations. MOPT's mutation scheduling should complement rather than replace these features. Consider hierarchical scheduling: first select strategy class (value-profile-directed vs random mutation), then select specific operator within that class.

---

## References

- Lyu et al., "MOPT: Optimized Mutation Scheduling for Fuzzers", USENIX Security 2019
- AFL (American Fuzzy Lop): https://lcamtuf.coredump.cx/afl/
- PropertyTestingKit repository: Current implementation of coverage-guided fuzzing in Swift
