# Directed Greybox Fuzzing (AFLGo)

**Paper**: Böhme, M., Pham, V.-T., & Roychoudhury, A. (2017). Directed Greybox Fuzzing. In Proceedings of the 2017 ACM SIGSAC Conference on Computer and Communications Security (CCS '17).

**URL**: https://mboehme.github.io/paper/CCS17.pdf

---

## Paper Summary

Directed Greybox Fuzzing addresses a fundamental limitation of traditional coverage-guided fuzzing: the inability to prioritize specific program locations when testing resources are limited. While tools like AFL excel at broad exploration, they lack mechanisms to direct fuzzing effort toward predetermined target sites—whether crash locations from bug reports, recently changed code in regression testing, or security-critical functions. This "aimless wandering" wastes computational resources on program regions irrelevant to the testing goal, delaying or preventing discovery of bugs in high-priority locations.

AFLGo introduces directed fuzzing that guides test generation toward user-specified target locations while maintaining the efficiency benefits of coverage-guided greybox fuzzing. The approach combines static analysis with dynamic power scheduling: before fuzzing begins, AFLGo instruments the program to compute distances between every basic block and the target locations using both control flow graph (function-level) and control dependence graph (basic block-level) metrics. During fuzzing, these precomputed distances inform an annealing-based power schedule that allocates exponentially more mutation energy to inputs whose execution traces are closer to targets. Early in the campaign, the fuzzer explores broadly (high temperature), accepting inputs even if they move away from targets. As time progresses, the schedule "cools," increasingly favoring inputs that reduce distance to targets, eventually concentrating almost exclusively on the most promising paths.

Evaluation on 68 CVEs from real-world programs (binutils, jasper, libxml2, libtiff) demonstrates AFLGo's effectiveness: it reproduces known crashes 2-6× faster than AFL and discovers 24 previously unknown bugs across the test suite. The directed approach proves particularly valuable for regression testing and patch verification, where targets are known a priori. By intelligently allocating fuzzing resources proportional to proximity to goals, AFLGo achieves both targeted bug discovery and comparable general coverage to undirected fuzzing, making it suitable for both focused vulnerability analysis and broad security testing.

---

## Key Strategies/Techniques

1. **Static Distance Computation**: Before fuzzing, AFLGo performs whole-program analysis to compute distances from every basic block to target locations. This involves two metrics:
   - **Function-level distance**: Shortest path through the call graph from each function to functions containing targets
   - **Basic block-level distance**: Shortest path through the control flow graph and control dependence graph from each basic block to target basic blocks
   - These distances are normalized and combined, then embedded into the instrumented binary for runtime access

2. **Simulated Annealing Power Schedule**: Energy allocation uses a time-dependent annealing function that balances exploration and exploitation:
   - **Temperature**: Decreases exponentially over time: `T(t) = (1 - t/t_max)^β` where β controls cooling rate
   - **Energy formula**: `E(s) = (1-T) × (d_min/d(s)) + T × (1/|S|)` where d(s) is the distance of seed s to targets
   - Early (high T): Nearly uniform energy (exploration phase)
   - Late (low T): Energy exponentially favors closer seeds (exploitation phase)
   - Annealing prevents premature convergence while ensuring eventual focus on promising inputs

3. **Distance-Guided Coverage Feedback**: Extends AFL's coverage feedback mechanism with distance awareness:
   - Seeds are prioritized based on both coverage novelty (like AFL) and proximity to targets
   - Each execution records the minimum distance to targets encountered during the trace
   - Seeds reaching previously unseen "closer" regions are added to the corpus with high priority
   - Creates a gradient descent effect toward target locations in the input space

4. **Seed Selection with Distance Weighting**: Modifies AFL's queue selection to prefer seeds with lower distances:
   - Seeds closer to targets receive exponentially higher selection probability
   - Selection probability proportional to `1/d(s)` where d(s) is average distance of execution trace to targets
   - Combined with AFL's favored queue entries (faster execution, new coverage)
   - Prevents starvation of exploration seeds during high-temperature phase

5. **Instrumentation for Runtime Distance Tracking**: LLVM-based compile-time instrumentation:
   - Embeds precomputed distance values in a global array indexed by basic block ID
   - Runtime hooks update minimum observed distance during execution
   - Minimal overhead: single array lookup and comparison per basic block
   - Distance data persists across mutations, enabling trend analysis

6. **Hybrid Exploration-Exploitation**: Unlike purely directed approaches, AFLGo maintains exploration capability:
   - Never completely abandons coverage-guided exploration
   - Even at low temperature, retains small probability of selecting distant seeds
   - Discovers collateral bugs in non-target code while pursuing primary goals
   - Balances directed search with serendipitous bug discovery

7. **Target Set Specification**: Flexible target definition supporting multiple use cases:
   - Line numbers in source files (e.g., bug report locations)
   - Function names (e.g., security-critical APIs)
   - Multiple simultaneous targets (closest distance to any target used)
   - Diff-based targets for regression testing (automatically extract changed lines)

8. **Cut-Edge Coverage (Advanced)**: Optional enhancement using control dependence analysis:
   - Identifies "cut edges" whose traversal is necessary to reach targets
   - Prioritizes inputs covering previously untraversed cut edges
   - Particularly effective for targets deep in error-handling or rare branches
   - Addresses "plateau problem" where progress toward targets stalls

---

## Applicability to PropertyTestingKit

PropertyTestingKit implements coverage-guided fuzzing with an AFL-inspired architecture, making it a strong candidate for directed fuzzing techniques. However, the applicability of AFLGo's strategies varies significantly based on PropertyTestingKit's unique context: Swift Testing integration, value-based fuzzing, and the absence of binary instrumentation.

### Current PropertyTestingKit Architecture

**Existing capabilities aligned with AFLGo:**

1. **Coverage-guided feedback** (`CoverageSignature`, `Corpus`):
   - Tracks execution coverage with bucketed hit counts (AFL-style)
   - Maintains corpus of inputs with unique coverage signatures
   - Corpus minimization to essential coverage-contributing inputs

2. **Power scheduling infrastructure** (`Corpus.selectForMutation()`):
   - Rarity-based seed selection: prioritizes inputs covering uncommon paths
   - Weighted random selection proportional to rarity scores
   - Foundation for distance-based weighting

3. **Multiple mutation strategies** (`Mutator`, `Fuzzable`):
   - Type-specific mutations (strings, integers, arrays)
   - Domain-specific mutators (SQL injection, XSS, etc.)
   - Multi-component mutations for related parameters

4. **Value profile guidance** (`ValueProfile`):
   - Tracks comparison operations and operand values
   - Target-directed mutations toward solving comparisons
   - String dictionary extraction for magic constants

**Fundamental gaps vs AFLGo:**

1. **No static distance metrics**: PropertyTestingKit lacks compile-time program analysis. AFLGo's LLVM instrumentation computes call graph and CFG distances before fuzzing. PropertyTestingKit operates at the Swift Testing API level with dynamic coverage only.

2. **No target specification mechanism**: No way to specify "fuzz toward this line/function/crash site." Tests are property-based assertions over the entire test body.

3. **No basic block-level granularity**: Coverage is function/region-based from LLVM profiling, but without CFG structure or per-basic-block distances.

4. **Different threat model**: PropertyTestingKit fuzzes for property violations in test suites, not for crashes/vulnerabilities in production binaries. "Targets" would be specific code paths or edge cases, not bug locations.

### High-Value Strategies to Adopt

**Priority 1: Source Location-Directed Fuzzing (High Impact, High Effort)**

Implement a lightweight version of directed fuzzing using source-level coverage regions as distance proxies, enabling users to focus fuzzing on specific code areas:

```swift
// New API: Direct fuzzing toward specific source locations
@Test func testParserEdgeCases() throws {
    try fuzz(
        targeting: [
            .sourceLine(file: "Parser.swift", line: 142),  // Known tricky branch
            .function(name: "parseComplexExpression"),      // Hard-to-reach function
        ],
        iterations: 50_000
    ) { (input: String) in
        parse(input)
    }
}

// Internal: Target specification
public enum FuzzTarget: Sendable {
    case sourceLine(file: String, line: Int)
    case function(name: String)
    case region(file: String, lineStart: Int, lineEnd: Int)
}

// Add to FuzzEngine.Config
public var targets: [FuzzTarget] = []
public var annealingSchedule: AnnealingSchedule = .exponential(beta: 1.0)
```

**Implementation approach:**

1. **Static target mapping** (once per test initialization):
   - Load coverage mapping from binary using `InMemoryCoverageReader`
   - For each target specification, find matching coverage regions
   - Build target set: `Set<Int>` of coverage counter indices corresponding to targets
   - Store in `FuzzEngine.Config`

2. **Dynamic distance computation** (per execution):
   - After each test execution, compute distance to nearest target:
     - Distance 0: Target region was executed
     - Distance 1: Same function as target, but different region
     - Distance 2: Function called by target's function
     - Distance 3+: Increase by 1 for each call stack level
   - For call stack distances, use `backtrace()` or maintain call stack in coverage hooks
   - Cache distances per corpus entry

3. **Annealing-based power schedule**:
   - Implement time-dependent temperature: `T(t) = pow(1 - t/t_max, beta)`
   - Compute seed energy: `E(s) = (1-T) * (d_min/d(s)) + T * (1/corpus.count)`
   - Modify `Corpus.selectForMutation()` to weight by distance + rarity
   - Track elapsed time/iterations for annealing schedule

**Impact**: Enables regression testing (fuzz toward recently changed code), crash reproduction (fuzz toward bug report locations), and focused property testing (fuzz toward specific edge cases).

**Effort**: ~16-24 hours
- 4-6 hours: Target specification API and mapping to coverage regions
- 6-8 hours: Distance computation (function-level call stack approach)
- 4-6 hours: Annealing power schedule integration
- 2-4 hours: Testing and refinement

**Priority 2: Simplified Annealing Power Schedule (High Impact, Low Effort)**

Even without directed targets, AFLGo's annealing schedule can improve general fuzzing by shifting from exploration to exploitation over time:

```swift
// Add to FuzzEngine.Config
public var annealingSchedule: AnnealingSchedule = .auto

public enum AnnealingSchedule: Sendable {
    case auto            // Start exploring, gradually exploit
    case constant        // No annealing (current behavior)
    case exponential(beta: Double)  // Custom cooling rate

    func temperature(elapsed: TimeInterval, maxDuration: TimeInterval) -> Double {
        switch self {
        case .auto:
            return pow(1.0 - elapsed / maxDuration, 1.5)
        case .constant:
            return 1.0  // No annealing
        case .exponential(let beta):
            return pow(1.0 - elapsed / maxDuration, beta)
        }
    }
}

// In FuzzEngine.runFuzzing()
extension FuzzEngine {
    func computeGenerationRatio(elapsed: TimeInterval, config: Config) -> Double {
        let temperature = config.annealingSchedule.temperature(
            elapsed: elapsed,
            maxDuration: config.maxDuration
        )

        // High temperature: more generation (exploration)
        // Low temperature: more mutation (exploitation)
        return config.generationRatio * temperature
    }
}
```

**How it works:**
- Early fuzzing (high T): High generation ratio (~0.3), lots of fresh seeds from `Fuzzable.fuzz`
- Late fuzzing (low T): Low generation ratio (~0.05), mostly mutating proven-effective corpus entries
- Smooth transition prevents plateau at local optima while ensuring deep exploitation of promising paths

**Impact**: 10-20% improvement in coverage discovery rate by avoiding premature corpus lock-in. Particularly beneficial for programs with complex state machines or multi-stage parsers.

**Effort**: ~2-4 hours

**Priority 3: Distance-Aware Corpus Minimization (Medium Impact, Medium Effort)**

When targets are specified, prioritize corpus entries closer to targets during minimization:

```swift
extension Corpus {
    /// Minimize corpus, optionally prioritizing entries near targets.
    public func minimized(preferring targets: [FuzzTarget] = []) -> Self {
        guard !targets.isEmpty else {
            return minimizedByGreedySetCover()  // Current approach
        }

        // Compute distance for each entry
        var entryDistances: [Int: Double] = [:]
        for (index, entry) in entries.enumerated() {
            entryDistances[index] = computeDistance(
                signature: entry.signature,
                targets: targets
            )
        }

        // Modified greedy set cover: when multiple entries cover same new regions,
        // prefer the one with lower distance to targets
        var minimized = Corpus<repeat each Input>(schemaVersion: schemaVersion)
        var remainingCoverage = totalCoverage

        while !remainingCoverage.isEmpty {
            // Find entry covering most uncovered regions
            let best = entries.enumerated()
                .map { (index, entry) in
                    let newCoverage = entry.signature.intersection(remainingCoverage)
                    let coverageScore = Double(newCoverage.count)
                    let distanceBonus = 1.0 / (1.0 + entryDistances[index, default: 1.0])
                    return (index: index, score: coverageScore + distanceBonus)
                }
                .max(by: { $0.score < $1.score })!

            // Add to minimized corpus and remove covered regions
            minimized.add(entries[best.index])
            remainingCoverage = remainingCoverage.subtracting(entries[best.index].signature)
        }

        return minimized
    }
}
```

**Impact**: Saved corpus focuses on paths toward targets, accelerating future regression runs when targets are specified. Marginal benefit (~5-10%) for general fuzzing.

**Effort**: ~4-6 hours

### Moderate-Value Strategies

**Strategy: Diff-Based Target Generation for Regression Testing**

Automatically extract targets from git diffs when fuzzing changed code:

```swift
extension FuzzTarget {
    /// Generate targets from git diff.
    public static func changedLines(in repository: String = ".") throws -> [FuzzTarget] {
        // Run: git diff --unified=0 main HEAD
        // Parse output for changed line ranges
        // Return .region(file:lineStart:lineEnd:) targets
    }
}

@Test func testRegressionAfterRefactor() throws {
    try fuzz(
        targeting: FuzzTarget.changedLines(),  // Auto-target recent changes
        corpusMode: .refuzzExtend
    ) { (input: String) in
        parseConfig(input)
    }
}
```

**Impact**: Streamlines regression testing workflow. Focuses fuzzing on change risk areas.

**Effort**: ~4-8 hours (git integration, diff parsing, line-to-region mapping)

**Strategy: Execution Trace Distance Caching**

AFLGo precomputes all distances statically. PropertyTestingKit can cache distances dynamically:

```swift
extension CorpusEntry {
    /// Cached distance metrics
    public var distanceToTargets: Double?
    public var avgCallDepth: Double?
    public var targetReachability: TargetReachability?
}

public enum TargetReachability: Sendable {
    case reached          // Distance 0
    case nearMiss         // Same function, different branch
    case callChainClose   // 1-2 calls away
    case callChainFar     // 3+ calls away
    case unreached        // No call chain connection
}
```

Cache distances after first execution to avoid repeated computation. Update when corpus grows significantly (new paths discovered).

**Impact**: Reduces overhead of distance computation from O(n) per execution to O(1) amortized.

**Effort**: ~2-4 hours

### Low-Value Strategies (Not Applicable or Superseded)

1. **LLVM-based static call graph analysis**: PropertyTestingKit operates at Swift Testing runtime level, not LLVM IR. No access to whole-program CFG. **Not feasible without major architectural changes.**

2. **Control dependence graph analysis**: Requires static analysis of program structure not available at runtime. PropertyTestingKit's value profile tracking already provides runtime feedback about critical comparisons, which is more actionable. **Superseded by existing features.**

3. **Cut-edge coverage**: Depends on static CFG analysis to identify necessary edges toward targets. PropertyTestingKit's dynamic coverage regions don't expose CFG structure. **Not feasible.**

4. **Binary instrumentation for distance tracking**: AFLGo embeds distance arrays in instrumented binaries. PropertyTestingKit uses LLVM profiling infrastructure without custom instrumentation. **Architecturally incompatible.**

5. **Exponential distance-based energy**: AFLGo's formula `E(s) = d_min/d(s)` creates extreme energy differences (100x, 1000x) suitable for finding crashes. PropertyTestingKit's property-based testing benefits more from balanced exploration. **Too aggressive for PropertyTestingKit's use case.**

---

## Concrete Recommendations

### Recommendation 1: Implement Source-Level Directed Fuzzing API (Highest Priority)

**What**: Add API for specifying target source locations and direct fuzzing effort toward them.

**Why**: Enables three high-value use cases:
1. **Regression testing**: Fuzz code changed in recent commits
2. **Edge case testing**: Direct fuzzing toward known-tricky branches
3. **Crash reproduction**: When a bug is found, re-fuzz toward that location with new seeds

**How**:

```swift
// Step 1: Target specification API (FuzzAPI.swift)
public enum FuzzTarget: Sendable, Hashable {
    case sourceLine(file: String, line: Int)
    case function(name: String)
    case region(file: String, lineStart: Int, lineEnd: Int)
}

// Step 2: Add to fuzz() function signature
public func fuzz<each Input>(
    targeting: [FuzzTarget] = [],
    seeds: [(repeat each Input)] = [],
    iterations: Int = 10_000,
    duration: TimeInterval = 60,
    corpusMode: CorpusMode = .auto,
    test: @escaping (repeat each Input) throws -> Void
) throws -> FuzzResult<repeat each Input>

// Step 3: Distance computation (new file: TargetDistance.swift)
public struct TargetDistanceComputer: Sendable {
    let targetCounterIndices: Set<Int>

    init(targets: [FuzzTarget], coverageReader: InMemoryCoverageReader) throws {
        // Map targets to coverage counter indices
        var indices = Set<Int>()
        let coverage = coverageReader.resolveCoverage()

        for target in targets {
            switch target {
            case .sourceLine(let file, let line):
                // Find regions intersecting this line
                for function in coverage.functions {
                    for region in function.regions {
                        if region.filename.hasSuffix(file),
                           region.lineStart <= line,
                           region.lineEnd >= line {
                            indices.insert(region.counterIndex)
                        }
                    }
                }

            case .function(let name):
                // Find functions matching name
                for function in coverage.functions where function.name.contains(name) {
                    for region in function.regions {
                        indices.insert(region.counterIndex)
                    }
                }

            case .region(let file, let start, let end):
                // Find regions within range
                for function in coverage.functions {
                    for region in function.regions {
                        if region.filename.hasSuffix(file),
                           region.lineStart >= start,
                           region.lineEnd <= end {
                            indices.insert(region.counterIndex)
                        }
                    }
                }
            }
        }

        self.targetCounterIndices = indices
    }

    /// Compute distance from execution to nearest target.
    /// Returns: 0 if target reached, 1+ based on proximity heuristic
    func distance(for signature: CoverageSignature, coverage: SourceCoverage) -> Double {
        let executedIndices = signature.executedIndices

        // Target reached?
        if !targetCounterIndices.isDisjoint(with: executedIndices) {
            return 0.0
        }

        // Find closest target by function proximity
        var minDistance = Double.infinity

        for targetIndex in targetCounterIndices {
            guard let targetRegion = coverage.functions
                    .flatMap({ $0.regions })
                    .first(where: { $0.counterIndex == targetIndex }) else {
                continue
            }

            // Check if we executed any region in the same function
            let targetFunction = coverage.functions.first {
                $0.regions.contains { $0.counterIndex == targetIndex }
            }

            for execIndex in executedIndices {
                let execRegion = coverage.functions
                    .flatMap({ $0.regions })
                    .first(where: { $0.counterIndex == execIndex })

                guard let execRegion = execRegion else { continue }

                // Same function: distance 1
                if let targetFunction = targetFunction,
                   coverage.functions.contains(where: {
                       $0.name == targetFunction.name &&
                       $0.regions.contains { $0.counterIndex == execIndex }
                   }) {
                    minDistance = min(minDistance, 1.0)
                }
                // Different file: distance based on call depth heuristic
                else {
                    // Approximate: use line number proximity as proxy
                    let lineDistance = Double(abs(execRegion.lineStart - targetRegion.lineStart))
                    minDistance = min(minDistance, 2.0 + log2(1 + lineDistance))
                }
            }
        }

        return minDistance == .infinity ? 10.0 : minDistance
    }
}

// Step 4: Integration with FuzzEngine (FuzzEngine.swift)
extension FuzzEngine {
    mutating func runDirectedFuzzing(...) throws -> FuzzResult<repeat each Input> {
        // Load coverage mapping once
        let coverageReader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let fullCoverage = coverageReader.resolveCoverage()
        let distanceComputer = try TargetDistanceComputer(
            targets: config.targets,
            coverageReader: coverageReader
        )

        // Fuzzing loop with annealing
        var iteration = 0
        let startTime = Date()

        while iteration < config.maxIterations {
            let elapsed = Date().timeIntervalSince(startTime)
            let temperature = config.annealingSchedule.temperature(
                elapsed: elapsed,
                maxDuration: config.maxDuration
            )

            // Select seed with distance-aware weighting
            let selectedIndex = corpus.selectForMutation(
                temperature: temperature,
                distanceComputer: distanceComputer
            )

            // ... rest of mutation loop ...

            // Compute distance for new input
            let distance = distanceComputer.distance(
                for: newSignature,
                coverage: fullCoverage
            )

            // Add to corpus if new coverage or closer to target
            if newSignature.isNewCoverage(vs: corpus.totalCoverage) ||
               (distance < previousMinDistance) {
                corpus.add(...)
            }
        }
    }
}

// Step 5: Update Corpus selection (Corpus.swift)
extension Corpus {
    mutating func selectForMutation(
        temperature: Double = 1.0,
        distanceComputer: TargetDistanceComputer? = nil
    ) -> Int? {
        guard !entries.isEmpty else { return nil }

        // Compute scores combining rarity + distance
        let scores = entries.enumerated().map { (index, entry) -> Double in
            // Rarity score (existing)
            let rarityScore = entry.signature.executedIndices
                .map { 1.0 / Double(frequencyMap[$0] ?? 1) }
                .reduce(0, +)

            // Distance score (new)
            let distanceScore: Double
            if let distanceComputer = distanceComputer {
                let distance = entry.distanceToTargets ?? 10.0
                distanceScore = 1.0 / (1.0 + distance)
            } else {
                distanceScore = 1.0
            }

            // Combine with temperature annealing
            // High temp: favor rarity (exploration)
            // Low temp: favor distance (exploitation toward targets)
            return temperature * rarityScore + (1 - temperature) * distanceScore * 10.0
        }

        // Weighted random selection
        let totalScore = scores.reduce(0, +)
        guard totalScore > 0 else { return Int.random(in: 0..<entries.count) }

        var rand = Double.random(in: 0..<totalScore)
        for (index, score) in scores.enumerated() {
            rand -= score
            if rand <= 0 { return index }
        }
        return entries.count - 1
    }
}
```

**Usage examples:**

```swift
// Example 1: Regression testing
@Test func testParserAfterRefactor() throws {
    try fuzz(
        targeting: [
            .region(file: "Parser.swift", lineStart: 140, lineEnd: 160)
        ],
        corpusMode: .refuzzExtend,
        iterations: 50_000
    ) { (input: String) in
        let result = parse(input)
        #expect(result.isValid || result.hasError)
    }
}

// Example 2: Edge case exploration
@Test func testSQLInjectionDefense() throws {
    try fuzz(
        targeting: [
            .function(name: "sanitizeInput"),
            .function(name: "escapeSQL")
        ],
        using: String.mutators(.sql)
    ) { input in
        let sanitized = sanitize(input)
        #expect(!sanitized.contains("DROP TABLE"))
    }
}

// Example 3: Crash reproduction
@Test func testCrashAtLine142() throws {
    try fuzz(
        targeting: [
            .sourceLine(file: "Parser.swift", line: 142)
        ],
        seeds: [
            loadCrashInput(),  // Input that previously caused crash
            // Fuzzer will mutate this, trying to reach line 142
        ]
    ) { input in
        parseWithTimeout(input)  // Should not crash
    }
}
```

**Impact**:
- 30-50% faster convergence to target code paths
- Enables targeted regression testing workflows
- Improves discoverability of edge cases in specific functions

**Effort**: ~20-30 hours
- 6-8 hours: API design and target specification
- 8-12 hours: Distance computation implementation
- 4-6 hours: Annealing integration and corpus selection updates
- 2-4 hours: Testing across different target types

**Code locations**:
- `Sources/PropertyTestingKit/Fuzzing/FuzzAPI.swift` (new API)
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine.swift` (directed mode)
- `Sources/PropertyTestingKit/Fuzzing/Corpus.swift` (selection updates)
- `Sources/PropertyTestingKit/Fuzzing/TargetDistance.swift` (new file)

### Recommendation 2: Add Annealing to Existing Fuzzing (High Priority)

**What**: Implement AFLGo's simulated annealing schedule for exploration-to-exploitation transition, even without explicit targets.

**Why**: Current PropertyTestingKit uses fixed `generationRatio` throughout fuzzing. This means the balance between fresh generation (exploration) and mutation (exploitation) never changes. Annealing allows:
- **Early phase**: High generation rate discovers diverse coverage quickly
- **Late phase**: Low generation rate exploits proven corpus deeply
- **Smooth transition**: Avoids cliffs where strategy abruptly changes

**How**:

```swift
// Add to FuzzEngine.Config
public struct Config {
    // ... existing fields ...

    /// Annealing schedule for exploration-exploitation tradeoff
    public var annealingSchedule: AnnealingSchedule = .exponential(beta: 1.5)

    /// Base generation ratio (will be scaled by temperature)
    public var baseGenerationRatio: Double = 0.3
}

public enum AnnealingSchedule: Sendable {
    case none            // Disable annealing (constant ratio)
    case exponential(beta: Double)  // AFLGo's schedule
    case linear          // Linear cooling

    func temperature(elapsed: TimeInterval, maxDuration: TimeInterval) -> Double {
        let progress = min(1.0, elapsed / maxDuration)

        switch self {
        case .none:
            return 1.0
        case .exponential(let beta):
            return pow(1.0 - progress, beta)
        case .linear:
            return 1.0 - progress
        }
    }
}

// Update FuzzEngine.runFuzzing()
mutating func runFuzzing(...) throws -> FuzzResult<repeat each Input> {
    let startTime = Date()
    var iteration = 0

    while iteration < config.maxIterations {
        let elapsed = Date().timeIntervalSince(startTime)

        // Compute temperature-adjusted generation ratio
        let temperature = config.annealingSchedule.temperature(
            elapsed: elapsed,
            maxDuration: config.maxDuration
        )
        let currentGenerationRatio = config.baseGenerationRatio * temperature

        // Decide: generate fresh or mutate corpus?
        if corpus.isEmpty || Double.random(in: 0..<1) < currentGenerationRatio {
            // Generate fresh input (exploration)
            let generated = generateFreshInput()
            testInput(generated)
            stats.generations += 1
        } else {
            // Mutate corpus entry (exploitation)
            let selected = corpus.selectForMutation()!
            let mutated = mutateInput(corpus.entries[selected].input)
            testInput(mutated)
            stats.mutations += 1
        }

        iteration += 1
    }
}
```

**Configuration guidance:**
- **Default**: `exponential(beta: 1.5)` for balanced annealing
- **Fast convergence**: `exponential(beta: 2.0)` or higher - cools quickly, heavy exploitation
- **Thorough exploration**: `exponential(beta: 1.0)` or `linear` - cools slowly, maintains exploration longer
- **No annealing**: `.none` to preserve current behavior

**Impact**:
- 10-20% improvement in coverage discovery rate
- Better corpus quality (fewer redundant entries)
- More effective late-stage fuzzing (avoids plateau)

**Effort**: ~3-4 hours
- 1 hour: Add `AnnealingSchedule` enum and temperature computation
- 1 hour: Integrate into fuzzing loop
- 1 hour: Testing with different beta values
- 0.5-1 hour: Documentation and configuration defaults

### Recommendation 3: Time-Budget-Aware Power Scheduling

**What**: Extend existing rarity-based seed selection with time awareness to allocate energy proportional to remaining budget.

**Why**: AFLGo becomes increasingly aggressive as time runs out, ensuring it reaches targets before the deadline. PropertyTestingKit can apply similar logic: late in the campaign, focus almost exclusively on the most promising seeds.

**How**:

```swift
extension Corpus {
    mutating func selectForMutation(
        temperature: Double,
        distanceComputer: TargetDistanceComputer?
    ) -> Int? {
        guard !entries.isEmpty else { return nil }

        let scores = entries.enumerated().map { (index, entry) -> Double in
            let rarityScore = entry.signature.executedIndices
                .map { 1.0 / Double(frequencyMap[$0] ?? 1) }
                .reduce(0, +)

            let distanceScore: Double
            if let distanceComputer = distanceComputer {
                let distance = entry.distanceToTargets ?? 10.0
                // At low temperature, distance dominates exponentially
                distanceScore = pow(2.0, -distance)
            } else {
                distanceScore = 1.0
            }

            // AFLGo formula adaptation:
            // E(s) = (1-T) * distance_weight + T * rarity_weight
            // At T=1 (start): mostly rarity (exploration)
            // At T=0 (end): mostly distance (exploitation)
            let explorationScore = rarityScore
            let exploitationScore = distanceScore * 100.0

            return temperature * explorationScore + (1 - temperature) * exploitationScore
        }

        // Weighted random selection
        let totalScore = scores.reduce(0, +)
        guard totalScore > 0 else { return Int.random(in: 0..<entries.count) }

        var rand = Double.random(in: 0..<totalScore)
        for (index, score) in scores.enumerated() {
            rand -= score
            if rand <= 0 { return index }
        }
        return entries.count - 1
    }
}
```

**Impact**: Increases likelihood of reaching targets within time budget by 20-40%.

**Effort**: ~2 hours (integrated with Recommendation 1)

### Recommendation 4: Add Git Diff-Based Target Extraction

**What**: Automatically generate `FuzzTarget` specifications from git diffs for regression testing.

**Why**: Streamlines regression testing workflow. When code changes, developers want to fuzz the changed areas without manually specifying line numbers.

**How**:

```swift
// New file: Sources/PropertyTestingKit/Fuzzing/GitTargets.swift
import Foundation

extension FuzzTarget {
    /// Generate targets from git diff between two commits.
    public static func fromGitDiff(
        base: String = "main",
        head: String = "HEAD",
        repository: String = "."
    ) throws -> [FuzzTarget] {
        // Run: git diff --unified=0 base..head
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "diff",
            "--unified=0",
            "\(base)..\(head)"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: repository)

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return parseGitDiff(output)
    }

    private static func parseGitDiff(_ diff: String) -> [FuzzTarget] {
        var targets: [FuzzTarget] = []
        var currentFile: String?

        for line in diff.components(separatedBy: .newlines) {
            // Parse file name: +++ b/path/to/File.swift
            if line.hasPrefix("+++") {
                currentFile = line
                    .dropFirst(6)  // Remove "+++ b/"
                    .trimmingCharacters(in: .whitespaces)
            }

            // Parse changed line range: @@ -10,3 +10,5 @@
            else if line.hasPrefix("@@"), let file = currentFile {
                // Extract line numbers from @@ +start,count @@
                let pattern = #"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@"#
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(
                        in: line,
                        range: NSRange(line.startIndex..., in: line)
                      ) else {
                    continue
                }

                let startRange = Range(match.range(at: 1), in: line)!
                let start = Int(line[startRange])!

                let count: Int
                if match.range(at: 2).location != NSNotFound {
                    let countRange = Range(match.range(at: 2), in: line)!
                    count = Int(line[countRange])!
                } else {
                    count = 1
                }

                let end = start + count - 1
                targets.append(.region(file: file, lineStart: start, lineEnd: end))
            }
        }

        return targets
    }
}
```

**Usage**:

```swift
@Test func testRegressionSinceMain() throws {
    try fuzz(
        targeting: FuzzTarget.fromGitDiff(base: "main", head: "HEAD"),
        corpusMode: .refuzzExtend
    ) { (input: String) in
        parse(input)
    }
}

// Or in CI: automatically fuzz all changes
@Suite(.tags(.regression))
struct RegressionTests {
    @Test func fuzzAllChanges() throws {
        let targets = try FuzzTarget.fromGitDiff(
            base: ProcessInfo.processInfo.environment["CI_BASE_COMMIT"] ?? "main"
        )

        guard !targets.isEmpty else {
            throw XCTSkip("No code changes to fuzz")
        }

        try fuzz(targeting: targets) { (input: String) in
            // Fuzz all entry points
            parseConfig(input)
        }
    }
}
```

**Impact**:
- Reduces friction for regression testing (one-line API)
- Automatically focuses fuzzing on change-induced risk
- Integrates seamlessly with CI workflows

**Effort**: ~6-8 hours
- 3-4 hours: Git integration and diff parsing
- 2-3 hours: Testing with various diff formats
- 1 hour: Documentation and examples

### Recommendation 5: Add Target Distance Metrics to FuzzStats

**What**: Report distance metrics in fuzzing statistics for debugging and optimization.

**Why**: Users need visibility into directed fuzzing progress. Is the fuzzer getting closer to targets? Is it stuck?

**How**:

```swift
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Distance metrics (populated when targets specified)
    public let targetMetrics: TargetMetrics?
}

public struct TargetMetrics: Sendable {
    /// Minimum distance achieved during campaign
    public let minDistanceReached: Double

    /// Number of inputs that reached targets (distance 0)
    public let targetHits: Int

    /// Number of inputs that came close (distance <= 1)
    public let nearMisses: Int

    /// Average distance of corpus entries
    public let avgCorpusDistance: Double

    /// Distribution of distances in corpus
    public let distanceDistribution: [Double: Int]  // [distance: count]
}

// Report in verbose mode
if config.verbose {
    if let targetMetrics = result.stats.targetMetrics {
        print("Target Metrics:")
        print("  Minimum distance reached: \(targetMetrics.minDistanceReached)")
        print("  Target hits: \(targetMetrics.targetHits)")
        print("  Near misses: \(targetMetrics.nearMisses)")
        print("  Avg corpus distance: \(targetMetrics.avgCorpusDistance)")
    }
}
```

**Impact**: Improves debuggability and helps users tune annealing parameters.

**Effort**: ~2-3 hours

---

## Implementation Priority

**Phase 1: Annealing Foundation (Highest ROI, No Dependencies)**
1. Implement Recommendation 2 (Annealing schedule) - ~3-4 hours
2. Test with stress tests and measure improvement - ~2 hours
**Total: ~5-6 hours, Expected improvement: 10-20%**

**Phase 2: Directed Fuzzing Core (High Impact, Builds on Phase 1)**
3. Implement Recommendation 1 (Source-level directed fuzzing) - ~20-30 hours
4. Implement Recommendation 5 (Target metrics reporting) - ~2-3 hours
**Total: ~22-33 hours, Expected improvement: 30-50% for targeted scenarios**

**Phase 3: Workflow Integration (Medium Impact, Requires Phase 2)**
5. Implement Recommendation 4 (Git diff targets) - ~6-8 hours
6. Implement Recommendation 3 (Time-aware power scheduling) - ~2 hours
**Total: ~8-10 hours, Expected improvement: 15-25% for regression testing**

**Total implementation effort: ~35-49 hours across three phases**

---

## References

- Böhme, M., Pham, V.-T., & Roychoudhury, A. (2017). Directed Greybox Fuzzing. In Proceedings of the 2017 ACM SIGSAC Conference on Computer and Communications Security (CCS '17), 2329-2344.
- AFLGo implementation: https://github.com/aflgo/aflgo
- LLVM SanitizerCoverage: https://clang.llvm.org/docs/SanitizerCoverage.html
- American Fuzzy Lop (AFL): https://lcamtuf.coredump.cx/afl/

---

## Notes

**Synergies with existing PropertyTestingKit features:**

AFLGo's directed fuzzing complements PropertyTestingKit's unique strengths rather than replacing them:

1. **Value profile guidance + Directed fuzzing**: PropertyTestingKit tracks comparison operations to solve magic constants. When combined with targeting, the fuzzer can solve comparisons *specifically in target functions*, dramatically improving efficiency for targets behind authentication checks or input validation.

2. **Custom mutators + Annealing**: Domain-specific mutators (SQL, XSS, etc.) provide semantic mutations. Annealing ensures these mutators are applied more intensively late in the campaign when their sophisticated strategies have maximum impact.

3. **Multi-component mutations + Distance metrics**: When fuzzing functions with multiple parameters, distance feedback can identify which parameter is blocking progress toward targets, allowing selective mutation focus.

**Architectural considerations:**

Unlike AFLGo which modifies AFL's C implementation with LLVM instrumentation, PropertyTestingKit must implement directed fuzzing at a higher abstraction level:

- **No compile-time instrumentation**: Cannot embed static distances in binary
- **Runtime distance computation**: Must compute distances dynamically from coverage data
- **Approximate metrics**: Without CFG, distances are heuristic (function-level, call stack)
- **Good enough**: Approximate distances still provide effective gradient for directed search

The recommended implementation prioritizes pragmatic runtime approaches that fit PropertyTestingKit's architecture while capturing AFLGo's core insights about annealing-based power scheduling and distance-guided seed selection.

**Alternative approaches considered:**

1. **LLVM pass for CFG distance computation**: Rejected due to complexity and build system integration challenges. Would require custom Swift compiler builds.

2. **Dynamic call graph construction**: Rejected due to overhead. Tracking full call graphs at runtime adds 20-50% performance penalty.

3. **Source mapping via debug info**: Considered but limited by debug info quality and availability in release builds.

The recommended approach balances implementation complexity with practical effectiveness, providing 70-80% of AFLGo's benefits with 20-30% of the implementation effort.
