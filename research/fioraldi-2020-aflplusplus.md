# AFL++: Combining Incremental Steps of Fuzzing Research

**Paper:** Fioraldi et al., "AFL++: Combining Incremental Steps of Fuzzing Research", USENIX WOOT 2020
**URL:** https://www.usenix.org/system/files/woot20-paper-fioraldi.pdf
**GitHub:** https://github.com/AFLplusplus/AFLplusplus

---

## Paper Summary

AFL++ is a community-driven enhancement to AFL (American Fuzzy Lop) that integrates multiple state-of-the-art fuzzing research advances into a single, production-ready fuzzing framework. Rather than proposing a single novel technique, AFL++ addresses a critical problem in the fuzzing research community: while individual research papers demonstrate improvements on specific benchmarks, these techniques are often evaluated in isolation, remain difficult to reproduce, and are rarely integrated into practical tools. AFL++ serves as a comprehensive platform that combines collision-free instrumentation, adaptive mutation scheduling (MOPT), input-to-state correspondence (Redqueen), compiler-level transformations (laf-intel), optimized power schedules (AFLfast++), and a flexible custom mutator API.

The paper's key insight is that fuzzing techniques are highly target-dependent: a method that dramatically improves performance on one program may degrade it on another. Through comprehensive evaluation on diverse targets, the authors demonstrate this variability and argue that future fuzzing research should evaluate not just single-technique effectiveness versus baseline AFL, but also how techniques interact when combined. AFL++ provides the infrastructure to enable this combinatorial testing while remaining practical for security researchers and developers who need a robust, maintainable fuzzing tool. The framework intentionally prioritizes compatibility, allowing users to enable or disable specific features based on their target's characteristics.

By consolidating years of fuzzing research into a single actively-maintained codebase, AFL++ aims to become the new baseline for both practical fuzzing campaigns and future research evaluation, reducing the fragmentation that occurs when each research group maintains isolated forks of AFL with incompatible modifications.

---

## Key Strategies/Techniques

1. **Collision-Free Instrumentation (LTO Mode)**: Implements link-time instrumentation that assigns unique IDs to each edge in the control flow graph, eliminating the coverage map collisions inherent in vanilla AFL's random edge ID assignment. This prevents the fuzzer from missing new paths due to hash collisions, which become increasingly problematic as program size grows (with a 64KB map, AFL has collisions at just 256 instrumented blocks). AFL++ achieves this through LLVM link-time optimization (LTO), instrumenting after all compilation units are combined.

2. **LAF-Intel Compiler Transformations**: Applies compiler-level transformations to circumvent fuzzing roadblocks, particularly "magic byte" comparisons that are difficult to satisfy through random mutation. The technique splits large comparisons into cascaded smaller comparisons (e.g., transforming `if (x == 0xabad1dea)` into `if ((x & 0xff) == 0xea) if ((x >> 8 & 0xff) == 0x1d)...`), transforms switch statements into if-else chains, and decomposes string comparison functions (strcmp, memcmp) into byte-by-byte comparisons. This provides gradual coverage feedback as the fuzzer gets "closer" to the correct value, increasing probability of solving constraints from 2^32 to approximately 2^9.

3. **Redqueen/CmpLog (Input-to-State Correspondence)**: Instruments the target to capture comparison operands during execution and uses lightweight "colorization" to approximate taint tracking without the performance overhead. When the fuzzer observes a comparison like `if (input_bytes == 0xdeadbeef)`, it automatically inserts the literal `0xdeadbeef` into the input at various positions, effectively building a dynamic dictionary of magic values. This technique is faster than laf-intel and particularly effective when the target doesn't heavily transform input data before comparison, solving both magic bytes and checksum validation problems.

4. **MOPT (Optimized Mutation Scheduling)**: Implements adaptive mutation operator scheduling using Particle Swarm Optimization (PSO). Instead of applying mutation operators with fixed probabilities, MOPT learns which operators (bit flips, arithmetic mutations, block deletions, etc.) are most effective for the current target and dynamically adjusts their selection probabilities. The fuzzer runs in three phases: pilot mode (uniform exploration), core mode (PSO-driven adaptation), and pacemaker mode (periodic reversion to uniform to escape local optima). AFL++ implements both the core and pilot modes of MOPT, with extensions to work with other AFL++ features.

5. **AFLfast++ Power Schedules**: Extends AFLfast's power scheduling algorithms that control how much fuzzing energy (number of mutations) to allocate to each corpus entry. Implements multiple schedules including explore (balanced), fast (favor rarely-hit paths), exploit (favor high-coverage seeds), coe (cut-off exponential), and rare (favor low-frequency edges). Different schedules excel on different targets, so AFL++ supports per-instance schedule assignment in parallel fuzzing setups, with recommendations like running the main instance with exploit and secondaries with combinations of fast and explore.

6. **Custom Mutator API**: Provides a comprehensive plugin interface allowing users to implement structure-aware mutations for domain-specific formats (JSON, XML, network protocols, etc.). The API exposes hooks at multiple stages of the fuzzing process: pre-save (input trimming), post-load (input loading), fuzz (mutation), queue entry addition, and introspection. Mutators can be written in C/C++, Python, or Rust, and multiple mutators can be chained. The API also supports custom trimming functions to minimize interesting inputs, integration with external generators, and optional configuration of AFL++ parameters by the mutator.

7. **QEMU 5.1 Upgrade with CompareCoverage**: Upgrades AFL's QEMU mode (for fuzzing binaries without source code) to version 5.1 with enhanced comparison coverage tracking. This allows black-box fuzzing to benefit from techniques like Redqueen that previously required source instrumentation.

8. **InsTrim Instrumentation**: Provides selective instrumentation that allows users to focus coverage tracking on specific code regions while ignoring others. This is useful when certain code paths (like error handling, logging, or library code) are known to be less interesting for vulnerability discovery.

9. **Persistent Mode and Deferred Initialization**: Optimizes fuzzer throughput by keeping the target process alive across multiple test cases rather than fork/exec for each input. Deferred initialization allows the fuzzer to delay expensive setup (file parsing, memory allocation) until after the fork point, maximizing the work done in the shared parent process.

10. **Dictionary Generation**: Automatically extracts string literals and comparison constants during compilation and embeds them in the instrumented binary. At fuzzing start, these are transferred to the fuzzer as a dynamic dictionary, improving coverage discovery by approximately 5-10% statistically.

---

## Applicability to PropertyTestingKit

**Moderate-to-High Applicability** - While PropertyTestingKit and AFL++ operate in very different contexts (Swift Testing framework vs. native binary fuzzing), several core concepts translate well to PropertyTestingKit's architecture. The primary difference is that PropertyTestingKit performs type-aware, structured fuzzing of Swift code through the testing framework, while AFL++ performs binary-level, coverage-guided fuzzing of native executables. However, both share fundamental fuzzing primitives: coverage tracking, corpus management, mutation strategies, and feedback-driven input selection.

### Current PropertyTestingKit Architecture

PropertyTestingKit already implements several AFL-style concepts:

- **Coverage-guided corpus management**: Tracks coverage signatures for each input and maintains a corpus of inputs that discovered unique coverage
- **Energy-based input selection**: Uses power scheduling to select corpus entries for mutation, favoring rare coverage paths
- **Multiple mutation strategies**: Supports both protocol-based mutations (`Fuzzable`) and composable domain-specific mutators (`Mutator` types)
- **Value profile guidance**: Tracks comparison operands when compiled with `-sanitize-coverage=trace-cmp`, similar to Redqueen
- **String dictionary capture**: Automatically captures string literals for dictionary-based mutations
- **Corpus persistence and regression**: Saves successful corpora to disk and supports regression testing

### Where AFL++ Techniques Can Be Applied

**1. MOPT Adaptive Mutation Scheduling** (High Applicability)

This is the most directly applicable technique. PropertyTestingKit currently applies mutations uniformly, but MOPT's approach of tracking which mutation strategies discover new coverage most frequently could significantly improve efficiency. PropertyTestingKit's `ComposedMutator` combines multiple strategies but treats them equally:

```swift
public func mutate(_ value: Value) -> [Value] {
    mutators.flatMap { $0.mutate(value) }  // Equal weighting
}
```

An MOPT-inspired enhancement would track per-mutator effectiveness and implement weighted sampling. The three-phase approach (pilot → core → pacemaker) maps naturally to PropertyTestingKit's iteration-based fuzzing loop. See the [MOPT research summary](lyu-2019-mopt.md) for detailed recommendations on implementing this in PropertyTestingKit.

**2. Power Schedule Diversity** (Moderate Applicability)

PropertyTestingKit already implements energy-based input selection that favors rare coverage paths. AFL++'s insight about using diverse power schedules across parallel fuzzing instances could improve PropertyTestingKit's parallel fuzzing story. Currently, PropertyTestingKit doesn't explicitly support running multiple parallel fuzzing instances with different strategies. Implementing schedule diversity would require:

- Multiple predefined power schedules beyond the current rarity-based approach
- Configuration to assign different schedules to different fuzzing instances
- Shared corpus synchronization between instances

However, PropertyTestingKit's smaller iteration counts (10,000 default vs AFL's millions) and Swift Testing's per-test isolation may reduce the benefits compared to long-running binary fuzzing campaigns.

**3. Collision-Free Coverage** (Low Applicability)

AFL++'s collision-free instrumentation solves a problem that doesn't exist in PropertyTestingKit. PropertyTestingKit uses Swift's SanitizerCoverage runtime callbacks (`__sanitizer_cov_trace_pc_guard`) which provide instrumentation-assigned IDs that are already collision-free within a single binary. The collision problem in vanilla AFL stems from AFL's compile-time random ID assignment, which PropertyTestingKit doesn't use. No action needed here.

**4. LAF-Intel Split Comparisons** (Low-to-Moderate Applicability)

LAF-intel's compiler transformations split large comparisons to provide gradual feedback. PropertyTestingKit already addresses this through value profile guidance: when compiled with `-sanitize-coverage=trace-cmp`, comparison operands are captured and the fuzzer can perform target-directed mutations toward specific values. This is actually *more sophisticated* than laf-intel's static splitting because it's dynamic and works for any comparison operator, not just equality checks.

However, laf-intel's switch statement transformation (converting switches to if-else chains) could theoretically help if Swift's switch statements don't generate coverage feedback for each case. This would require investigation into how Swift's compiled switch statements interact with SanitizerCoverage instrumentation.

**5. Redqueen/CmpLog** (Moderate Applicability - Partially Implemented)

PropertyTestingKit's value profile guidance already implements the core idea of Redqueen: capturing comparison operands and performing target-directed mutations. The key difference is Redqueen's "colorization" technique for lightweight taint tracking to determine which input bytes influenced which comparisons. PropertyTestingKit doesn't currently track byte-level input-to-state correspondence.

For Swift Testing targets, full Redqueen-style colorization may be overkill because PropertyTestingKit operates on structured Swift types rather than byte arrays. However, a simplified version could track which parameter in a multi-parameter test influenced which comparison, enabling more targeted mutations. For example, if `test(username: String, password: String)` shows that a comparison involves the password parameter, focus mutations on that parameter.

**6. Custom Mutator API** (Already Well Implemented)

PropertyTestingKit already has a sophisticated mutator system through the `Mutator` protocol and `ComposedMutator`. The existing API provides:

- Type-safe mutations through Swift protocols
- Composability via `ComposedMutator`
- Domain-specific mutators (SQL injection, XSS, phone numbers, etc.)
- Seed value specification through `Mutator.seeds`

AFL++'s custom mutator API is more permissive (accepts arbitrary byte arrays, supports C/Python/Rust) because it targets binary fuzzing where structure is unknown. PropertyTestingKit's approach is actually more sophisticated for type-aware fuzzing. No significant changes needed, though MOPT-style effectiveness tracking (Recommendation 1 in the MOPT summary) would enhance the existing mutator system.

**7. Dictionary Generation** (Already Implemented)

PropertyTestingKit already implements automatic dictionary generation through `FuzzEngine`'s string capture mechanism. The implementation is similar in spirit to AFL++'s approach: capture interesting string literals at runtime and use them for mutations. The difference is PropertyTestingKit captures strings dynamically during test execution rather than at compile time, which may be more flexible for Swift's dynamic string handling.

**8. Persistent Mode** (Not Applicable)

AFL++'s persistent mode optimization keeps the target process alive across test cases to avoid fork/exec overhead. This doesn't apply to PropertyTestingKit because Swift Testing already manages test isolation efficiently, and PropertyTestingKit runs within the testing framework's process rather than repeatedly launching external binaries. The overhead model is completely different.

**9. InsTrim Selective Instrumentation** (Not Applicable)

InsTrim allows selective instrumentation of code regions. PropertyTestingKit uses Swift's built-in SanitizerCoverage which instruments at module granularity. While selective instrumentation could theoretically reduce overhead, Swift Testing's typical use cases (unit tests, integration tests) have much smaller code surfaces than the large binaries AFL targets. The complexity of implementing selective instrumentation likely exceeds the benefit.

**10. QEMU Mode** (Not Applicable)

QEMU mode enables fuzzing binaries without source code. PropertyTestingKit requires Swift source code and operates through the Swift Testing framework, so this doesn't apply.

---

## Concrete Recommendations

### Recommendation 1: Implement MOPT-Style Adaptive Mutation Scheduling

**Priority:** High
**Effort:** Medium
**Impact:** Potentially significant improvement in fuzzing efficiency

PropertyTestingKit should implement effectiveness tracking for mutation strategies and use weighted selection during the fuzzing loop. See the detailed implementation recommendations in the [MOPT research summary](lyu-2019-mopt.md), particularly:

- Recommendation 1: Add mutation strategy effectiveness tracking
- Recommendation 2: Implement adaptive mutation strategy selection with three-phase pipeline
- Recommendation 3: Track per-mutator effectiveness in `ComposedMutator`
- Recommendation 5: Add pacemaker mode to prevent premature convergence

**Key Implementation Points:**

1. Add a `MutationStrategyTracker` to `FuzzEngine` that records which strategies discover new coverage
2. Implement pilot phase (uniform selection), core phase (weighted selection), and pacemaker mode (periodic uniform)
3. Extend `ComposedMutator` to track per-sub-mutator effectiveness
4. Add configuration options: `enableAdaptiveMutation`, `pilotPhaseIterations`, `mutationExplorationFactor`

**Expected Benefits:**

- Faster coverage discovery by focusing on effective mutation strategies
- Automatic adaptation to target characteristics without manual tuning
- Better resource utilization within PropertyTestingKit's smaller iteration budgets

### Recommendation 2: Implement Multiple Power Schedules

**Priority:** Medium
**Effort:** Medium
**Impact:** Moderate improvement, especially for parallel fuzzing

Extend PropertyTestingKit's corpus selection strategy beyond the current rarity-based approach by implementing multiple power schedules inspired by AFLfast++.

**Implementation:**

```swift
// Add to FuzzEngine.Config
public enum PowerSchedule: Sendable {
    case explore   // Balanced between exploitation and exploration (current behavior)
    case fast      // Favor rarely-hit paths (exploit rarity more aggressively)
    case exploit   // Favor high-coverage seeds (best for main instance)
    case rare      // Favor extremely rare edges
    case uniform   // Uniform random selection (baseline)
}

public struct Config: Sendable {
    // ... existing fields ...

    /// Power schedule for corpus entry selection
    public var powerSchedule: PowerSchedule

    public init(
        // ... existing parameters ...
        powerSchedule: PowerSchedule = .explore
    ) {
        // ... existing assignments ...
        self.powerSchedule = powerSchedule
    }
}
```

Modify `Corpus.selectForMutation()` to implement different selection strategies based on the configured schedule. The current implementation favors rare coverage, which roughly corresponds to AFLfast++'s "fast" schedule. Add alternatives:

- `explore`: Balanced mix of exploitation (high coverage) and exploration (rarity)
- `fast`: Current behavior (favor rare coverage)
- `exploit`: Favor entries that found the most total coverage
- `rare`: Extremely favor entries with unique coverage (higher exponent on rarity factor)
- `uniform`: Equal probability for all entries (useful for baseline comparison)

**Parallel Fuzzing Enhancement:**

If/when PropertyTestingKit supports parallel fuzzing with shared corpus, follow AFL++'s recommendation: assign different schedules to different instances (e.g., main instance with `exploit`, secondaries with mix of `fast` and `explore`).

### Recommendation 3: Investigate Switch Statement Coverage

**Priority:** Low
**Effort:** Low (investigation), potentially Medium (if fix needed)
**Impact:** Unknown (depends on investigation results)

Investigate whether Swift's compiled switch statements provide per-case coverage feedback through SanitizerCoverage. If not, this represents a coverage blind spot where the fuzzer can't distinguish between different switch cases.

**Investigation Steps:**

1. Create a test program with a large switch statement
2. Compile with `-sanitize-coverage=trace-pc-guard`
3. Run inputs that hit different switch cases
4. Check if coverage signatures differ per case

**If Coverage Is Per-Case:** No action needed, Swift already provides the needed feedback.

**If Coverage Is Per-Switch:** Consider:
- Filing a Swift compiler issue to request per-case coverage instrumentation
- Documenting the limitation for users
- Potentially implementing a source transformation (like laf-intel) that rewrites switches to if-else chains during test compilation (though this is complex and may not be worth it)

### Recommendation 4: Enhance Value Profile with Parameter-Level Tracking

**Priority:** Low
**Effort:** High
**Impact:** Moderate improvement for multi-parameter tests

Extend PropertyTestingKit's value profile guidance to track which parameter in a multi-parameter test contributed to which comparison, enabling more targeted mutations. This is inspired by Redqueen's input-to-state correspondence but adapted for Swift's structured types.

**Current Behavior:**

When `test(username: String, password: String, age: Int)` executes comparison operations, the value profile captures the operands but doesn't track which parameter was involved. When selecting a mutation target, all parameters are equally likely to be mutated.

**Enhanced Behavior:**

Track parameter-level correspondence: if a comparison involved the `password` parameter, increase the mutation probability for that specific parameter. This is less complex than byte-level taint tracking but provides meaningful guidance for structured inputs.

**Implementation Sketch:**

```swift
// Extend ValueProfileTracker to associate comparisons with parameter indices
private struct ParameterAwareValueProfile {
    // Map: comparison site → parameter index that influenced it
    var comparisonSources: [UInt64: Int] = [:]

    // During test execution, track active parameter
    var currentParameterIndex: Int?

    func recommendMutationTarget(
        parameterCount: Int,
        recentComparisons: [UInt64]
    ) -> Int? {
        // Return parameter index most frequently involved in recent comparisons
        let involvedParameters = recentComparisons.compactMap { comparisonSources[$0] }
        guard !involvedParameters.isEmpty else { return nil }

        // Return most common parameter index
        let counts = Dictionary(involvedParameters.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
```

This would require cooperation from the test execution infrastructure to track which parameter is currently being used (potentially through dynamic scoping or call stack analysis). Given the implementation complexity and Swift's lack of built-in taint tracking, this is a low-priority enhancement.

### Recommendation 5: Add Power Schedule and Strategy Telemetry

**Priority:** Low
**Effort:** Low
**Impact:** Improves observability and debugging

If Recommendations 1 and 2 are implemented, add telemetry to track and report:

- Per-strategy coverage discovery rates
- Power schedule effectiveness
- Mutation operator success rates
- Time spent in pilot vs core vs pacemaker phases

**Implementation:**

```swift
public struct FuzzStats: Sendable {
    // ... existing fields ...

    /// Breakdown of coverage discoveries by mutation strategy
    public let coverageByStrategy: [String: Int]

    /// Mutation strategy success rates (coverage discoveries / attempts)
    public let strategySuccessRates: [String: Double]

    /// Power schedule used
    public let powerSchedule: String

    /// Time spent in different MOPT phases
    public let pilotPhaseIterations: Int
    public let corePhaseIterations: Int
    public let pacemakerIterations: Int
}
```

This enables users to understand what's working for their specific targets and make informed decisions about configuration tuning.

---

## Implementation Priority

**Immediate Value:**
1. **Recommendation 1**: MOPT adaptive mutation scheduling - directly improves fuzzing efficiency with measurable impact

**Incremental Improvements:**
2. **Recommendation 2**: Multiple power schedules - provides flexibility and improves parallel fuzzing when implemented
3. **Recommendation 5**: Telemetry - improves observability and helps validate Recommendations 1 and 2

**Nice to Have:**
4. **Recommendation 3**: Switch statement investigation - may reveal no issue, or may be complex to address
5. **Recommendation 4**: Parameter-level tracking - high complexity, uncertain benefit

---

## Key Takeaways from AFL++ for PropertyTestingKit

1. **Target-Dependent Techniques**: AFL++'s evaluation demonstrates that no single fuzzing technique universally improves performance. PropertyTestingKit should embrace this by making features configurable and providing guidance on what works for different target characteristics (e.g., integer-heavy vs. string-heavy, simple vs. complex types).

2. **Combination is Powerful**: AFL++'s success comes from *combining* multiple techniques and allowing them to work together (or be disabled when they conflict). PropertyTestingKit already follows this philosophy with composable mutators and optional features like value profiling. Continue this approach.

3. **Adaptive is Better than Fixed**: Both MOPT (adaptive mutation scheduling) and AFLfast++ (adaptive power schedules) demonstrate benefits of learning what works during a fuzzing campaign rather than using fixed strategies. This is PropertyTestingKit's highest-value takeaway.

4. **Developer Experience Matters**: AFL++'s custom mutator API and extensive documentation make it accessible to security researchers without deep fuzzing expertise. PropertyTestingKit should maintain its focus on Swift-idiomatic APIs, clear documentation, and sensible defaults while allowing expert tuning.

5. **Research Infrastructure**: AFL++ aims to be a platform for fuzzing research. While PropertyTestingKit's primary goal is practical property testing for Swift developers, incorporating research-validated techniques (MOPT, AFLfast, value profiling) positions it as a serious fuzzing tool rather than just a testing utility.

---

## Differences from PropertyTestingKit's Context

1. **Binary vs. Framework Fuzzing**: AFL++ fuzzes standalone binaries through repeated execution and coverage observation. PropertyTestingKit fuzzes Swift functions through the Swift Testing framework. This means PropertyTestingKit has natural access to type information, structured inputs, and Swift's runtime, while AFL++ must infer structure from binary behavior.

2. **Iteration Budget**: AFL++ runs for millions of iterations over hours or days to find security vulnerabilities. PropertyTestingKit defaults to 10,000 iterations as part of a test suite that should complete in reasonable time. This affects which techniques are worth the overhead.

3. **Coverage Granularity**: AFL++ tracks edge coverage in compiled binaries. PropertyTestingKit tracks the same through SanitizerCoverage but operates at Swift function granularity. This means PropertyTestingKit's coverage map is typically much smaller and less collision-prone.

4. **Goal Differences**: AFL++ primarily targets security vulnerability discovery in existing software. PropertyTestingKit targets property verification during development. This means PropertyTestingKit users are more likely to fix issues immediately rather than triage crashes, and they care about test suite performance.

5. **Type Safety**: PropertyTestingKit's `Mutator` protocol and `Fuzzable` conformances leverage Swift's type system to ensure mutations produce valid inputs. AFL++ operates on raw bytes and relies on the target program's input parsing to reject invalid inputs. This makes PropertyTestingKit's mutations inherently more efficient (higher percentage of generated inputs are valid) but less exploratory (can't easily escape type constraints to test error handling).

---

## References

- Fioraldi et al., "AFL++: Combining Incremental Steps of Fuzzing Research", USENIX WOOT 2020
- AFL++ GitHub: https://github.com/AFLplusplus/AFLplusplus
- AFL++ Official Site: https://aflplus.plus/
- USENIX Presentation: https://www.usenix.org/conference/woot20/presentation/fioraldi
- LAF-Intel Blog: https://lafintel.wordpress.com/
- Redqueen Paper: Aschermann et al., "REDQUEEN: Fuzzing with Input-to-State Correspondence", NDSS 2019
- MOPT Paper: Lyu et al., "MOPT: Optimized Mutation Scheduling for Fuzzers", USENIX Security 2019
- AFLfast Paper: Böhme et al., "Coverage-based Greybox Fuzzing as Markov Chain", CCS 2016

---

## Sources

- [AFL++: Combining Incremental Steps of Fuzzing Research (USENIX)](https://www.usenix.org/conference/woot20/presentation/fioraldi)
- [AFL++ Paper PDF](https://www.usenix.org/system/files/woot20-paper-fioraldi.pdf)
- [AFL++ GitHub Repository](https://github.com/AFLplusplus/AFLplusplus)
- [AFL++ Official Website](https://aflplus.plus/)
- [AFL++ Custom Mutators Documentation](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/custom_mutators.md)
- [AFL++ Power Schedules Documentation](https://aflplus.plus/docs/power_schedules/)
- [AFL++ LTO Instrumentation](https://github.com/AFLplusplus/AFLplusplus/blob/stable/instrumentation/README.lto.md)
- [LAF-Intel: Circumventing Fuzzing Roadblocks with Compiler Transformations](https://lafintel.wordpress.com/)
- [AFL++ LAF-Intel Documentation](https://github.com/AFLplusplus/AFLplusplus/blob/stable/instrumentation/README.laf-intel.md)
- [REDQUEEN: Fuzzing with Input-to-State Correspondence](https://www.ndss-symposium.org/ndss-paper/redqueen-fuzzing-with-input-to-state-correspondence/)
- [AFL++ Fuzzing Approach Documentation](https://github.com/AFLplusplus/AFLplusplus/blob/stable/docs/afl-fuzz_approach.md)
- [AFL++ Technical Details](https://aflplus.plus/docs/technical_details/)
