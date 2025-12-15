# Swarm Testing

**Paper**: Groce, A., Zhang, C., Eide, E., Chen, Y., & Regehr, J. (2012). Swarm testing. Proceedings of the 2012 International Symposium on Software Testing and Analysis (ISSTA '12), 78-88.

**URL**: https://users.cs.utah.edu/~regehr/papers/swarm12.pdf

---

## Paper Summary

Swarm testing addresses a fundamental limitation of traditional random testing: the tendency to include all available features in every generated test case. While conventional wisdom suggests that maximizing feature coverage in each test improves bug detection, this paper demonstrates that the opposite is often true. The key insight is that **features can suppress bugs**—including a feature in a test does not always improve the ability to expose faults, and in fact, some features actively prevent the system from executing interesting behaviors that would reveal defects.

The paper introduces swarm testing as a simple yet powerful technique: instead of generating test cases that potentially include all features, create a large "swarm" of randomly generated configurations, each of which deliberately omits some features. Each configuration receives equal computational resources, forcing exploration of the system under different feature combinations. The authors identify two mechanisms by which feature omission improves testing effectiveness. First, **active suppression**: certain features prevent execution of bug-triggering behaviors (e.g., continuous "pop" operations on a stack prevent overflow bugs from manifesting). Second, **feature competition**: when all features are enabled, they compete for space within each test case, limiting the depth to which any single feature's logic can be explored. By removing competing features, swarm testing allows deeper exploration of the remaining features' state spaces.

Experimental results on C compiler testing (CSmith with Csmith's random program generator) demonstrate dramatic improvements: swarm testing found **42% more distinct compiler crashes** in one week compared to heavily hand-tuned default configurations. The technique also improved code coverage and found bugs that traditional testing missed entirely. Importantly, swarm testing requires minimal implementation effort—simply add probabilistic feature inclusion/exclusion to existing random test generators—making it an inexpensive way to improve testing diversity and effectiveness.

---

## Key Strategies/Techniques

1. **Feature Omission Diversity**: For each test configuration, randomly omit a subset of available features rather than including all features. In compiler testing, features included language constructs (pointers, arrays, structs, specific operators, control flow constructs).

2. **Probabilistic Feature Inclusion**: Each feature has an independent probability of being included in a given test configuration. The paper used **50% probability per feature** in their compiler experiments, though this can be tuned based on the system under test.

3. **Configuration Swarm**: Generate a large number of diverse configurations, each representing a different subset of enabled features. Each configuration receives equal computational budget (time or number of tests).

4. **Feature Space Exploration**: Systematically explore different regions of the system's state space by varying which features are active. This allows reaching deep states in specific features that would be obscured by interference from other features.

5. **Bug Trigger vs. Suppressor Analysis**: After finding bugs, analyze which features consistently appear (triggers) or are consistently absent (suppressors) across multiple configurations that expose the same bug. This helps with root cause analysis.

6. **Extreme Test Cases**: Feature omission creates edge cases like "only push operations" or "no pointer arithmetic" that rarely occur in traditional testing but effectively expose corner-case bugs.

7. **Minimal Implementation Overhead**: The technique requires minimal changes to existing random test generators—just add probabilistic feature enable/disable logic before test generation. No complex feedback mechanisms or instrumentation needed.

---

## Applicability to PropertyTestingKit

PropertyTestingKit implements **coverage-guided fuzzing** with corpus management, which operates differently from the **generational random testing** context where swarm testing was originally developed. However, several aspects of swarm testing are highly relevant and could provide complementary benefits to PropertyTestingKit's existing strategies.

### Current PropertyTestingKit Architecture

**Relevant capabilities:**

1. **Custom Mutators** (`Mutator` protocol):
   - Users can define domain-specific mutation strategies
   - Mutators can be composed and combined
   - Each mutator represents a "feature" in swarm testing terminology

2. **Multi-Strategy Mutations**:
   - Single-component mutations
   - Multi-component mutations
   - Arithmetic relationship mutations
   - Dictionary-based string mutations
   - Target-directed mutations (value profile guidance)

3. **Corpus Management**:
   - Coverage-guided selection prioritizes rare paths
   - Rarity-based scoring for corpus entry selection
   - Weighted random selection based on coverage novelty

4. **Seed Support**:
   - Initial seeds and additional seeds
   - Generation vs. mutation ratio control

### Conceptual Alignment

Swarm testing's feature omission maps naturally to PropertyTestingKit's mutation strategy selection. Instead of applying all available mutators to every corpus entry, swarm testing would:

1. **Mutator Subset Selection**: For each fuzzing session or time slice, randomly select which mutators to enable
2. **Deep Feature Exploration**: Focus computational effort on fewer mutation strategies per configuration, allowing deeper exploration
3. **Diversity Through Restriction**: Paradoxically increase diversity by restricting options, preventing dominant strategies from crowding out less-aggressive ones

### High-Value Strategies to Adopt

**Priority 1: Swarm-Based Mutator Selection (Medium Impact, Low Effort)**

The most direct application: randomly enable/disable subsets of available mutation strategies per fuzzing configuration or time window.

**Implementation approach:**

```swift
// In FuzzEngine.Config
public struct SwarmConfig {
    /// Enable swarm testing mode
    public var enabled: Bool = false

    /// Probability each mutation strategy is included (default 0.5)
    public var mutatorInclusionProbability: Double = 0.5

    /// How many iterations before resampling mutator configuration
    public var configurationWindow: Int = 1000

    /// Minimum number of mutation strategies to keep active
    public var minActiveMutators: Int = 1
}

// Add to FuzzEngine
private var activeMutatorConfiguration: Set<MutatorType>?

enum MutatorType {
    case singleComponent
    case multiComponent
    case arithmeticRelationship
    case dictionary
    case targetDirected
    case custom(String)  // Named custom mutators
}
```

**Usage in fuzzing loop:**

```swift
// Resample configuration every N iterations
if iteration % config.swarmConfig.configurationWindow == 0 {
    activeMutatorConfiguration = sampleSwarmConfiguration(
        probability: config.swarmConfig.mutatorInclusionProbability
    )
}

// Apply only active mutators
if let activeConfig = activeMutatorConfiguration {
    mutations = applyOnlyActiveMutators(parent, activeConfig)
} else {
    // Standard behavior: all mutators active
    mutations = mutateInput(parent)
}
```

**Expected impact:**

- **Deep exploration**: Disabling dictionary mutations might allow arithmetic mutations to explore deeper numeric state spaces
- **Feature interference reduction**: String mutations and numeric mutations won't compete for mutation slots in the same test case
- **Bug trigger identification**: Tracking which mutator configurations find specific bugs helps identify root causes

**Priority 2: Generator-Level Swarm Testing (High Impact, Medium Effort)**

Apply feature omission at the test input generation level, analogous to the paper's compiler testing approach.

**Implementation approach:**

For property tests with complex structured inputs (e.g., testing a parser with various language features), allow users to define feature sets and randomly enable/disable them:

```swift
public protocol FeatureSet {
    associatedtype Feature: Hashable
    var allFeatures: Set<Feature> { get }
}

public struct SwarmGenerator<T, F: FeatureSet> {
    let baseGenerator: (Set<F.Feature>) -> T
    let featureSet: F
    let inclusionProbability: Double

    public func generate() -> T {
        let enabledFeatures = featureSet.allFeatures.filter { _ in
            Double.random(in: 0..<1) < inclusionProbability
        }
        return baseGenerator(enabledFeatures)
    }
}
```

**Example usage:**

```swift
enum ProgramFeatures: FeatureSet {
    case arrays, pointers, structs, loops, recursion, exceptions

    var allFeatures: Set<ProgramFeatures> {
        [.arrays, .pointers, .structs, .loops, .recursion, .exceptions]
    }
}

let swarmGen = SwarmGenerator(
    baseGenerator: { features in
        generateProgram(withFeatures: features)
    },
    featureSet: ProgramFeatures.self,
    inclusionProbability: 0.5
)
```

**Expected impact:**

- Particularly effective for testing complex systems with many optional subsystems (compilers, parsers, interpreters, state machines)
- Finds bugs that only manifest when specific features are **absent** (initialization bugs, default value issues, fallback logic)
- Complements coverage-guided fuzzing: coverage feedback guides *which* inputs to mutate; swarm testing guides *which* features to include

**Priority 3: Adaptive Swarm Configuration (Medium Impact, Medium Effort)**

Instead of fixed 50% probability, adapt feature inclusion based on observed bug triggers and suppressors.

**Implementation approach:**

```swift
public class AdaptiveSwarmTracker {
    /// Track which features were enabled when each bug was found
    private var bugFeatureCorrelations: [BugID: Set<MutatorType>] = [:]

    /// Adjusted probabilities based on observed effectiveness
    private var adaptiveProbabilities: [MutatorType: Double] = [:]

    public func recordBugWithConfiguration(_ bugID: BugID, _ config: Set<MutatorType>) {
        bugFeatureCorrelations[bugID] = config
        updateAdaptiveProbabilities()
    }

    private func updateAdaptiveProbabilities() {
        // Features that consistently appear in bug-finding configs get boosted
        // Features that rarely appear get reduced probability
        // Similar to AFLFast's power scheduling but for feature selection
    }
}
```

**Expected impact:**

- Learns which feature combinations are most effective for specific targets
- Reduces wasted computation on ineffective feature combinations
- Provides actionable feedback: "Bugs most often found with mutators X and Y disabled"

### Moderate-Value Strategies

**Swarm Testing + Value Profile Guidance**: PropertyTestingKit's value profile tracking (comparison instruction interception) is orthogonal to swarm testing. Combining them could yield compounding benefits:

- Value profiles identify **what** numeric values to try (magic constants, comparison boundaries)
- Swarm testing determines **when** to focus on numeric vs. string vs. structural mutations
- Example: A configuration with only arithmetic mutations active + value profile guidance might crack magic constant comparisons faster than configurations with all mutators competing

**Corpus Entry Swarm Configurations**: Instead of global swarm configurations, apply different feature subsets to different corpus entries:

```swift
public struct CorpusEntry {
    // ... existing fields ...

    /// Which mutation strategies are permitted for this entry
    public var allowedMutators: Set<MutatorType>?
}

// When adding to corpus, assign random swarm configuration
corpus.add(
    input: newInput,
    signature: signature,
    allowedMutators: sampleSwarmConfiguration()
)
```

This creates a corpus where different entries specialize in different mutation strategies, similar to how different entries specialize in covering different paths.

**Bug Reproduction Minimization**: When a bug is found, use swarm testing's bug trigger/suppressor analysis to determine the minimal set of features (mutators) needed to reproduce it. This aids debugging and test case reduction.

### Low-Value Strategies (Limited Applicability)

1. **Simple Random Testing Without Coverage**: Swarm testing's original context was generational fuzzing without feedback. PropertyTestingKit's coverage guidance already provides strong feedback signals that reduce the need for blind diversity.

2. **Complete Feature Enumeration**: The paper's exhaustive feature grid searches are infeasible for large feature sets. PropertyTestingKit's existing weighted selection is more practical.

3. **Static Configuration**: Unlike coverage-guided feedback which adapts dynamically, pure swarm testing uses fixed probabilities. PropertyTestingKit should prefer adaptive approaches when possible.

---

## Concrete Recommendations

### Recommendation 1: Implement Basic Swarm Mutator Selection (Highest Priority)

**What**: Add optional swarm testing mode that randomly enables/disables mutation strategies per time window.

**Why**: This is the simplest, lowest-risk way to bring swarm testing benefits to PropertyTestingKit. It requires no changes to the core fuzzing loop, just mutation strategy filtering.

**How**:

1. Add `SwarmConfig` to `FuzzEngine.Config`:
```swift
public struct SwarmConfig: Sendable, Codable {
    public var enabled: Bool = false
    public var mutatorInclusionProbability: Double = 0.5
    public var configurationWindow: Int = 1000
}
```

2. Track active mutator configuration in `FuzzEngine`:
```swift
private var activeMutatorConfiguration: Set<MutatorType>?
private var iterationsSinceConfigurationChange: Int = 0
```

3. Resample configuration periodically:
```swift
if config.swarmConfig.enabled {
    if iterationsSinceConfigurationChange >= config.swarmConfig.configurationWindow {
        activeMutatorConfiguration = sampleSwarmConfiguration()
        iterationsSinceConfigurationChange = 0
    }
    iterationsSinceConfigurationChange += 1
}
```

4. Filter mutations based on active configuration:
```swift
func mutateInput(_ parent: Input) -> [Input] {
    var allMutations: [Input] = []

    if shouldApply(.singleComponent) {
        allMutations.append(contentsOf: singleComponentMutations(parent))
    }
    if shouldApply(.multiComponent) {
        allMutations.append(contentsOf: multiComponentMutations(parent))
    }
    // ... etc for each mutation type

    return allMutations
}

private func shouldApply(_ mutator: MutatorType) -> Bool {
    guard config.swarmConfig.enabled else { return true }
    return activeMutatorConfiguration?.contains(mutator) ?? true
}
```

**Impact**:
- Expected 10-25% improvement in bug detection rate based on paper's results
- Particularly effective for finding bugs that require deep exploration of specific mutation strategies
- Low risk: can be toggled off if ineffective for specific targets

**Effort**: ~4-6 hours implementation + testing

**Testing**:
- Create stress tests with multiple mutation strategies
- Compare bug detection rate with/without swarm mode over fixed time budget
- Verify configurations are being resampled correctly
- Track which configurations find bugs (for analysis)

**Code Location**:
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine.swift`
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine+Config.swift` (if separated)

### Recommendation 2: Add Swarm Statistics Tracking

**What**: Track and report which mutator configurations are finding bugs and achieving new coverage.

**Why**: Understanding which feature combinations are effective enables:
1. Debugging: identify root causes by analyzing bug-triggering configurations
2. Optimization: tune mutator inclusion probabilities based on effectiveness
3. Validation: verify swarm testing is providing benefits vs. baseline

**How**:

```swift
public struct SwarmStatistics: Sendable {
    /// How many times each configuration found new coverage
    public var configurationCoverageHits: [Set<MutatorType>: Int] = [:]

    /// How many times each configuration found bugs (crashes, assertions)
    public var configurationBugHits: [Set<MutatorType>: Int] = [:]

    /// Total number of configurations tested
    public var totalConfigurations: Int = 0

    /// Current active configuration
    public var currentConfiguration: Set<MutatorType>?
}

// Add to FuzzStats
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Swarm testing statistics (if enabled)
    public let swarmStats: SwarmStatistics?
}
```

**Impact**: Enables data-driven optimization of swarm parameters and mutator design.

**Effort**: ~2 hours

### Recommendation 3: Implement Feature-Based Test Generation API

**What**: Provide API for users to define feature sets and enable swarm-based generation for complex domains (lower priority, nice-to-have).

**Why**: The paper's primary application was compiler testing with language feature subsets. PropertyTestingKit users testing similarly complex systems (parsers, interpreters, DSLs) would benefit from analogous capabilities.

**How**:

```swift
public protocol FeatureFlagSet: Hashable, Sendable {
    static var allFeatures: Set<Self> { get }
}

public struct SwarmConfiguration<F: FeatureFlagSet> {
    public let enabledFeatures: Set<F>
    public let probability: Double

    public static func sample(probability: Double = 0.5) -> Self {
        let enabled = F.allFeatures.filter { _ in
            Double.random(in: 0..<1) < probability
        }
        return SwarmConfiguration(enabledFeatures: enabled, probability: probability)
    }
}

// Users define their feature space
enum MyLanguageFeatures: FeatureFlagSet {
    case arrays, pointers, loops, recursion, exceptions

    static var allFeatures: Set<MyLanguageFeatures> {
        [.arrays, .pointers, .loops, .recursion, .exceptions]
    }
}

// Use in property tests
@Test
func testCompiler() {
    fuzz(maxIterations: 10_000) { (config: SwarmConfiguration<MyLanguageFeatures>) in
        let program = generateProgram(withFeatures: config.enabledFeatures)
        let result = compiler.compile(program)
        #expect(result.isValid)
    }
}
```

**Impact**: Highly effective for testing complex systems with many optional components. Niche applicability but high value where relevant.

**Effort**: ~6-8 hours

**Priority**: Consider only after Recommendations 1-2 are implemented and show positive results.

### Recommendation 4: Document Swarm Testing in User Guide

**What**: Add documentation explaining when and how to use swarm testing effectively.

**Why**: Swarm testing is counterintuitive ("do less to find more"). Users need guidance on:
- When to enable it (complex mutation strategies, many custom mutators)
- How to configure it (probability tuning, window sizing)
- How to interpret results (configuration effectiveness analysis)

**Content outline**:

```markdown
## Swarm Testing Mode

Swarm testing improves fuzzing diversity by randomly enabling/disabling
mutation strategies. This paradoxically increases effectiveness by:

1. **Reducing interference**: Fewer active mutators means less competition
2. **Deeper exploration**: Focused mutation strategies explore deeper states
3. **Bug suppressor discovery**: Some bugs only appear when certain features are disabled

### When to Use
- Testing with 3+ custom mutators
- Complex domains with many mutation strategies
- When plateau detection triggers frequently (may indicate feature interference)

### Configuration
- `mutatorInclusionProbability: 0.5` - 50% chance each mutator is enabled (paper default)
- `configurationWindow: 1000` - Resample configuration every N iterations
- Lower probability for more diversity, higher for broader coverage

### Analysis
Review `SwarmStatistics` in fuzzing results to identify:
- Which configurations find bugs most often
- Whether swarm mode improves coverage vs. baseline
```

**Effort**: ~2 hours

---

## Implementation Priority

1. **Phase 1 (Immediate Value)**: Implement Recommendations 1 & 2
   - Basic swarm mutator selection (~4-6 hours)
   - Statistics tracking (~2 hours)
   - **Total: ~6-8 hours, expected 10-25% improvement**

2. **Phase 2 (Evaluation)**:
   - Run comprehensive stress tests comparing swarm vs. baseline
   - Analyze which targets benefit most
   - Tune default parameters based on empirical results
   - **Total: ~4 hours testing + analysis**

3. **Phase 3 (Optional Enhancements)**: Only if Phase 2 shows strong results
   - Feature-based generation API (Recommendation 3)
   - Adaptive swarm configuration
   - Documentation (Recommendation 4)
   - **Total: ~10-12 hours**

---

## Relationship to Other Techniques

**Swarm Testing + AFLFast Power Scheduling**:
- AFLFast optimizes *which* corpus entries to fuzz
- Swarm testing optimizes *how* to fuzz them (which mutation strategies)
- Complementary: can be combined for compounding benefits

**Swarm Testing + Value Profile Guidance**:
- Value profiles identify promising numeric values (magic constants, boundaries)
- Swarm testing can disable competing mutators to give arithmetic mutations more opportunities
- Example: configuration with only arithmetic mutations + value profiles might crack checksums faster

**Swarm Testing vs. Coverage-Guided Feedback**:
- Coverage guidance is about *where* you've been (adaptive, feedback-driven)
- Swarm testing is about *what* you're doing (proactive, diversity-driven)
- Not competing strategies—swarm testing adds diversity on top of coverage guidance

---

## Key Insights for PropertyTestingKit

1. **Feature suppression matters**: Including more mutation strategies isn't always better. Some mutations may prevent others from exploring deeply enough to trigger bugs.

2. **Diversity through restriction**: Paradoxically, restricting available mutations per configuration increases overall diversity across configurations.

3. **Low implementation cost**: Unlike complex techniques like power scheduling or value profiles, swarm testing requires minimal code changes—just probabilistic feature toggling.

4. **Debugging aid**: Tracking which mutator configurations find specific bugs provides actionable debugging information: "This crash only occurs when string mutations are disabled."

5. **Synergy with existing techniques**: Swarm testing complements rather than replaces PropertyTestingKit's existing strategies (coverage guidance, value profiles, corpus management).

---

## References

- Groce, A., Zhang, C., Eide, E., Chen, Y., & Regehr, J. (2012). Swarm testing. Proceedings of the 2012 International Symposium on Software Testing and Analysis (ISSTA '12), 78-88. https://users.cs.utah.edu/~regehr/papers/swarm12.pdf

- Groce, A. (2014). Better Random Testing by Leaving Features Out. Embedded in Academia blog. https://blog.regehr.org/archives/591

- Alipour, A., Groce, A., Gopinath, R., & Christi, A. (2016). Generating Focused Random Tests Using Directed Swarm Testing. Proceedings of the 25th International Symposium on Software Testing and Analysis (ISSTA '16), 70-81. https://agroce.github.io/issta16.pdf

- Hypothesis Issues #2643: Expand our use of swarm testing. https://github.com/HypothesisWorks/hypothesis/issues/2643

- Hypothesis Issues #1637: Support automatic 'swarm testing' for example selection. https://github.com/HypothesisWorks/hypothesis/issues/1637

---

## Notes

Swarm testing represents a philosophical shift in fuzzing: **constraint improves exploration**. By accepting that we can't exhaustively test all feature combinations in all depths, we instead systematically explore *many* feature subsets at *sufficient* depth rather than *all* features at *insufficient* depth.

For PropertyTestingKit, this manifests as mutation strategy management. Current fuzzing applies all available mutations to each corpus entry, potentially causing:
- **Shallow exploration**: Each mutation gets less "air time" per entry
- **Interference**: String mutations might overwrite numeric values that arithmetic mutations need to explore
- **Suppression**: Dictionary mutations might prevent exploration of edge cases that only appear without magic strings

Swarm testing addresses these issues with minimal implementation complexity, making it an ideal early enhancement for PropertyTestingKit.
