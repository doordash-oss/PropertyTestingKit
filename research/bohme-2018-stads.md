# STADS: Software Testing as Species Discovery

**Paper**: Böhme, M. (2018). STADS: Software Testing as Species Discovery. ACM Transactions on Software Engineering and Methodology, 27(2), Article 7.

**URL**: https://mboehme.github.io/paper/TOSEM18.pdf

---

## Paper Summary

This paper addresses a fundamental challenge in software testing: the statistically well-grounded extrapolation from program behaviors observed during testing to conclusions about untested behaviors. A security researcher who has run a fuzzer for a week has no rigorous means to estimate the total number of feasible program branches given that only a fraction has been covered, estimate the additional time required to cover 10% more branches, or assess the residual risk that a vulnerability exists when none has been discovered. Without such capabilities, testers cannot make informed decisions about when to stop testing, how much confidence to place in their results, or how to allocate testing resources across multiple projects.

Böhme establishes an unexpected connection with the scientific field of ecology, introducing a statistical framework that models Software Testing and Analysis as Discovery of Species (STADS). The analogy is direct: just as ecologists sample individuals from a tropical rain forest to determine their species and extrapolate properties of the entire forest, software testers sample program executions to observe coverage patterns and extrapolate properties of the entire program. Classical problems in ecology—estimating the total number of species, additional sampling effort required to discover 10% more species, and the probability of discovering a new species—map precisely to software testing challenges. STADS adapts over three decades of research in ecological biostatistics, including well-established estimators like Chao1 for total species richness and Good-Turing for discovery probability, to provide rigorous statistical guarantees for fuzzing campaigns.

The paper demonstrates that these ecological estimators remain statistically consistent even for fuzzers with adaptive sampling bias like AFL (American Fuzzy Lop), meaning bias decreases and precision increases as more test inputs are generated. The framework provides quantifiable confidence bounds for stopping decisions, progress metrics grounded in statistical theory, and estimates of residual vulnerability risk based on observed testing outcomes. By treating each unique coverage signature (execution path, branch tuple, or other program behavior) as a distinct "species," STADS enables testers to reason mathematically about what remains undiscovered based on the frequency distribution of discovered behaviors. This transforms fuzzing from an ad-hoc "run until bored" activity into a statistically principled engineering practice with measurable guarantees.

---

## Key Strategies/Techniques

1. **Species-Program Behavior Mapping**: Maps unique program behaviors (coverage signatures, execution paths, branch tuples) to ecological species. Each distinct coverage pattern observed during testing represents a different "species." This abstraction enables the application of ecological statistical methods to software testing data.

2. **Chao1 Estimator for Total Coverage**: Applies the Chao1 species richness estimator to estimate the total number of feasible program branches or execution paths. The formula is: `Ŝ = S_obs + f₁²/(2f₂)` where `S_obs` is observed species count, `f₁` is the number of singletons (behaviors seen exactly once), and `f₂` is the number of doubletons (behaviors seen exactly twice). This provides a lower bound on total program behaviors based on the distribution of rare observations.

3. **Good-Turing Estimator for Discovery Probability**: Uses the Good-Turing estimator to calculate the probability that the next test input will discover a new coverage pattern. The Good-Turing estimate also provides an upper bound on residual vulnerability risk—the probability that a vulnerability exists but has not yet been found. This addresses the critical question: "How confident can I be that no bugs remain?"

4. **Singleton and Doubleton Frequency Analysis**: Tracks the number of coverage patterns observed exactly once (singletons) and exactly twice (doubletons) during fuzzing. These rare observations carry the most information about unobserved behaviors. A high singleton/doubleton ratio suggests many undiscovered paths remain; a low ratio suggests the fuzzer is approaching saturation.

5. **Temporal Extrapolation**: Projects future coverage growth based on current discovery rates. Given the current fuzzing progress, STADS can estimate how many additional test executions are required to achieve a target coverage level (e.g., "10% more branches"). This enables informed resource allocation and scheduling decisions.

6. **Spatial Extrapolation**: Estimates properties of the entire program (the "population") from the subset of behaviors observed during testing (the "sample"). This includes estimating total feasible branches, total reachable program states, and the completeness of current coverage.

7. **Statistical Correctness Guarantees**: Provides quantifiable confidence bounds and measures of precision for all estimates. Unlike heuristic stopping rules, STADS estimates come with statistical guarantees that improve as more testing is performed, allowing rigorous evaluation of fuzzing campaign quality.

8. **Adaptive Sampling Bias Handling**: Demonstrates that ecological estimators remain valid even when the fuzzer employs adaptive sampling (like AFL's coverage-guided corpus selection). The paper proves that despite AFL preferentially sampling certain inputs, the estimators are statistically consistent as sample size increases.

9. **Residual Risk Quantification**: Estimates the maximum probability that a vulnerability exists given that none has been found. This transforms the qualitative statement "no bugs found" into a quantitative risk assessment like "95% confidence that residual vulnerability risk is below 0.1%."

10. **Coverage-Based Stopping Rules**: Establishes principled stopping criteria based on statistical confidence rather than arbitrary thresholds. Testers can stop when estimated coverage exceeds a target threshold, when discovery probability drops below a minimum value, or when residual risk falls below acceptable levels.

---

## Applicability to PropertyTestingKit

PropertyTestingKit implements coverage-guided fuzzing with corpus management, making it an excellent candidate for STADS integration. The framework's statistical methods would provide rigorous answers to questions currently unanswerable: "How much more fuzzing is needed?", "What's the probability of finding another bug?", and "Should I stop or continue?"

### Current PropertyTestingKit Architecture

**Existing capabilities that align with STADS:**

1. **Coverage tracking** (`CoverageTracker.swift`, `CoverageSignature.swift`):
   - Tracks coverage with bucketed execution counts (AFL-style: 0, 1, 2, 3, 4-7, 8-15, etc.)
   - Records unique coverage signatures for each corpus entry
   - Maintains `executedIndices` representing covered branches/blocks
   - Already has the data needed to identify "species" (unique coverage patterns)

2. **Corpus management** (`Corpus.swift`):
   - Maintains collection of inputs with their coverage signatures
   - Tracks which coverage patterns have been discovered
   - Already computes frequency of each coverage index across corpus entries
   - Can easily extract singleton and doubleton counts

3. **Statistics reporting** (`FuzzStats.swift`):
   - Reports `totalIterations`, `totalCoverage`, `uniqueInputsGenerated`
   - Tracks `iterationsSinceNewCoverage` for plateau detection
   - Foundation for STADS metrics integration

4. **Plateau detection** (`FuzzEngine.swift`):
   - Uses `plateauThreshold` to stop when no new coverage found
   - Current approach is heuristic; STADS would make it statistically principled

**Current gaps vs STADS:**

1. **No statistical extrapolation**: PropertyTestingKit reports observed coverage but cannot estimate total feasible coverage or time to reach coverage goals.

2. **No residual risk estimation**: When fuzzing finds no bugs, PropertyTestingKit cannot quantify confidence that no bugs remain.

3. **No discovery probability tracking**: Cannot estimate likelihood that the next iteration will discover new coverage.

4. **Heuristic stopping rules**: Plateau detection uses fixed iteration thresholds rather than statistical confidence bounds.

5. **No species frequency distribution**: While PropertyTestingKit tracks which coverage indices are executed, it doesn't maintain frequency distributions needed for Chao1/Good-Turing estimators.

### High-Value Strategies to Adopt

**Priority 1: Chao1 Coverage Estimation (High Impact, Low Effort)**

The Chao1 estimator provides a statistically rigorous estimate of total feasible coverage based on singleton and doubleton frequencies. This is STADS's most immediately valuable contribution.

```swift
// Add to CoverageTracker or new STADSEstimator class
public struct STADSEstimator {
    /// Calculate Chao1 estimate of total species (coverage indices)
    public static func estimateTotalCoverage(
        observedSpecies: Int,
        singletons: Int,
        doubletons: Int
    ) -> Double {
        let S_obs = Double(observedSpecies)
        let f1 = Double(singletons)
        let f2 = Double(doubletons)

        guard f2 > 0 else {
            // When no doubletons, use alternative formula
            if f1 > 0 {
                return S_obs + (f1 * (f1 - 1)) / 2.0
            }
            return S_obs
        }

        // Standard Chao1: Ŝ = S_obs + f₁²/(2f₂)
        return S_obs + (f1 * f1) / (2.0 * f2)
    }
}
```

**Priority 2: Species Frequency Tracking (Medium Impact, Low Effort)**

Track how many times each unique coverage pattern has been observed to enable singleton/doubleton counting.

```swift
// Add to Corpus or CoverageTracker
public struct SpeciesFrequencyTracker {
    /// Map from coverage signature hash to observation count
    private var speciesObservationCounts: [Int: Int] = [:]

    /// Record observation of a species (coverage pattern)
    public mutating func recordObservation(signature: CoverageSignature) {
        let hash = signature.hashValue
        speciesObservationCounts[hash, default: 0] += 1
    }

    /// Count of species observed exactly once (singletons)
    public var singletonsCount: Int {
        speciesObservationCounts.values.filter { $0 == 1 }.count
    }

    /// Count of species observed exactly twice (doubletons)
    public var doubletonsCount: Int {
        speciesObservationCounts.values.filter { $0 == 2 }.count
    }

    /// Total number of unique species observed
    public var totalSpecies: Int {
        speciesObservationCounts.count
    }
}
```

**Priority 3: Good-Turing Discovery Probability (High Impact, Medium Effort)**

Estimate the probability that the next test will discover new coverage, and use this to quantify residual vulnerability risk.

```swift
// Add to STADSEstimator
public struct STADSEstimator {
    /// Calculate Good-Turing estimate of discovery probability
    /// Also serves as upper bound on residual vulnerability risk
    public static func estimateDiscoveryProbability(
        singletons: Int,
        totalObservations: Int
    ) -> Double {
        guard totalObservations > 0 else { return 1.0 }

        // Good-Turing: P(new) ≈ f₁ / N
        // where f₁ is singleton count and N is total observations
        return Double(singletons) / Double(totalObservations)
    }

    /// Estimate residual vulnerability risk
    /// Upper bound on probability that an undetected vulnerability exists
    public static func estimateResidualRisk(
        singletons: Int,
        totalObservations: Int,
        vulnerabilitiesFound: Int
    ) -> Double {
        // When no vulnerabilities found, discovery probability
        // provides upper bound on residual risk
        guard vulnerabilitiesFound == 0 else {
            // When vulnerabilities found, risk estimation is more complex
            // (requires models of vulnerability distribution)
            return 1.0
        }

        return estimateDiscoveryProbability(
            singletons: singletons,
            totalObservations: totalObservations
        )
    }
}
```

**Priority 4: Statistical Stopping Rules (High Impact, Medium Effort)**

Replace heuristic plateau detection with statistically principled stopping criteria.

```swift
// Add to FuzzEngine.Config
public struct Config {
    // ... existing fields ...

    /// Stop when discovery probability drops below this threshold
    public var minDiscoveryProbability: Double = 0.01  // 1%

    /// Stop when estimated coverage completeness exceeds this threshold
    public var targetCoverageCompleteness: Double = 0.95  // 95%

    /// Stop when residual risk drops below this threshold
    public var maxAcceptableRisk: Double = 0.05  // 5%

    /// Use STADS-based stopping rules instead of heuristic plateau detection
    public var useSTADSStoppingRules: Bool = true
}

// In FuzzEngine.runFuzzing()
private func shouldStopFuzzing(
    frequencyTracker: SpeciesFrequencyTracker,
    iteration: Int
) -> Bool {
    guard config.useSTADSStoppingRules else {
        // Fall back to heuristic plateau detection
        return iterationsSinceNewCoverage >= config.plateauThreshold
    }

    let singletons = frequencyTracker.singletonsCount
    let doubletons = frequencyTracker.doubletonsCount
    let observedSpecies = frequencyTracker.totalSpecies

    // Calculate STADS metrics
    let estimatedTotal = STADSEstimator.estimateTotalCoverage(
        observedSpecies: observedSpecies,
        singletons: singletons,
        doubletons: doubletons
    )

    let coverageCompleteness = Double(observedSpecies) / estimatedTotal

    let discoveryProbability = STADSEstimator.estimateDiscoveryProbability(
        singletons: singletons,
        totalObservations: iteration
    )

    // Stop if any criterion met
    return coverageCompleteness >= config.targetCoverageCompleteness
        || discoveryProbability <= config.minDiscoveryProbability
}
```

**Priority 5: STADS Statistics Reporting (Medium Impact, Low Effort)**

Add STADS metrics to `FuzzStats` for visibility and decision-making.

```swift
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Total unique species (coverage patterns) observed
    public let observedSpecies: Int

    /// Number of singleton species (observed once)
    public let singletons: Int

    /// Number of doubleton species (observed twice)
    public let doubletons: Int

    /// Chao1 estimate of total feasible species
    public let estimatedTotalSpecies: Double

    /// Current coverage completeness (observed / estimated total)
    public let coverageCompleteness: Double

    /// Good-Turing estimate of discovery probability
    public let discoveryProbability: Double

    /// Estimated residual vulnerability risk (upper bound)
    public let estimatedResidualRisk: Double

    /// Estimated additional iterations to reach 10% more coverage
    public let estimatedIterationsFor10MorePercent: Int?
}
```

**Priority 6: Temporal Extrapolation (Medium Impact, High Effort)**

Estimate time required to achieve coverage goals based on current discovery rate.

```swift
public struct STADSEstimator {
    /// Estimate iterations required to reach target coverage
    public static func estimateIterationsToTarget(
        currentSpecies: Int,
        targetSpecies: Double,
        recentDiscoveryRate: Double
    ) -> Int? {
        guard recentDiscoveryRate > 0 else { return nil }

        let remaining = targetSpecies - Double(currentSpecies)
        guard remaining > 0 else { return 0 }

        // Assume discovery rate decays as coverage increases
        // Use exponential model: new_rate = current_rate * exp(-k * time)
        // This requires tracking discovery rate over time

        // Simplified linear projection (conservative):
        return Int(ceil(remaining / recentDiscoveryRate))
    }
}
```

### Moderate-Value Strategies

**Confidence Intervals**: STADS estimators can provide confidence bounds on all estimates. Add statistical confidence intervals to reported metrics:

```swift
public struct CoverageEstimate {
    public let pointEstimate: Double
    public let lowerBound: Double  // 95% confidence interval
    public let upperBound: Double
    public let standardError: Double
}
```

**Alternative Estimators**: STADS discusses multiple estimators (Chao1, ACE, Jackknife). PropertyTestingKit could implement several and report consensus estimates:

```swift
public enum SpeciesEstimator {
    case chao1
    case ace  // Abundance-based Coverage Estimator
    case jackknife

    func estimate(/* ... */) -> Double { /* ... */ }
}
```

**Species Definition Flexibility**: Allow users to define what constitutes a "species"—could be unique coverage signatures, unique crash signatures, unique execution paths, etc.:

```swift
public enum SpeciesDefinition {
    case coverageSignature  // Current approach
    case executionPath      // Full trace
    case crashSignature     // For bug diversity estimation
    case customHash((Input) -> Int)
}
```

### Low-Value Strategies (Not Applicable or Already Covered)

1. **Basic coverage tracking**: Already implemented comprehensively in PropertyTestingKit.

2. **Corpus minimization**: Already implemented; orthogonal to STADS.

3. **AFL-specific adaptations**: STADS paper validates estimators for AFL; PropertyTestingKit uses similar coverage-guided approach so same validations apply.

4. **Large population handling**: STADS discusses challenges with millions of branches. PropertyTestingKit targets Swift programs which typically have smaller branch counts than C/C++ programs tested in STADS evaluation.

---

## Concrete Recommendations

### Recommendation 1: Implement Core STADS Estimators (Highest Priority)

**What**: Add `STADSEstimator` utility with Chao1 and Good-Turing implementations.

**Why**: These estimators transform PropertyTestingKit from a coverage-guided fuzzer into a statistically principled testing framework. Users gain rigorous answers to critical questions: "How complete is my testing?", "What's the probability of finding more bugs?", "When can I stop?"

**How**:
1. Create `Sources/PropertyTestingKit/STADS/STADSEstimator.swift`
2. Implement `estimateTotalCoverage()` using Chao1 formula
3. Implement `estimateDiscoveryProbability()` using Good-Turing formula
4. Implement `estimateResidualRisk()` as upper bound on vulnerability probability
5. Add unit tests with known distributions to verify estimator accuracy

**Impact**: Provides statistically valid coverage estimates and risk quantification. In ecology, Chao1 accuracy is typically within 10-20% of true species counts; expect similar accuracy for feasible branch estimation.

**Effort**: ~4-6 hours implementation + testing

**Code Location**: New file `Sources/PropertyTestingKit/STADS/STADSEstimator.swift`

### Recommendation 2: Add Species Frequency Tracking (High Priority)

**What**: Track observation counts for each unique coverage signature to enable singleton/doubleton counting.

**Why**: This is the foundational data structure for all STADS estimators. Without frequency tracking, Chao1 and Good-Turing cannot be computed.

**How**:
1. Create `SpeciesFrequencyTracker` struct
2. Add `recordObservation()` method called whenever corpus entry is executed
3. Maintain hash-to-count mapping for all observed signatures
4. Provide properties for `singletonsCount`, `doubletonsCount`, `totalSpecies`
5. Integrate into `FuzzEngine` to record every test execution

**Impact**: Enables all STADS estimators. Minimal performance overhead (single hash map operation per test).

**Effort**: ~2-3 hours implementation + integration

**Code Location**: `Sources/PropertyTestingKit/STADS/SpeciesFrequencyTracker.swift`, integrate in `FuzzEngine.swift`

### Recommendation 3: Integrate STADS into FuzzStats (High Priority)

**What**: Add STADS metrics to `FuzzStats` structure and report them alongside existing statistics.

**Why**: Makes statistical estimates visible to users. Enables data-driven decisions about when to stop fuzzing, whether to allocate more resources, and how to interpret results.

**How**:
1. Add STADS-related fields to `FuzzStats` (see Priority 5 code example)
2. Calculate STADS metrics at end of fuzzing campaign
3. Include STADS metrics in test output and logs
4. Format metrics with clear explanations (e.g., "Coverage Completeness: 87% (95% CI: 82-92%)")

**Impact**: Transforms fuzzing from black-box activity into transparent, measurable process. Users can make informed decisions about testing adequacy.

**Effort**: ~2 hours

**Code Location**: `Sources/PropertyTestingKit/Fuzzing/FuzzStats.swift`

### Recommendation 4: Implement STADS-Based Stopping Rules (Medium Priority)

**What**: Replace heuristic plateau detection with statistical stopping criteria based on discovery probability and coverage completeness.

**Why**: Current plateau detection is arbitrary (stop after N iterations without coverage). STADS provides principled stopping rules with statistical guarantees: stop when discovery probability drops below threshold OR coverage completeness exceeds target.

**How**:
1. Add configuration options for STADS stopping criteria
2. Calculate discovery probability and coverage completeness each iteration
3. Stop when statistical criteria met instead of iteration count
4. Make STADS stopping rules opt-in via config flag
5. Log stopping reason with statistical justification

**Impact**: Reduces wasted computation (stop sooner when saturated) while providing statistical confidence in results. May reduce fuzzing time by 10-30% for equivalent coverage confidence.

**Effort**: ~3-4 hours

**Code Location**: `Sources/PropertyTestingKit/Fuzzing/FuzzEngine.swift`

### Recommendation 5: Add Temporal Extrapolation (Lower Priority)

**What**: Estimate iterations/time required to reach coverage goals based on current discovery rate.

**Why**: Helps with resource planning and timeline estimation. Users can answer: "How much longer until 90% coverage?" or "Should I allocate more machines to this fuzzing campaign?"

**How**:
1. Track discovery rate over time (species per 1000 iterations)
2. Model discovery rate decay (exponential or power law)
3. Project iterations to reach target coverage levels
4. Add `estimateIterationsToTarget()` method
5. Report projections in `FuzzStats`

**Impact**: Enables better resource allocation and project planning. Particularly valuable for continuous integration environments with time budgets.

**Effort**: ~6-8 hours (requires modeling discovery rate dynamics)

**Code Location**: `Sources/PropertyTestingKit/STADS/STADSEstimator.swift`, `Sources/PropertyTestingKit/Fuzzing/FuzzEngine.swift`

### Recommendation 6: Validate Estimator Accuracy (Lower Priority)

**What**: Conduct empirical study on PropertyTestingKit fuzzing campaigns to validate STADS estimator accuracy.

**Why**: STADS paper validates estimators on AFL fuzzing C programs. PropertyTestingKit targets Swift with different coverage instrumentation and program characteristics. Validation ensures estimators remain accurate in this context.

**How**:
1. Run long fuzzing campaigns (24-48 hours) on diverse Swift programs
2. Compare Chao1 estimates at various points to final observed coverage
3. Track estimation error and confidence interval coverage
4. Document any systematic biases or adjustments needed
5. Publish validation results as research note

**Impact**: Increases confidence in STADS metrics. May reveal Swift-specific adjustments needed for optimal estimator performance.

**Effort**: ~16-24 hours (requires extensive fuzzing experiments)

**Code Location**: Add to stress tests, document in `research/stads-validation.md`

---

## Implementation Priority

1. **Implement Recommendations 1-3** (Core STADS Infrastructure): ~8-11 hours total, provides foundation for statistical testing
2. **Implement Recommendation 4** (STADS Stopping Rules): ~3-4 hours, immediate practical benefit
3. **Evaluate impact** with existing stress tests and real-world fuzzing campaigns
4. **Consider Recommendation 5** (Temporal Extrapolation) if resource planning becomes priority
5. **Consider Recommendation 6** (Validation Study) as longer-term research project

---

## References

- Böhme, M. (2018). STADS: Software Testing as Species Discovery. ACM Transactions on Software Engineering and Methodology, 27(2), Article 7. https://dl.acm.org/doi/10.1145/3210309
- Chao, A. (1984). Nonparametric estimation of the number of classes in a population. Scandinavian Journal of Statistics, 11(4), 265-270.
- Good, I. J. (1953). The population frequencies of species and the estimation of population parameters. Biometrika, 40(3-4), 237-264.
- Colwell, R. K., & Coddington, J. A. (1994). Estimating terrestrial biodiversity through extrapolation. Philosophical Transactions of the Royal Society B, 345(1311), 101-118.
- The Fuzzing Book - When To Stop Fuzzing: https://www.fuzzingbook.org/html/WhenToStopFuzzing.html

---

## Notes

### STADS Complements PropertyTestingKit's Strengths

PropertyTestingKit already has advanced fuzzing capabilities that STADS does not address:
- **Value profile guidance** for comparison tracking and target-directed mutation
- **Custom mutators** for domain-specific input generation
- **Multi-component mutations** for correlated inputs
- **String dictionary capture** for magic constant discovery
- **Arithmetic relationship mutations** for checksum-style conditions

STADS adds orthogonal capabilities:
- **Statistical rigor** for coverage estimation and stopping decisions
- **Residual risk quantification** when no bugs found
- **Discovery probability tracking** for resource allocation
- **Principled stopping rules** based on statistical confidence

The combination is powerful: PropertyTestingKit's coverage-guided mutations discover program behaviors efficiently, while STADS provides statistical guarantees about the completeness and adequacy of those discoveries.

### Key Insight: Species Definition Flexibility

The beauty of STADS is its abstraction: any notion of "program behavior" can be modeled as a species. PropertyTestingKit could apply STADS to multiple dimensions:
- **Coverage species**: Unique coverage signatures (current approach)
- **Crash species**: Unique crash signatures (bug diversity estimation)
- **Input species**: Unique input structure patterns (input space coverage)
- **Comparison species**: Unique comparison operand patterns (value profile coverage)

Each species definition answers different questions about testing completeness.

### Limitation: No Ground Truth

Unlike ecology where ground truth can eventually be discovered (census entire forest), software testing never has ground truth (total feasible coverage is undecidable). STADS estimates are lower bounds with statistical confidence intervals, not exact answers. Users must understand this limitation and use estimates for relative comparisons and stopping decisions, not absolute guarantees.

### Connection to Other Research

STADS is part of Böhme's broader research program on statistical fuzzing:
- **AFLFast (2016)**: Power schedules for efficient coverage discovery
- **STADS (2018)**: Statistical estimation of coverage completeness
- **Exponential Cost (2020)**: Fundamental limits on vulnerability discovery

PropertyTestingKit has already implemented AFLFast-inspired techniques. Adding STADS completes the picture: efficient discovery (AFLFast power schedules) + rigorous evaluation (STADS estimators) = statistically principled fuzzing framework.
