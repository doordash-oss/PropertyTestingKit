# MAP-Elites: Illuminating Search Spaces by Mapping Elites

**Paper:** Mouret & Clune, "Illuminating search spaces by mapping elites", arXiv:1504.04909, 2015
**URL:** https://arxiv.org/abs/1504.04909
**GitHub Tutorial:** https://github.com/jbmouret/map_elites_tutorial
**Python Reference:** https://github.com/resibots/pymap_elites

---

## Paper Summary

MAP-Elites (Multi-dimensional Archive of Phenotypic Elites) represents a fundamental paradigm shift in evolutionary algorithms by prioritizing "illumination" over pure optimization. Traditional evolutionary algorithms search for a single optimal solution, treating diversity as merely a means to avoid local optima. In contrast, MAP-Elites explicitly seeks to create a comprehensive map showing how high-performing solutions are distributed across a user-defined feature space. Rather than returning "the best robot design," MAP-Elites returns "the best robot design for every combination of height and weight" (or any other dimensions the user chooses). This illumination approach reveals how different solution characteristics combine to affect performance, exposing relationships that single-solution optimization completely obscures.

The algorithm operates by maintaining a grid-based archive where each cell represents a unique combination of feature dimensions (behavior descriptors). Solutions are placed into grid cells based on their measured features, and each cell retains only the highest-performing solution for that behavioral niche. The process begins with random initialization, then iteratively generates new solutions through mutation and crossover, evaluates both their performance and feature descriptors, and places them into appropriate cells where they replace existing occupants only if superior. This creates local competition within behavioral niches rather than global competition, fundamentally changing the selective pressure from "be the best overall" to "be the best of your kind." The grid-based discretization elegantly sidesteps the computational expense of maintaining explicit diversity metrics by using simple cell indexing.

The practical impact of MAP-Elites extends far beyond theoretical interest. The algorithm has been demonstrated across domains from neural network architecture search to soft robotics, including physical robot deployment. Counterintuitively, by explicitly pursuing diversity rather than singular optimization, MAP-Elites often discovers better overall solutions than traditional optimization algorithms—the broader exploration of the solution space increases the probability of finding global optima. More importantly, the resulting archive of diverse high-quality solutions provides users with actionable choices, reveals unexpected design possibilities, and serves practical purposes like damage recovery (switching to a different locomotion strategy when a robot leg fails). Recent high-profile applications include Meta's use in LLaMA v3 for finding adversarial prompts and Google's AlphaEvolve for discovering mathematical facts, demonstrating the algorithm's continued relevance and expanding scope.

---

## Key Strategies/Techniques

1. **Behavior Characterization via Feature Dimensions**: Instead of comparing solutions in parameter space (which suffers from the "competing convention" problem where identical behaviors can be encoded differently), MAP-Elites uses behavioral descriptors—measurable outcome metrics chosen by the user. For a robot, this might be "proportion of time each leg contacts ground" or "final XYZ displacement." For neural networks, it could be "number of hidden nodes" or "modularity score." The user selects 2-5 dimensions that capture meaningful variation in the problem domain.

2. **Grid-Based Discretization**: The continuous behavior space is discretized into a multi-dimensional grid. Each cell represents a behavioral niche (e.g., "robots that are 20-30cm tall and weigh 500-600g"). This discretization replaces expensive pairwise similarity calculations with simple cell indexing. The grid size grows exponentially with dimensions (a 10x10x10x10 grid for 4 dimensions = 10,000 cells), so keeping dimensionality low (2-5) is critical for computational tractability.

3. **Local Competition within Niches**: Solutions compete only with others in the same grid cell (same behavioral niche), not with the entire population. This fundamentally changes selective pressure: a solution doesn't need to be globally optimal, just locally optimal within its behavioral category. This prevents convergence to a single solution type and maintains diversity throughout the evolutionary process.

4. **Elite Preservation Strategy**: Each grid cell stores at most one solution—the elite for that niche. When a new solution maps to an occupied cell, it replaces the current occupant only if it has higher performance (fitness). Empty cells are immediately filled by any solution mapping to them. This creates an archive of champions across the behavior space rather than a uniform population.

5. **Variation Operators (Mutation/Crossover)**: New solutions are generated by selecting an occupied cell (uniformly at random or using biased selection strategies) and applying genetic operators to its elite. Standard mutation and crossover from evolutionary algorithms are used, with the key difference being that offspring are evaluated on both performance and behavior, then placed into their own behavioral niche (which may differ from the parent's niche).

6. **Illumination as Primary Goal**: Unlike traditional evolutionary algorithms where diversity is a means to an end (avoiding local optima), MAP-Elites treats illumination—filling the archive with high-quality solutions across all niches—as the explicit goal. Success is measured not just by the best solution found, but by coverage (percentage of cells occupied) and QD-score (sum of performance across all occupied cells).

7. **No Explicit Fitness Sharing or Distance Calculations**: Traditional diversity-promoting algorithms like novelty search require computing distances between individuals or maintaining separate niches with fitness sharing. MAP-Elites avoids this computational overhead entirely—the grid structure implicitly maintains diversity without any pairwise comparisons.

8. **Greedy Archive Update**: The algorithm uses a simple greedy replacement strategy: if a new solution is better than the current elite in its cell (or the cell is empty), it immediately replaces it. There's no tournament selection, no population size limits, no generational replacement—just straightforward elite preservation per cell.

---

## Applicability to PropertyTestingKit

**High Applicability** - MAP-Elites offers powerful techniques that align exceptionally well with PropertyTestingKit's fuzzing architecture. The core insight—maintaining a diverse archive of solutions organized by behavioral features—maps naturally to maintaining a diverse corpus of test inputs organized by their characteristics. PropertyTestingKit's existing coverage-guided infrastructure provides an excellent foundation for MAP-Elites integration.

### Current PropertyTestingKit Architecture

PropertyTestingKit implements AFL-inspired coverage-guided fuzzing with several relevant features:

- **Corpus Management** (`Corpus.swift`): Maintains inputs with unique coverage signatures, uses energy-based selection for mutation, tracks coverage union across all entries
- **Coverage-Guided Evolution** (`FuzzEngine.swift`): Inputs discovering new edge coverage are preserved, iterative mutation/generation with plateau detection
- **Value Profile Guidance** (lines 544-616, 705-760): Tracks comparison operand distances, prioritizes inputs making progress toward solving comparisons, implements target-directed mutations
- **Multi-Strategy Mutation** (lines 933-1135): Single-component, multi-component, arithmetic relationship, and dictionary-based mutations
- **Corpus Minimization** (lines 180-214 in `Corpus.swift`): Greedy set cover algorithm to find minimal corpus covering all unique indices

The architecture follows a single-dimension optimization model: "maximize edge coverage." This is analogous to a traditional evolutionary algorithm optimizing for a single fitness function. MAP-Elites would transform this into multi-dimensional illumination.

### Where MAP-Elites Concepts Apply

**1. Multi-Dimensional Corpus Organization** (Direct Application - High Priority)

Currently, `Corpus` uses a flat list where entries are distinguished only by their `CoverageSignature`. MAP-Elites would introduce behavioral dimensions beyond coverage:

```swift
/// Feature dimensions for characterizing test inputs
public struct InputFeatures: Hashable {
    /// Edge coverage density (0-100%)
    let coverageDensity: Int

    /// Input "complexity" bucket (e.g., string length ranges, numeric magnitude)
    let complexityBucket: Int

    /// Execution path depth (function call depth, loop iterations)
    let pathDepth: Int
}

/// Grid cell in the MAP-Elites archive
public struct EliteCell<each Input: Codable & Sendable> {
    let features: InputFeatures
    var elite: CorpusEntry<repeat each Input>?
    var performance: Double  // Could be: exec speed, memory usage, etc.
}

/// MAP-Elites archive organized as a multi-dimensional grid
public struct MapElitesCorpus<each Input: Codable & Sendable>: Sendable {
    /// Grid dimensions configuration
    let dimensions: GridDimensions

    /// Sparse storage: only occupied cells
    private var cells: [InputFeatures: EliteCell<repeat each Input>]

    /// Total coverage union (for compatibility with existing code)
    public private(set) var totalCoverage: CoverageSignature

    /// Add input if it's the best in its behavioral niche
    mutating func addIfElite(
        input: repeat each Input,
        signature: CoverageSignature,
        features: InputFeatures,
        performance: Double
    ) -> Bool {
        guard let cell = cells[features] else {
            // Empty cell - immediately add
            cells[features] = EliteCell(
                features: features,
                elite: CorpusEntry(input: repeat each input, signature: signature),
                performance: performance
            )
            totalCoverage = totalCoverage.union(with: signature)
            return true
        }

        // Occupied cell - replace if better performance
        if performance > cell.performance {
            cells[features]?.elite = CorpusEntry(input: repeat each input, signature: signature)
            cells[features]?.performance = performance
            totalCoverage = totalCoverage.union(with: signature)
            return true
        }

        return false
    }

    /// Coverage: percentage of cells occupied
    var coverage: Double {
        Double(cells.count) / Double(dimensions.totalCells)
    }

    /// QD-score: sum of performance across all elites
    var qdScore: Double {
        cells.values.reduce(0.0) { $0 + $1.performance }
    }
}
```

**2. Behavioral Feature Extraction** (New Capability)

PropertyTestingKit needs to extract behavioral features from test execution. Several features are immediately available:

```swift
/// Extract behavioral features from a test execution
struct FeatureExtractor {
    /// Configuration for discretization
    struct Config {
        let coverageBuckets: Int = 10  // 0-10%, 10-20%, etc.
        let complexityBuckets: Int = 10
        let depthBuckets: Int = 5
    }

    let config: Config

    func extract<each Input: Codable & Sendable>(
        from input: (repeat each Input),
        signature: CoverageSignature,
        executionContext: ExecutionContext
    ) -> InputFeatures {
        // Coverage density: percentage of all possible edges hit
        let coverageDensity = calculateCoverageDensity(signature)
        let coverageBucket = min(coverageDensity / 10, config.coverageBuckets - 1)

        // Input complexity: aggregate measure of input "size"
        let complexity = calculateComplexity(input)
        let complexityBucket = discretize(complexity, into: config.complexityBuckets)

        // Execution depth: maximum call stack depth or loop iterations
        let depth = executionContext.maxStackDepth
        let depthBucket = discretize(depth, into: config.depthBuckets)

        return InputFeatures(
            coverageDensity: coverageBucket,
            complexityBucket: complexityBucket,
            pathDepth: depthBucket
        )
    }

    private func calculateComplexity<each Input: Codable & Sendable>(
        _ input: (repeat each Input)
    ) -> Int {
        var totalComplexity = 0

        func addComplexity<V>(_ value: V) {
            switch value {
            case let str as String:
                totalComplexity += str.count
            case let int as Int:
                totalComplexity += Int(log2(Double(abs(int) + 1)))
            case let arr as [Any]:
                totalComplexity += arr.count * 10
            default:
                totalComplexity += 1
            }
        }

        (repeat addComplexity(each input))
        return totalComplexity
    }
}
```

**3. Performance Metrics Beyond Coverage** (Extension)

MAP-Elites requires a "performance" score separate from behavioral features. PropertyTestingKit could use:

```swift
/// Performance metrics for ranking inputs within a behavioral niche
public enum PerformanceMetric {
    case executionSpeed      // Faster is better (for perf testing)
    case memoryPressure      // Higher is better (stress testing)
    case valueProfileProgress // Distance improvements on comparisons
    case coverageRarity      // Sum of 1/frequency for covered edges

    func evaluate<each Input: Codable & Sendable>(
        input: (repeat each Input),
        signature: CoverageSignature,
        context: ExecutionContext,
        corpus: MapElitesCorpus<repeat each Input>
    ) -> Double {
        switch self {
        case .executionSpeed:
            return 1.0 / context.executionTime  // Inverse time
        case .memoryPressure:
            return Double(context.peakMemoryUsage)
        case .valueProfileProgress:
            return context.valueProfileScore
        case .coverageRarity:
            return corpus.calculateRarityScore(signature)
        }
    }
}
```

**4. Illumination-Focused Fuzzing Strategy** (Algorithm Change)

The fuzzing loop would change from "maximize coverage" to "illuminate the feature space":

```swift
// In FuzzEngine.runFuzzing()
private func runIlluminationFuzzing(
    additionalSeeds: [(repeat each Input)] = [],
    test: ((repeat each Input)) throws -> Void
) -> FuzzResult<repeat each Input> {
    var archive = MapElitesCorpus<repeat each Input>(
        dimensions: config.featureDimensions,
        schemaVersion: CorpusSchema.currentVersion()
    )

    // Phase 1: Seed the archive
    for input in allSeeds {
        let (signature, context) = executeWithContext(input, test: test)
        let features = featureExtractor.extract(from: input, signature: signature, context: context)
        let performance = performanceMetric.evaluate(input: input, signature: signature, context: context, corpus: archive)

        archive.addIfElite(
            input: repeat each input,
            signature: signature,
            features: features,
            performance: performance
        )
    }

    // Phase 2: Illuminate the space
    var iteration = allSeeds.count
    while iteration < config.maxIterations {
        // Select a cell (occupied) to mutate from
        guard let cell = archive.selectCellForMutation() else { break }
        guard let elite = cell.elite else { continue }

        // Generate variations
        let mutations = mutateInput(elite.input)
        guard let mutated = mutations.randomElement() else { continue }

        // Evaluate and place in archive
        let (signature, context) = executeWithContext(mutated, test: test)
        let features = featureExtractor.extract(from: mutated, signature: signature, context: context)
        let performance = performanceMetric.evaluate(input: mutated, signature: signature, context: context, corpus: archive)

        // This may go to a different cell than the parent!
        archive.addIfElite(
            input: mutated,
            signature: signature,
            features: features,
            performance: performance
        )

        iteration += 1

        // Stopping condition: archive coverage plateau
        if iteration % 100 == 0 && archive.coverageStagnant(threshold: config.plateauThreshold) {
            break
        }
    }

    if config.verbose {
        print("[MAP-Elites] Archive coverage: \(archive.coverage * 100)%")
        print("[MAP-Elites] QD-score: \(archive.qdScore)")
        print("[MAP-Elites] Occupied cells: \(archive.occupiedCells.count)")
    }

    return archive.toFuzzResult()
}
```

**5. Cell Selection Strategy** (Mutation Source)

MAP-Elites typically uses uniform random selection, but PropertyTestingKit could bias toward specific strategies:

```swift
extension MapElitesCorpus {
    /// Select a cell for mutation (MAP-Elites variation operator source)
    func selectCellForMutation(strategy: SelectionStrategy = .uniform) -> EliteCell<repeat each Input>? {
        guard !cells.isEmpty else { return nil }

        switch strategy {
        case .uniform:
            // Original MAP-Elites: uniform random
            return cells.values.randomElement()

        case .rareCoverage:
            // PropertyTestingKit's existing energy-based approach
            // Prioritize cells whose elites cover rare edges
            let scores = cells.values.map { cell in
                calculateRarityScore(cell.elite!.signature)
            }
            return weightedRandomSelection(from: Array(cells.values), weights: scores)

        case .frontierExpansion:
            // Prioritize cells near empty cells (expand the frontier)
            let frontierCells = cells.values.filter { cell in
                hasEmptyNeighbors(cell.features)
            }
            return frontierCells.randomElement() ?? cells.values.randomElement()

        case .curiosity:
            // Prioritize cells with recent performance improvements
            return cells.values.max { $0.performanceImprovement < $1.performanceImprovement }
        }
    }

    /// Check if a cell has empty neighboring cells
    private func hasEmptyNeighbors(_ features: InputFeatures) -> Bool {
        for neighbor in features.neighbors() {
            if cells[neighbor] == nil {
                return true
            }
        }
        return false
    }
}
```

**6. Feature Dimensions for Swift Fuzzing** (Domain-Specific Design)

Choosing effective feature dimensions is critical. For PropertyTestingKit testing Swift code:

```swift
/// Recommended feature dimensions for Swift fuzzing
public enum SwiftFuzzFeatures {
    /// Input characteristics
    case stringLength       // For String inputs: discretized length
    case numericMagnitude   // For Int/Double: log-scale buckets
    case collectionSize     // For Arrays: element count
    case optionality        // For Optionals: nil vs non-nil
    case nesting           // For nested structures: depth

    /// Execution characteristics
    case edgeCoverage      // Total edges hit (standard AFL approach)
    case branchDepth       // Maximum nested branch depth
    case loopIterations    // Total loop iterations executed
    case functionCalls     // Number of function calls made
    case exceptionPath     // Whether an exception was thrown

    /// Performance characteristics
    case executionTime     // Discretized execution duration
    case memoryAllocations // Number of allocations
    case stackDepth        // Maximum call stack depth
}

/// Example: 3D feature space for fuzzing a parser
struct ParserFuzzFeatures: Hashable {
    let inputLength: Int        // 0-9: 0-10 chars, 10-100, 100-1000, etc.
    let nestingDepth: Int       // 0-9: 0-1 levels, 2-3, 4-7, 8-15, etc.
    let coverageDensity: Int    // 0-9: 0-10%, 10-20%, ..., 90-100%
}
```

**7. Hybrid Approach: MAP-Elites + AFL Coverage** (Pragmatic Integration)

PropertyTestingKit doesn't need to abandon AFL's pure coverage approach—MAP-Elites can complement it:

```swift
/// Hybrid corpus: traditional AFL corpus + MAP-Elites archive
public struct HybridCorpus<each Input: Codable & Sendable>: Sendable {
    /// Traditional AFL-style corpus: any input with unique coverage
    var coverageCorpus: Corpus<repeat each Input>

    /// MAP-Elites archive: elites across behavioral dimensions
    var mapElitesArchive: MapElitesCorpus<repeat each Input>

    /// Add input to both if applicable
    mutating func add(
        input: repeat each Input,
        signature: CoverageSignature,
        features: InputFeatures,
        performance: Double
    ) {
        // Always try coverage corpus (AFL approach)
        coverageCorpus.addIfInteresting(input: repeat each input, signature: signature)

        // Also try MAP-Elites archive
        mapElitesArchive.addIfElite(
            input: repeat each input,
            signature: signature,
            features: features,
            performance: performance
        )
    }

    /// Select input for mutation from either corpus
    func selectForMutation() -> (repeat each Input)? {
        // 50/50 split between coverage corpus and MAP-Elites archive
        if Bool.random() {
            return coverageCorpus.entries.randomElement()?.input
        } else {
            return mapElitesArchive.selectCellForMutation()?.elite?.input
        }
    }
}
```

**8. Visualization and Reporting** (User-Facing Feature)

MAP-Elites' power lies in illuminating the search space. PropertyTestingKit could expose this:

```swift
/// Generate a visual report of the MAP-Elites archive
public struct ArchiveReport {
    let archive: MapElitesCorpus<repeat each Input>

    /// Generate a 2D heatmap for two selected dimensions
    func heatmap(xDimension: String, yDimension: String) -> [[Double?]] {
        // Project the multi-dimensional archive onto 2D
        // Each cell shows the performance of the elite in that niche
        // Empty cells are nil
    }

    /// Generate a markdown report
    func markdown() -> String {
        """
        # MAP-Elites Fuzzing Report

        ## Archive Statistics
        - Total cells: \(archive.dimensions.totalCells)
        - Occupied cells: \(archive.occupiedCells.count)
        - Coverage: \(archive.coverage * 100)%
        - QD-score: \(archive.qdScore)

        ## Top Performers by Niche
        \(topPerformersTable())

        ## Coverage Heatmap
        \(coverageHeatmap())
        """
    }
}
```

---

## Concrete Recommendations

### Recommendation 1: Introduce Feature Extraction as Optional Mode

**Priority: High** | **Effort: Medium** | **Impact: High**

Add MAP-Elites as an opt-in alternative to standard coverage-guided fuzzing:

```swift
// In FuzzEngine.Config
public struct Config: Sendable {
    // ... existing fields ...

    /// Enable MAP-Elites illumination mode
    public var enableMapElites: Bool

    /// Feature dimensions for MAP-Elites
    public var featureDimensions: FeatureDimensions?

    /// Performance metric for ranking within niches
    public var performanceMetric: PerformanceMetric
}

// Usage
@Test func testParser() throws {
    try fuzz(
        config: .init(
            enableMapElites: true,
            featureDimensions: .init(
                inputLength: 10,        // 10 buckets for input length
                nestingDepth: 5,        // 5 buckets for nesting
                coverageDensity: 10     // 10 buckets for coverage %
            ),
            performanceMetric: .coverageRarity
        )
    ) { (input: String) in
        parse(input)
    }
}
```

**Implementation Steps:**
1. Create `MapElitesCorpus` struct alongside existing `Corpus`
2. Implement `FeatureExtractor` to compute behavioral features
3. Add `enableMapElites` flag to `Config` with default `false` (backward compatible)
4. Implement `runIlluminationFuzzing()` method in `FuzzEngine`
5. Update corpus serialization to handle both formats

**Benefits:**
- Maintains backward compatibility (default behavior unchanged)
- Provides users with choice between coverage maximization and space illumination
- Reveals behavioral diversity in test inputs

### Recommendation 2: Implement Execution Context Tracking

**Priority: High** | **Effort: Medium** | **Impact: High**

To extract meaningful behavioral features, PropertyTestingKit needs execution context beyond coverage counters:

```swift
/// Context information captured during test execution
public struct ExecutionContext: Sendable {
    /// Execution time in nanoseconds
    let executionTime: UInt64

    /// Maximum call stack depth reached
    let maxStackDepth: Int

    /// Total loop iterations (if instrumented)
    let loopIterations: Int

    /// Peak memory usage in bytes
    let peakMemoryUsage: UInt64

    /// Whether test threw an exception
    let didThrow: Bool

    /// Value profile progress score
    let valueProfileScore: Double
}

/// Enhanced coverage measurement with context
public func measureCoverageWithContext<T>(
    _ block: () throws -> T
) throws -> (result: T, signature: CoverageSignature, context: ExecutionContext) {
    @Dependency(\.coverageCounters) var coverageCounters

    let startTime = DispatchTime.now().uptimeNanoseconds
    let startMemory = getCurrentMemoryUsage()

    // Stack depth tracking would require compiler instrumentation
    // For now, use available metrics

    let before = coverageCounters.snapshot()
    var didThrow = false
    let result: T
    do {
        result = try block()
    } catch {
        didThrow = true
        throw error
    }
    let after = coverageCounters.snapshot()

    let endTime = DispatchTime.now().uptimeNanoseconds
    let endMemory = getCurrentMemoryUsage()

    let signature = CoverageSignature(diff: after!.difference(from: before!))
    let context = ExecutionContext(
        executionTime: endTime - startTime,
        maxStackDepth: 0,  // TODO: Requires instrumentation
        loopIterations: 0,  // TODO: Requires instrumentation
        peakMemoryUsage: endMemory - startMemory,
        didThrow: didThrow,
        valueProfileScore: 0.0  // TODO: Extract from ValueProfileTracker
    )

    return (result, signature, context)
}
```

**Integration with FuzzEngine:**

```swift
// In FuzzEngine.runFuzzing(), replace inline coverage tracking with:
let (_, signature, context) = try measureCoverageWithContext {
    try test(input)
}

// Extract features using context
if config.enableMapElites {
    let features = featureExtractor.extract(
        from: input,
        signature: signature,
        executionContext: context
    )
    let performance = config.performanceMetric.evaluate(
        input: input,
        signature: signature,
        context: context,
        corpus: archive
    )
    archive.addIfElite(...)
}
```

### Recommendation 3: Start with Simple 2D Feature Space

**Priority: High** | **Effort: Low** | **Impact: Medium**

Before implementing full multi-dimensional MAP-Elites, start with a 2D version for validation:

```swift
/// Simple 2D MAP-Elites for initial implementation
public struct MapElites2D<each Input: Codable & Sendable>: Sendable {
    let xBuckets: Int  // e.g., 10 for input length
    let yBuckets: Int  // e.g., 10 for coverage density

    /// Sparse grid storage
    private var grid: [[EliteCell<repeat each Input>?]]

    init(xBuckets: Int, yBuckets: Int) {
        self.xBuckets = xBuckets
        self.yBuckets = yBuckets
        self.grid = Array(repeating: Array(repeating: nil, count: yBuckets), count: xBuckets)
    }

    /// Add input if it's the elite in its cell
    mutating func addIfElite(
        input: repeat each Input,
        signature: CoverageSignature,
        x: Int,
        y: Int,
        performance: Double
    ) -> Bool {
        guard x < xBuckets && y < yBuckets else { return false }

        if let existing = grid[x][y] {
            // Replace if better
            if performance > existing.performance {
                grid[x][y] = EliteCell(
                    features: InputFeatures(/* ... */),
                    elite: CorpusEntry(input: repeat each input, signature: signature),
                    performance: performance
                )
                return true
            }
            return false
        } else {
            // Empty cell - add immediately
            grid[x][y] = EliteCell(
                features: InputFeatures(/* ... */),
                elite: CorpusEntry(input: repeat each input, signature: signature),
                performance: performance
            )
            return true
        }
    }

    /// Visualize as ASCII heatmap
    func asciiHeatmap() -> String {
        var lines: [String] = []
        for y in (0..<yBuckets).reversed() {
            var line = ""
            for x in 0..<xBuckets {
                if let cell = grid[x][y] {
                    // Performance-based intensity
                    let intensity = Int(cell.performance / maxPerformance * 9)
                    line += "\(intensity)"
                } else {
                    line += "."
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
```

**Recommended 2D Feature Pairs:**
1. **(Input Length, Coverage Density)**: Shows if longer inputs hit more code
2. **(Input Complexity, Execution Time)**: Reveals performance bottlenecks
3. **(Nesting Depth, Branch Depth)**: For structured input formats like JSON/XML

### Recommendation 4: Add Archive Comparison for Regression Detection

**Priority: Medium** | **Effort: Low** | **Impact: Medium**

MAP-Elites archives naturally support regression detection by comparing occupied cells:

```swift
extension MapElitesCorpus {
    /// Compare two archives to detect behavioral changes
    func diff(from other: MapElitesCorpus<repeat each Input>) -> ArchiveDiff {
        let myFeatures = Set(cells.keys)
        let otherFeatures = Set(other.cells.keys)

        return ArchiveDiff(
            newBehaviors: myFeatures.subtracting(otherFeatures),  // Cells we have that they don't
            lostBehaviors: otherFeatures.subtracting(myFeatures), // Cells they have that we don't
            improvedPerformance: improvedCells(from: other),
            degradedPerformance: degradedCells(from: other)
        )
    }

    private func improvedCells(from other: MapElitesCorpus) -> Set<InputFeatures> {
        var improved = Set<InputFeatures>()
        for (features, cell) in cells {
            if let otherCell = other.cells[features],
               cell.performance > otherCell.performance {
                improved.insert(features)
            }
        }
        return improved
    }
}

// In regression mode:
if config.corpusMode == .auto || config.corpusMode == .regressionOnly {
    let savedArchive = try MapElitesCorpus<repeat each Input>.load(from: directory)
    let currentArchive = runIlluminationFuzzing(...)
    let diff = currentArchive.diff(from: savedArchive)

    if !diff.lostBehaviors.isEmpty {
        print("[Regression] Lost \(diff.lostBehaviors.count) behavioral niches!")
        // Trigger re-fuzzing
    }
}
```

### Recommendation 5: Expose QD Metrics in Test Reports

**Priority: Low** | **Effort: Low** | **Impact: Medium**

Quality-Diversity metrics provide richer test insights than simple coverage numbers:

```swift
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// MAP-Elites specific metrics
    public let mapElitesStats: MapElitesStats?
}

public struct MapElitesStats: Sendable {
    /// Total cells in the grid
    let totalCells: Int

    /// Occupied cells
    let occupiedCells: Int

    /// Coverage: occupied / total
    var coverage: Double {
        Double(occupiedCells) / Double(totalCells)
    }

    /// QD-score: sum of performance across all elites
    let qdScore: Double

    /// Average performance of elites
    var avgPerformance: Double {
        occupiedCells > 0 ? qdScore / Double(occupiedCells) : 0
    }
}

// In test output:
@Test func testComplexParser() throws {
    let result = try fuzz(enableMapElites: true) { (input: String) in
        complexParser.parse(input)
    }

    if let meStats = result.stats.mapElitesStats {
        print("""
        MAP-Elites Results:
        - Archive coverage: \(meStats.coverage * 100)%
        - Occupied niches: \(meStats.occupiedCells)/\(meStats.totalCells)
        - QD-score: \(meStats.qdScore)
        - Avg performance: \(meStats.avgPerformance)
        """)
    }
}
```

### Recommendation 6: Consider CVT-MAP-Elites for High-Dimensional Features

**Priority: Low** | **Effort: High** | **Impact: Medium**

If PropertyTestingKit moves beyond 3-4 feature dimensions, the grid size explodes exponentially. CVT-MAP-Elites (Centroidal Voronoi Tessellation) uses adaptive partitioning instead of fixed grids:

```swift
/// CVT-MAP-Elites: use Voronoi tessellation instead of grid
public struct CVTMapElitesCorpus<each Input: Codable & Sendable>: Sendable {
    /// Centroids in high-dimensional feature space
    let centroids: [FeatureVector]

    /// Elite for each centroid (cell)
    private var elites: [Int: EliteCell<repeat each Input>]

    init(numCentroids: Int, featureSpace: FeatureSpace) {
        // Initialize centroids using k-means or random sampling
        self.centroids = featureSpace.generateCentroids(count: numCentroids)
        self.elites = [:]
    }

    /// Find nearest centroid for a feature vector
    func nearestCentroid(_ features: FeatureVector) -> Int {
        var bestIdx = 0
        var bestDist = Double.infinity
        for (idx, centroid) in centroids.enumerated() {
            let dist = features.distance(to: centroid)
            if dist < bestDist {
                bestDist = dist
                bestIdx = idx
            }
        }
        return bestIdx
    }

    mutating func addIfElite(
        input: repeat each Input,
        signature: CoverageSignature,
        features: FeatureVector,
        performance: Double
    ) -> Bool {
        let cellIdx = nearestCentroid(features)

        if let existing = elites[cellIdx] {
            if performance > existing.performance {
                elites[cellIdx] = EliteCell(/* ... */)
                return true
            }
            return false
        } else {
            elites[cellIdx] = EliteCell(/* ... */)
            return true
        }
    }
}
```

**When to use CVT over grid:**
- More than 4 feature dimensions (grid becomes sparse)
- Continuous feature spaces with non-uniform importance
- When computational cost of nearest-neighbor search is acceptable

**For PropertyTestingKit:** Start with simple grid-based MAP-Elites. CVT is an optimization for later if dimensionality becomes a bottleneck.

---

## Implementation Roadmap

### Phase 1: Foundation (1-2 weeks)
1. Implement `ExecutionContext` tracking in `measureCoverage()`
2. Create `MapElites2D` with simple input-length × coverage-density features
3. Add `enableMapElites` flag to `FuzzEngine.Config`
4. Implement basic feature extraction for `String` and `Int` inputs

### Phase 2: Integration (2-3 weeks)
1. Implement `MapElitesCorpus` with multi-dimensional support
2. Add performance metrics (execution time, coverage rarity)
3. Integrate MAP-Elites into `FuzzEngine.runFuzzing()` as alternative path
4. Implement cell selection strategies (uniform, rare coverage, frontier)
5. Update corpus serialization to support MAP-Elites format

### Phase 3: Polish (1-2 weeks)
1. Add `MapElitesStats` to `FuzzResult`
2. Implement archive visualization (ASCII heatmap, markdown reports)
3. Add regression detection via archive diffing
4. Write comprehensive tests for MAP-Elites components
5. Document usage patterns and recommended feature dimensions

### Phase 4: Advanced Features (Future)
1. CVT-MAP-Elites for high-dimensional features
2. Custom feature dimension APIs for user-defined behaviors
3. Multi-objective optimization (MAP-Elites with multiple performance metrics)
4. Interactive archive exploration tools

---

## Sources

- [Mouret & Clune (2015): Illuminating search spaces by mapping elites](https://arxiv.org/abs/1504.04909)
- [MAP-Elites Introduction](https://szhaovas.github.io/2022-09-15-me/)
- [Map Elites | Algorithm Afternoon](https://algorithmafternoon.com/novelty/map_elites/)
- [Quality-Diversity Algorithms: MAP-Elites applied to Robot Navigation | Towards Data Science](https://towardsdatascience.com/quality-diversity-algorithms-a-new-approach-based-on-map-elites-applied-to-robot-navigation-f51380deec5d/)
- [MAP-Elites Tutorial Repository](https://github.com/jbmouret/map_elites_tutorial)
- [Python MAP-Elites Reference Implementation](https://github.com/resibots/pymap_elites)
