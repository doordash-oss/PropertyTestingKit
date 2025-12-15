# TOFU: Target-Oriented FUzzer

**Paper:** Wang, Liblit, Reps, "TOFU: Target-Oriented FUzzer", arXiv:2004.14375, 2020
**URL:** https://arxiv.org/abs/2004.14375

---

## Paper Summary

TOFU addresses a fundamental limitation in coverage-guided fuzzing: while traditional fuzzers like AFL aim to maximize overall code coverage in an undirected manner, many practical scenarios require reaching specific target locations in the program (e.g., recently patched code, functions suspected of containing vulnerabilities, or security-critical code paths). Directed fuzzing focuses resources on reaching these targets rather than exploring the entire program uniformly, but existing directed fuzzers often struggle with efficiency and target reachability.

TOFU introduces two key innovations to improve directed fuzzing effectiveness. First, it employs a distance metric that scores each input according to how close its execution trace gets to the target locations. This distance-guided search biases the fuzzer toward inputs that make progress toward targets, similar to how AFLGo uses static analysis to compute control flow distances. Second, and more importantly, TOFU is input-structure aware - it accepts a specification of the program's expected input format (typically a grammar or structure specification) and uses this knowledge to generate more semantically valid inputs. This is particularly important for programs with complex input formats like XML, JSON, or command-line interfaces where purely byte-level mutations often produce invalid inputs that are rejected early in parsing, never reaching deeper program logic where targets may reside.

Experimental evaluation on xmllint demonstrated substantial improvements: TOFU is 28% faster than AFLGo (a state-of-the-art directed fuzzer) while reaching 45% more target locations. Ablation studies confirm that both distance-guided search and input structure awareness contribute significantly to performance. The input structure knowledge proves especially valuable for programs with strict input format requirements, enabling TOFU to generate inputs that pass validation and reach target code more effectively than structure-unaware byte-level mutations.

---

## Key Strategies/Techniques

1. **Distance-Guided Input Prioritization**: TOFU uses a distance metric to score each input based on how close its execution trace gets to target locations. Inputs that reach basic blocks closer to targets receive higher priority for mutation, similar to AFLGo's approach but enhanced with input structure awareness.

2. **Input-Structure-Aware Fuzzing**: TOFU accepts a specification of valid input formats (grammars or structure descriptions) and uses this knowledge during mutation. This ensures generated inputs are more likely to be syntactically valid and reach deeper program logic rather than being rejected during early parsing stages.

3. **Grammar-Based Option Space Exploration**: For programs with command-line options or configuration parameters, TOFU first fuzzes the option space using grammar-based mutations to identify which options enable code coverage near the targets. It then selects configurations that enable target-proximal code before fuzzing the main input files.

4. **Combined Structural and Byte-Level Mutations**: Unlike purely grammar-based fuzzers that generate syntactically valid inputs, TOFU combines structure-aware generation with traditional byte-level mutations. This hybrid approach maintains both semantic validity (to reach deep code) and the ability to trigger edge cases through malformed inputs.

5. **Target-Oriented Seed Selection**: TOFU prioritizes corpus entries that have historically reached basic blocks closer to target locations when selecting seeds for mutation, focusing fuzzing resources on the most promising paths toward targets.

6. **Iterative Distance Refinement**: As fuzzing progresses and new program paths are discovered, TOFU updates its understanding of which inputs are closest to targets, creating a dynamic search that adapts to the program's actual runtime behavior rather than relying solely on static analysis.

---

## Applicability to PropertyTestingKit

**Medium-to-High Applicability** - TOFU's techniques are relevant to PropertyTestingKit, though the library's focus differs from traditional executable fuzzing. Several concepts translate well while others require adaptation.

### Current PropertyTestingKit Architecture

PropertyTestingKit implements coverage-guided fuzzing with:

- **Coverage-guided corpus management** (`Corpus.swift`): Tracks coverage signatures and maintains inputs discovering new paths
- **Energy-based input selection** (`Corpus.selectForMutation()`): Prioritizes inputs with rare coverage features
- **Multiple mutation strategies**: Protocol-based `Fuzzable` mutations and composable `Mutator` types
- **Value profile guidance** (`FuzzEngine.swift`): Tracks comparison operands and prioritizes inputs making progress toward solving comparisons
- **String dictionary capture**: Captures magic strings at runtime for targeted mutations
- **Relationship-aware mutations**: Generates related values across multiple input parameters

PropertyTestingKit currently operates in an **undirected** mode, aiming to maximize overall code coverage rather than reaching specific target locations.

### Where TOFU Can Be Applied

**1. Target-Oriented Testing Mode** (New Feature)

PropertyTestingKit could add a directed fuzzing mode where users specify target locations (functions, line numbers, or code paths) they want the fuzzer to reach. This would be valuable for:

- **Regression testing**: Focus on recently modified code after patches
- **Security-critical code**: Prioritize reaching authentication, authorization, or cryptographic functions
- **Hard-to-reach code**: Target branches with low coverage in previous fuzzing runs
- **Specific bug reproduction**: Guide fuzzer toward code paths suspected of containing bugs

**2. Input Structure Awareness** (Partial Application)

TOFU's input structure awareness has limited but valuable applicability to PropertyTestingKit:

**Applicable:**
- PropertyTestingKit's custom `Mutator` protocol already provides structure-aware mutations (e.g., `PhoneNumberMutator`, `SQLInjectionMutator`, `EmailMutator`)
- These mutators encode knowledge of valid input formats similar to TOFU's grammar specifications
- Could enhance `ComposedMutator` to prioritize structure-preserving mutations when testing input validation code

**Less Applicable:**
- PropertyTestingKit targets Swift Testing framework with type-safe inputs, not byte-stream parsing
- Swift's strong typing already provides structural constraints that C programs lack
- Most PropertyTestingKit tests work with well-typed data structures (Strings, Ints, custom types) rather than parsing raw bytes

**3. Distance Metrics for Coverage Guidance** (High Value)

TOFU's distance-based prioritization could enhance PropertyTestingKit's corpus selection:

**Current approach:**
```swift
// Corpus.swift: selectForMutation() uses energy based on edge rarity
// More energy to rare edges, but no notion of "distance to target"
```

**TOFU-inspired enhancement:**
- Compute "distance" from each corpus entry to target locations using control flow graph analysis
- Prioritize mutating inputs that executed basic blocks closer to targets
- Combine with existing energy-based selection for hybrid priority scoring

**4. Multi-Stage Fuzzing for Complex Inputs** (Applicable)

TOFU's approach of fuzzing option spaces before input files translates to PropertyTestingKit's multi-parameter testing:

**Current:** PropertyTestingKit mutates all input parameters simultaneously
**TOFU-inspired:** First explore parameter combinations that enable code paths near targets, then focus on those configurations

This is especially relevant for tests with multiple parameters where certain parameter combinations unlock specific code paths.

### Challenges and Limitations

**1. Lack of Control Flow Graph Information**

TOFU relies on static analysis to compute distances between basic blocks and targets. PropertyTestingKit operates at runtime without access to:
- Control flow graphs of the code under test
- Call graphs
- Static reachability analysis

**Potential solutions:**
- Leverage Swift's upcoming macro system to capture function/line information at compile time
- Use runtime coverage data to build approximate CFGs dynamically
- Require users to specify targets using source locations that can be mapped to coverage hit counters

**2. Different Coverage Granularity**

TOFU operates at the basic block level (AFL-style edge coverage). PropertyTestingKit's coverage might be at different granularity depending on Swift's coverage infrastructure. Distance metrics would need to be adapted to whatever coverage representation is available.

**3. Swift Testing Integration**

PropertyTestingKit targets Swift Testing framework rather than standalone executables. Distance calculations would need to be per-test-function rather than per-binary, potentially requiring separate CFG analysis for each test target.

**4. Type Safety vs. Byte-Level Mutations**

TOFU's combination of structural and byte-level mutations is less applicable to Swift's type-safe environment. PropertyTestingKit can't easily generate "malformed but parseable" inputs the way TOFU does for XML or JSON parsers because Swift's type system prevents many malformation classes at compile time.

---

## Concrete Recommendations

### Recommendation 1: Add Target-Oriented Fuzzing Mode

**Implementation**: Extend `FuzzEngine.Config` to support target specifications and implement distance-guided prioritization.

```swift
// Add to FuzzEngine.Config
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable target-oriented fuzzing mode
    public var targetMode: TargetMode

    public enum TargetMode: Sendable {
        case undirected  // Current behavior: maximize overall coverage
        case directed(targets: [SourceLocation])
    }

    public struct SourceLocation: Sendable {
        let file: String
        let function: String
        let line: Int?
    }
}

// Add distance tracking to corpus entries
// In Corpus.swift
struct Entry<each Input: Sendable>: Sendable {
    // ... existing fields ...

    /// Minimum distance from this input's coverage to any target
    /// Lower is better (0 means target was reached)
    var distanceToTarget: Int?
}
```

**Distance Calculation Strategy:**

Since PropertyTestingKit lacks static CFG analysis, use a dynamic approximation:

```swift
// Runtime distance estimation based on coverage overlap
private func estimateDistanceToTargets(
    executedEdges: Set<UInt64>,
    targetEdges: Set<UInt64>
) -> Int {
    // Distance 0: Executed a target edge directly
    if !executedEdges.isDisjoint(with: targetEdges) {
        return 0
    }

    // Distance 1-N: Use historical data to estimate proximity
    // Track which edges have historically preceded target execution
    var minDistance = Int.max

    for executedEdge in executedEdges {
        if let dist = historicalDistances[executedEdge] {
            minDistance = min(minDistance, dist)
        }
    }

    return minDistance == Int.max ? 1000 : minDistance
}

// Build historical distance map during fuzzing
private var historicalDistances: [UInt64: Int] = [:]

private func updateHistoricalDistances(
    executionSequence: [UInt64],
    reachedTarget: Bool
) {
    guard reachedTarget else { return }

    // Work backwards from target, assigning distances
    for (index, edge) in executionSequence.enumerated().reversed() {
        let distanceToTarget = executionSequence.count - index

        // Update with minimum observed distance
        if let existing = historicalDistances[edge] {
            historicalDistances[edge] = min(existing, distanceToTarget)
        } else {
            historicalDistances[edge] = distanceToTarget
        }
    }
}
```

**Integration into Corpus Selection:**

```swift
// Modify Corpus.selectForMutation() to incorporate distance
public mutating func selectForMutation() -> Int? {
    guard !entries.isEmpty else { return nil }

    switch config.targetMode {
    case .undirected:
        // Current behavior: energy-based selection
        return selectByEnergy()

    case .directed:
        // TOFU-inspired: combine energy and distance
        return selectByEnergyAndDistance()
    }
}

private func selectByEnergyAndDistance() -> Int? {
    // Compute weights combining energy (coverage rarity) and distance
    let weights = entries.enumerated().map { (index, entry) -> Double in
        let energyWeight = Double(entry.energy)

        // Distance factor: closer to target = higher weight
        let distanceFactor = entry.distanceToTarget.map { dist -> Double in
            // Exponential decay: distance 0 = 1.0, distance 10 = 0.1, etc.
            return exp(-0.2 * Double(dist))
        } ?? 0.01  // Default low weight for unmeasured distance

        // Combine: high energy OR close to target = high selection probability
        return energyWeight * distanceFactor
    }

    return weightedRandomIndex(weights: weights)
}
```

### Recommendation 2: Add Structure-Aware Mutation Hints

**Implementation**: Allow `Mutator` implementations to declare whether they preserve input structure, and prioritize structure-preserving mutations based on context.

```swift
// Extend Mutator protocol with structure preservation hints
public protocol Mutator<Value>: Sendable {
    associatedtype Value: Sendable

    var seeds: [Value] { get }
    func mutate(_ value: Value) -> [Value]

    // New: Hint about whether mutations preserve structural validity
    var preservesStructure: Bool { get }
}

extension Mutator {
    // Default: unknown/mixed
    public var preservesStructure: Bool { false }
}

// Example: Structure-preserving mutator
public struct EmailMutator: Mutator {
    public var preservesStructure: Bool { true }  // Always generates valid email format

    public func mutate(_ value: String) -> [String] {
        // Mutations maintain email structure
        return [
            value.replacingOccurrences(of: "@", with: "+test@"),
            "admin@" + value.split(separator: "@").last.map(String.init) ?? "example.com"
        ]
    }
}

// Usage in FuzzEngine
private func selectMutationStrategy(
    parent: (repeat each Input),
    context: MutationContext
) -> MutationStrategy {
    // When far from targets, prefer structure-preserving mutations
    // to ensure inputs remain valid and reach deeper code
    if context.distanceToTarget > 5 {
        if let mutator = mutatorMutate, mutator.preservesStructure {
            return .structureAware
        }
    }

    // When close to targets, allow more aggressive mutations
    return .standard
}
```

### Recommendation 3: Multi-Stage Parameter Space Exploration

**Implementation**: For tests with multiple parameters, implement TOFU-inspired two-stage fuzzing.

```swift
// Add to FuzzEngine.Config
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable multi-stage parameter exploration for directed fuzzing
    public var multiStageParameterExploration: Bool

    /// Iterations to spend exploring parameter space before focused fuzzing
    public var parameterExplorationIterations: Int
}

// Modify runFuzzing() to add parameter exploration stage
private func runFuzzing() async throws {
    // ... existing seed evaluation ...

    // Stage 1: Parameter space exploration (for directed mode)
    if case .directed(let targets) = config.targetMode,
       config.multiStageParameterExploration {

        print("[Fuzz] Stage 1: Exploring parameter space for target proximity")

        var parameterCombinations: [ConfigHash: Set<UInt64>] = [:]

        for iteration in 0..<config.parameterExplorationIterations {
            // Generate diverse parameter combinations
            let input = generateRandomInput()
            let coverage = try await evaluateInput(input)

            // Track which parameter combinations enable target-proximal coverage
            let configHash = computeParameterConfigHash(input)
            parameterCombinations[configHash, default: []].formUnion(coverage)
        }

        // Identify parameter configurations closest to targets
        let targetProximalConfigs = parameterCombinations
            .sorted { estimateDistance($0.value, to: targets) < estimateDistance($1.value, to: targets) }
            .prefix(10)  // Keep top 10 configurations

        print("[Fuzz] Found \(targetProximalConfigs.count) target-proximal configurations")

        // Seed corpus with these configurations
        for (configHash, _) in targetProximalConfigs {
            let seedInput = generateInputWithConfig(configHash)
            try await evaluateSeed(seedInput)
        }
    }

    // Stage 2: Focused fuzzing (existing coverage-guided loop)
    print("[Fuzz] Stage 2: Coverage-guided fuzzing")
    // ... existing fuzzing loop ...
}

private func computeParameterConfigHash<each Input>(_ input: (repeat each Input)) -> ConfigHash {
    // Hash representing the "configuration" of parameters
    // For example, which string patterns, which numeric ranges, etc.
    var hasher = Hasher()

    repeat (each input).hash(into: &hasher)

    return ConfigHash(hasher.finalize())
}
```

### Recommendation 4: Dynamic Distance Learning

**Implementation**: Build approximate distance metrics dynamically during fuzzing rather than requiring static analysis.

```swift
// Add to FuzzEngine
private struct DynamicDistanceTracker {
    // Maps: edge -> minimum observed distance to target
    private var edgeDistances: [UInt64: Int] = [:]

    // Maps: edge -> edges that followed it in executions reaching targets
    private var edgeSuccessors: [UInt64: Set<UInt64>] = [:]

    // Target edges we're trying to reach
    private let targetEdges: Set<UInt64>

    mutating func recordExecution(
        coverageSequence: [UInt64],
        reachedTarget: Bool
    ) {
        guard reachedTarget else {
            // Even non-target executions help build successor graph
            for i in 0..<(coverageSequence.count - 1) {
                edgeSuccessors[coverageSequence[i], default: []].insert(coverageSequence[i + 1])
            }
            return
        }

        // Work backwards from target, assigning distances
        var currentDistance = 0
        for edge in coverageSequence.reversed() {
            // Update minimum distance
            if let existing = edgeDistances[edge] {
                edgeDistances[edge] = min(existing, currentDistance)
            } else {
                edgeDistances[edge] = currentDistance
            }

            // Record successor relationship
            if currentDistance > 0 {
                edgeSuccessors[edge, default: []].insert(coverageSequence[coverageSequence.count - currentDistance])
            }

            currentDistance += 1
        }
    }

    func estimateDistance(from edges: Set<UInt64>) -> Int {
        // Best-case distance: minimum across all executed edges
        var minDistance = Int.max

        for edge in edges {
            if let distance = edgeDistances[edge] {
                minDistance = min(minDistance, distance)
            }
        }

        // If we've never seen these edges reach targets,
        // estimate based on successor graph
        if minDistance == Int.max {
            minDistance = estimateDistanceViaSuccessors(from: edges)
        }

        return minDistance
    }

    private func estimateDistanceViaSuccessors(from edges: Set<UInt64>) -> Int {
        // BFS through successor graph to find shortest path to known-distance edges
        var queue: [(edge: UInt64, distance: Int)] = edges.map { ($0, 0) }
        var visited: Set<UInt64> = edges

        while !queue.isEmpty {
            let (edge, distance) = queue.removeFirst()

            // Found an edge with known target distance?
            if let knownDistance = edgeDistances[edge] {
                return distance + knownDistance
            }

            // Explore successors
            guard distance < 10 else { continue }  // Limit search depth

            for successor in edgeSuccessors[edge] ?? [] {
                if !visited.contains(successor) {
                    visited.insert(successor)
                    queue.append((successor, distance + 1))
                }
            }
        }

        return 1000  // Unknown distance
    }
}
```

### Recommendation 5: Target-Oriented Test Harness API

**Implementation**: Provide user-facing API for specifying targets and querying progress.

```swift
// Public API for directed fuzzing
extension FuzzEngine {
    /// Run directed fuzzing toward specific source locations
    public static func fuzzDirected<each Input: Fuzzable>(
        _ test: @escaping (repeat each Input) async throws -> Void,
        targets: [SourceLocation],
        config: Config = Config()
    ) async throws -> DirectedFuzzingResult {

        var modifiedConfig = config
        modifiedConfig.targetMode = .directed(targets: targets)
        modifiedConfig.multiStageParameterExploration = true

        let engine = FuzzEngine(
            test: test,
            config: modifiedConfig,
            coverageHandler: CoverageTracker.shared
        )

        try await engine.runFuzzing()

        return DirectedFuzzingResult(
            targetsReached: engine.reachedTargets,
            totalTargets: targets.count,
            iterationsToReach: engine.targetReachIterations,
            corpus: engine.corpus
        )
    }
}

public struct DirectedFuzzingResult {
    /// Which targets were successfully reached
    public let targetsReached: Set<SourceLocation>

    /// Total number of targets specified
    public let totalTargets: Int

    /// Iterations required to reach each target
    public let iterationsToReach: [SourceLocation: Int]

    /// Final corpus containing inputs that reached targets
    public let corpus: Any  // Type-erased corpus

    public var successRate: Double {
        Double(targetsReached.count) / Double(totalTargets)
    }
}

// Usage example:
@Test func directedFuzzingExample() async throws {
    let result = try await FuzzEngine.fuzzDirected(
        parseXML,
        targets: [
            .init(file: "XMLParser.swift", function: "handleNamespace", line: 145),
            .init(file: "XMLParser.swift", function: "parseAttributes", line: 203)
        ],
        config: .init(maxIterations: 50000)
    )

    print("Reached \(result.successRate * 100)% of targets")
    for (target, iterations) in result.iterationsToReach {
        print("  \(target.function): \(iterations) iterations")
    }
}
```

---

## Implementation Priority

**High Priority** (significant value, feasible implementation):
1. **Recommendation 1**: Target-oriented fuzzing mode with dynamic distance learning - adds valuable directed fuzzing capability
2. **Recommendation 4**: Dynamic distance tracking - enables distance metrics without requiring static analysis infrastructure

**Medium Priority** (useful but requires more infrastructure):
3. **Recommendation 3**: Multi-stage parameter exploration - particularly valuable for tests with multiple parameters
4. **Recommendation 5**: Public API for directed fuzzing - makes the feature accessible to users

**Lower Priority** (incremental improvements):
5. **Recommendation 2**: Structure-aware mutation hints - useful but PropertyTestingKit's type safety already provides structural guarantees

---

## Notes on Differences from TOFU/AFLGo

PropertyTestingKit's architecture differs from traditional directed fuzzers in important ways:

1. **No Static Analysis Infrastructure**: TOFU and AFLGo rely on compile-time static analysis to compute control flow distances. PropertyTestingKit operates purely at runtime and must build distance approximations dynamically based on observed execution patterns.

2. **Type-Safe Testing vs. Byte-Stream Fuzzing**: TOFU's combination of grammar-based and byte-level mutations targets C programs parsing untyped byte streams. PropertyTestingKit works with Swift's type-safe functions, limiting the applicability of "semi-valid" input generation.

3. **Test-Level Granularity**: PropertyTestingKit fuzzes individual test functions rather than entire executables. This means distance metrics and target specifications operate at function-level granularity, potentially enabling more precise targeting than binary-level fuzzing.

4. **Swift Testing Integration**: PropertyTestingKit integrates with Swift Testing framework, not standalone binaries. Coverage tracking and target specification must work within this framework's constraints.

5. **Runtime-Only Coverage**: TOFU uses compile-time instrumentation and static CFG analysis. PropertyTestingKit relies on Swift's runtime coverage facilities, which may provide different granularity and require different distance estimation strategies.

6. **Corpus Reuse**: Unlike AFL-based fuzzers that save corpus to disk, PropertyTestingKit's corpus is typically session-specific. Directed fuzzing mode would benefit from persistent corpus storage to avoid re-exploring parameter spaces across test runs.

---

## Potential Challenges

1. **Target Specification**: TOFU targets specific basic blocks identified through static analysis. PropertyTestingKit needs a user-friendly way to specify targets (function names, source locations, coverage points) without requiring users to understand coverage implementation details.

2. **Distance Metric Accuracy**: Without static CFG analysis, dynamic distance estimation may be less accurate, especially early in fuzzing before sufficient execution history is gathered. The fuzzer may waste iterations exploring distant paths before converging on target-proximal regions.

3. **Multiple Targets**: TOFU's paper focuses on multiple target scenarios. When PropertyTestingKit targets multiple locations, distance calculation must avoid the bias problems identified in AFLGo where harmonic mean distances favor easily-reachable targets over hard-to-reach ones.

4. **Coverage Granularity**: If Swift's coverage tracking operates at coarser granularity (e.g., function-level rather than basic-block-level), distance metrics will be less precise and directed fuzzing less effective.

5. **Overhead**: Distance calculation and historical successor graph tracking add computational overhead. Need to ensure this remains below 10% of total fuzzing time to preserve throughput.

6. **Integration with Existing Features**: PropertyTestingKit already has value profile guidance, comparison tracking, and relationship mutations. Directed fuzzing should complement these features rather than conflict. For example, when should the fuzzer prioritize distance reduction vs. comparison progress?

---

## Open Questions for Further Investigation

1. **Source Location Mapping**: How can PropertyTestingKit map user-specified source locations (file, function, line) to coverage hit counters? Requires compile-time metadata or runtime reflection capabilities.

2. **Coverage Implementation**: What granularity does Swift's coverage tracking provide? Basic block? Statement? Function? This determines the precision of distance metrics.

3. **Static Analysis Integration**: Could PropertyTestingKit leverage Swift's upcoming macro system or compiler plugins to perform lightweight static analysis for CFG distance computation?

4. **Persistent Corpus**: Should directed fuzzing mode save corpus to disk like AFL, enabling incremental progress across fuzzing sessions? This would align with regression testing use cases.

5. **Hybrid Directed/Undirected**: Should PropertyTestingKit support hybrid mode that allocates some iterations to directed fuzzing (target reaching) and some to undirected fuzzing (general coverage exploration)?

---

## Sources

- [TOFU: Target-Oriented FUzzer (arXiv)](https://arxiv.org/abs/2004.14375)
- [Papers With Code: TOFU](https://cs.paperswithcode.com/paper/tofu-target-oriented-fuzzer)
- [DeepAI: TOFU Publication](https://deepai.org/publication/tofu-target-oriented-fuzzer)
- [Directed Greybox Fuzzing (AFLGo Paper)](https://mboehme.github.io/paper/CCS17.pdf)
- [ISC4DGF: Directed Grey-box Fuzzing with LLM](https://arxiv.org/html/2409.14329v1)
- [DiPri: Distance-Based Seed Prioritization](https://dl.acm.org/doi/10.1145/3654440)
- [RLTG: Multi-targets Directed Greybox Fuzzing](https://pmc.ncbi.nlm.nih.gov/articles/PMC10096230/)
- [Seed Selection for Successful Fuzzing](https://dl.acm.org/doi/10.1145/3460319.3464795)
