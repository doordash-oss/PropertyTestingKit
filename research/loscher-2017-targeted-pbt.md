# Targeted Property-Based Testing

**Paper:** "Targeted property-based testing" (2017)
**Authors:** Andreas Löscher, Konstantinos Sagonas (Uppsala University, Sweden)
**Published:** ISSTA'17 - Proceedings of the 26th ACM SIGSOFT International Symposium on Software Testing and Analysis, Santa Barbara, CA, USA, July 2017
**Source:** https://proper-testing.github.io/papers/issta2017.pdf

## Paper Summary

Targeted Property-Based Testing (TPBT) addresses a fundamental limitation of traditional property-based testing frameworks like QuickCheck: the reliance on purely random input generation. While random generation is simple and often effective, it struggles with properties that depend on rare input characteristics or specific input patterns. For example, when testing network protocols with complex topologies, random generation may produce mostly simple configurations and miss edge cases involving high-energy consumption states or unusual network arrangements. Similarly, when testing security properties like noninterference, random inputs rarely exercise the specific program paths that could violate the property.

The core insight of TPBT is to transform property-based testing into a search-guided optimization problem. Instead of generating independent random inputs, TPBT uses a search strategy - specifically simulated annealing by default - to guide input generation toward inputs that are "interesting" with respect to the property being tested. The approach introduces three key components: (1) a utility function that measures how close an input comes to violating the property (even if it doesn't actually violate it), (2) a neighborhood function that generates inputs similar to a given input, and (3) a search strategy (simulated annealing) that uses the utility values to decide which inputs to explore further. The search strategy can accept worse utility values with some probability, allowing it to escape local optima and explore the input space more systematically than greedy approaches.

The authors implemented TPBT in an extension to PropEr (a property-based testing tool for Erlang) and demonstrated its effectiveness through three case studies: generating sensor network topologies with high energy consumption, creating routing trees for directional antenna networks optimized for different energy metrics, and testing noninterference properties of information-flow control abstract machines. In each case, TPBT found property violations or achieved optimization goals that random testing could not reach within reasonable time bounds. The approach combines the expressiveness and ease-of-use of property-based testing with the systematic exploration power of search-based testing, making it particularly valuable for properties involving optimization objectives or rare failure conditions.

## Key Strategies/Techniques

1. **Utility-Guided Input Generation**: Rather than just reporting pass/fail, tests compute utility values that quantify how close an input comes to violating the property. These utility values guide the search toward interesting regions of the input space. For example, when testing a pathfinding property, the utility might measure the distance between the actual exit position and the position reached by the algorithm.

2. **Simulated Annealing Search Strategy**: TPBT uses simulated annealing as its default search algorithm. SA maintains a current best input and explores the neighborhood by accepting better inputs (higher/lower utility based on maximization/minimization goal) and occasionally accepting worse inputs with a probability that decreases over time (controlled by a temperature function). This prevents getting stuck in local optima and enables more thorough exploration.

3. **Neighborhood Functions**: A neighborhood function takes an existing input and generates a similar input (a "neighbor"). For structured inputs like paths or trees, the neighborhood function might add a few steps, modify a subtree, or make small changes. The quality of the neighborhood function is critical - it must balance making meaningful changes while maintaining similarity to enable gradual refinement. PropEr can automatically construct neighborhood functions from random generators, reducing the manual effort required.

4. **User-Directed Search with MAXIMIZE/MINIMIZE**: Test authors specify whether to maximize or minimize utility values using directives like `?MAXIMIZE(UV)` or `?MINIMIZE(UV)`. This gives explicit control over search direction without requiring deep knowledge of search algorithms.

5. **Reset Mechanisms**: TPBT includes mechanisms to restart search when stuck in unproductive regions. For example, the `proper_sa:reset()` function can be called when inputs exceed certain thresholds (e.g., path length too long), discarding accumulated search state and starting fresh. This prevents wasting search budget on unpromising directions.

6. **Search Steps Configuration**: TPBT introduces a `search_steps` parameter (default: 1000) that controls how many search iterations to perform. This is independent of the `numtests` parameter used in random testing, allowing fine-grained control over the exploration budget.

7. **Automatic Component Construction**: A follow-up paper (ICST 2018) extended TPBT to automatically construct neighborhood functions from random generators, making TPBT "almost as easy as random testing" by removing the need to manually specify how to generate similar inputs.

## Applicability to PropertyTestingKit

### Alignment with Current Architecture

PropertyTestingKit shares some conceptual similarities with TPBT, but fundamentally uses a different approach to guided testing:

1. **Feedback-Guided Testing Philosophy**: Both TPBT and PropertyTestingKit use execution feedback to guide input generation, moving beyond pure randomness. However, they use different types of feedback:
   - TPBT uses explicit utility values computed by the test author
   - PropertyTestingKit uses coverage information (code paths executed) and value profiles (comparison operand distances) computed automatically by instrumentation

2. **Value Profile as Implicit Utility**: PropertyTestingKit's value profile guidance (tracking distances in comparisons like `a < b` or `a == X`) is conceptually similar to TPBT's utility values. Both measure "how close" an input is to achieving some goal. However, PropertyTestingKit's approach is automatic (no user annotation required) but less expressive (only tracks comparisons, not arbitrary metrics).

3. **Corpus-Based Iteration**: PropertyTestingKit maintains a corpus of interesting inputs and mutates them to generate new inputs, which is similar to how TPBT's neighborhood functions work. Both approaches build on previous successful inputs rather than generating from scratch each time.

4. **Multiple Mutation Strategies**: PropertyTestingKit's various mutation strategies (bit flips, arithmetic operations, dictionary substitutions) serve a similar role to TPBT's neighborhood functions - they define how to explore "nearby" inputs.

### Key Differences

Despite these similarities, there are fundamental differences in approach:

1. **Coverage vs. Utility**: PropertyTestingKit is coverage-guided (maximize code paths explored), while TPBT is utility-guided (optimize a user-defined metric). Coverage is a general-purpose metric that works for any code without modification. Utility functions are property-specific and must be manually defined.

2. **Search Strategy**: PropertyTestingKit uses evolutionary fuzzing strategies (corpus management, energy allocation, mutation selection) similar to AFL. TPBT uses simulated annealing with explicit temperature schedules and acceptance probabilities. These represent different meta-heuristics from the search-based software engineering literature.

3. **Automatic vs. Manual Instrumentation**: PropertyTestingKit relies on compiler instrumentation to automatically compute guidance signals. TPBT requires test authors to explicitly instrument their properties with utility computations.

4. **Generality**: PropertyTestingKit targets general-purpose bug finding (crashes, assertion failures, unexpected behaviors). TPBT targets optimization-oriented properties where you can measure "degrees of failure" even for inputs that don't violate the property yet.

5. **Integration Point**: PropertyTestingKit integrates at the compiler level (Swift compiler instrumentation). TPBT integrates at the test framework level (property macro extensions in PropEr).

### Challenges for Direct Adoption

Several challenges limit directly applying TPBT techniques to PropertyTestingKit:

1. **Manual Effort Requirement**: TPBT requires test authors to compute and report utility values for each test input. This is more work than PropertyTestingKit's zero-annotation approach. Many users want fuzzing to "just work" without thinking about utility functions.

2. **Optimization vs. Bug Finding Mismatch**: TPBT excels at optimization-oriented properties ("find a network topology with maximum energy consumption") but PropertyTestingKit focuses on bug finding ("find any input that crashes"). These are related but distinct goals. For simple crash finding, coverage may be more effective than custom utilities.

3. **Swift Testing Integration**: PropertyTestingKit integrates with Swift Testing's `@Test` functions which expect simple pass/fail results. Adding utility value reporting would require framework modifications.

4. **Temperature Schedule Tuning**: Simulated annealing requires tuning temperature functions for good performance. PropertyTestingKit's current approach (energy-based corpus selection with mutation strategies) is more parameter-free and works reasonably well across diverse targets.

5. **Local Search vs. Global Corpus**: TPBT's simulated annealing maintains a single "current input" and explores its neighborhood. PropertyTestingKit maintains a global corpus of many interesting inputs and explores all of them. These represent different exploration strategies with different trade-offs.

6. **Automatic Neighborhood Construction**: While PropEr can auto-generate neighborhood functions from generators, PropertyTestingKit doesn't have explicit generators - it works with raw bytes and type-aware mutations. The abstraction levels don't align directly.

### Applicable Concepts

Despite these differences, several TPBT concepts could enhance PropertyTestingKit:

1. **Value Profile as Utility Generalization**: PropertyTestingKit already tracks comparison distances (value profiles), which is a form of automatic utility. This could be extended to:
   - Track not just comparisons but also other interesting operations (divisions by near-zero values, array accesses near boundaries, etc.)
   - Prioritize inputs that make progress on multiple value profile targets simultaneously
   - Use value profile distance as an explicit "utility" metric for corpus prioritization

2. **Simulated Annealing for Value Profile Solving**: When PropertyTestingKit detects a value profile target (e.g., trying to make `x == 12345`), it could use simulated annealing to systematically explore values near the current distance rather than random mutations. This would be especially effective for solving multi-step constraints.

3. **Adaptive Temperature Schedules**: PropertyTestingKit's energy mechanism could incorporate temperature-like decay. New corpus entries could start with high "temperature" (allowing diverse mutations) and cool over time (focusing on refinement). This balances exploration and exploitation more explicitly.

4. **User-Defined Utility Functions (Opt-In)**: Add an optional API for power users to provide custom utility functions for specific tests. For example:
   ```swift
   @Test
   func testNetworkEnergy() async {
       await fuzz(utilityHint: { topology in
           topology.calculateEnergyConsumption()
       }) { topology in
           #expect(topology.isValid())
       }
   }
   ```
   When provided, the fuzzer could prioritize inputs with extreme utility values, combining coverage guidance with custom optimization.

5. **Reset Heuristics**: PropertyTestingKit could implement TPBT-style reset mechanisms to detect when fuzzing is stuck in unproductive regions and restart with fresh corpus entries or different mutation strategies.

6. **Neighborhood-Aware Mutation Selection**: Instead of uniformly selecting mutation strategies, PropertyTestingKit could adaptively select strategies based on which ones historically produce "nearby" inputs that make progress. This is similar to TPBT's neighborhood function quality concept.

7. **Multi-Objective Optimization**: TPBT optimizes a single utility function, but PropertyTestingKit already balances multiple objectives (coverage, value profiles, corpus diversity). Making this multi-objective optimization more explicit could improve prioritization. For example, use Pareto frontiers to identify corpus entries that are non-dominated across multiple metrics.

## Concrete Recommendations

### Short-Term (High Value, Low Complexity)

1. **Value Profile Distance-Based Prioritization** (2-3 days)
   - Enhance corpus entry selection to prioritize entries that are "close" to solving value profile targets
   - Currently PropertyTestingKit tracks value profiles but doesn't explicitly use distance for prioritization
   - Add a "minimum distance to target" metric to corpus entries and weight energy allocation accordingly
   - **File to modify**: `FuzzEngine.swift` (corpus selection logic), `ValueProfile.swift` (add distance tracking)
   - **Expected benefit**: 15-25% improvement in solving comparison-heavy constraints (e.g., magic number checks, hash validation)

2. **Simulated Annealing for Value Profile Solving** (3-5 days)
   - When a value profile target is detected, enter a focused SA mode for a limited number of iterations
   - Use comparison distance as utility, implement simple temperature schedule (linear or exponential decay)
   - Generate neighbor inputs by mutating the bytes involved in the comparison
   - **New file**: `Sources/PropertyTestingKit/Fuzzing/SimulatedAnnealingSolver.swift`
   - **Integration point**: `FuzzEngine.swift` lines where value profile targets are processed
   - **Expected benefit**: Dramatically faster solving of exact-value constraints (e.g., `x == 0x12345678`) that currently rely on random mutation luck

3. **Corpus Entry Temperature Decay** (2-3 days)
   - Add a "temperature" field to corpus entries that decays over time
   - High temperature = prefer diverse mutations (random bit flips, large changes)
   - Low temperature = prefer refinement mutations (single bit flips, small arithmetic changes)
   - This balances exploration (new corpus entries) with exploitation (mature entries)
   - **File to modify**: `Corpus.swift` (add temperature field), `FuzzEngine.swift` (use temperature in mutation selection)
   - **Expected benefit**: Better balance between finding new coverage and exploiting known-interesting inputs

### Medium-Term (Significant Value, Moderate Complexity)

4. **Optional User-Defined Utility Hints** (1-2 weeks)
   - Add an optional `utilityHint` parameter to the `fuzz` function
   - When provided, track utility values alongside coverage and prioritize extreme values
   - Implementation:
     ```swift
     public func fuzz<each Input>(
         utilityHint: ((repeat each Input) -> Double)? = nil,
         _ test: (repeat each Input) async throws -> Void
     ) async
     ```
   - Store utility values in corpus entries, use as additional prioritization signal
   - **New files**: `Sources/PropertyTestingKit/Fuzzing/UtilityTracking.swift`
   - **Expected benefit**: Enables optimization-oriented fuzzing for power users while keeping zero-annotation default behavior

5. **Multi-Metric Pareto Optimization** (1-2 weeks)
   - Explicitly model corpus selection as multi-objective optimization
   - Track multiple metrics per corpus entry: coverage, value profile progress, utility (if provided), execution time
   - Use Pareto dominance to identify non-dominated entries
   - Allocate energy preferentially to Pareto-optimal entries
   - **File to modify**: `Corpus.swift` (add multi-metric tracking and Pareto computation)
   - **Expected benefit**: More principled corpus management, avoiding wasted fuzzing effort on dominated inputs

6. **Adaptive Mutation Strategy Selection with UCB** (1 week)
   - Track historical success rates of different mutation strategies (bit flip, arithmetic, dictionary, etc.)
   - Use Upper Confidence Bound (UCB1) algorithm to balance exploration vs. exploitation of strategies
   - This is lighter-weight than full SA but provides adaptive behavior similar to TPBT
   - **File to modify**: `FuzzEngine.swift` (mutation strategy selection logic)
   - **Expected benefit**: 10-20% improvement by focusing on effective strategies for each specific test target

### Long-Term (Research-Level, High Complexity)

7. **Full Simulated Annealing Mode** (3-4 weeks)
   - Implement a complete SA-based fuzzing mode as an alternative to evolutionary fuzzing
   - Allow test authors to choose between coverage-guided (current) and utility-guided (SA-based) modes
   - Include configurable temperature schedules, acceptance probability functions, and neighborhood definitions
   - **New files**: `Sources/PropertyTestingKit/Fuzzing/SimulatedAnnealingEngine.swift`
   - **API changes**: Add mode selection to fuzzing configuration
   - **Expected benefit**: Enables TPBT-style optimization testing for users who need it, while keeping coverage-guided as default

8. **Automatic Utility Function Inference** (4-6 weeks)
   - Analyze test code to automatically infer potential utility functions
   - For example, if the test contains `#expect(value < threshold)`, infer that `value` might be a good utility metric
   - Use program analysis (AST inspection) or dynamic analysis (trace values computed before assertions)
   - This would bridge the gap between PropertyTestingKit's zero-annotation approach and TPBT's explicit utilities
   - **Scope**: Significant research effort, potentially a master's thesis project
   - **Expected benefit**: Combines the best of both worlds - automatic instrumentation with optimization-oriented search

9. **Hybrid Coverage + Utility Guidance** (2-3 weeks)
   - Combine coverage-guided and utility-guided fuzzing in a single engine
   - Maintain two corpora: coverage corpus (standard) and utility corpus (extreme utility values)
   - Alternate between coverage-maximizing and utility-optimizing mutations
   - **Architecture change**: Extend corpus to support multiple selection criteria
   - **Expected benefit**: Handle both general bug finding and optimization-oriented properties in a unified framework

### Implementation Priority

**Immediate (Next Sprint):**
- Value Profile Distance-Based Prioritization (#1)
- Corpus Entry Temperature Decay (#3)

**Next Quarter:**
- Simulated Annealing for Value Profile Solving (#2)
- Adaptive Mutation Strategy Selection with UCB (#6)

**Future Research:**
- Optional User-Defined Utility Hints (#4)
- Hybrid Coverage + Utility Guidance (#9)

**Long-Term Vision:**
- Automatic Utility Function Inference (#8)

### Key Insights

The main value of TPBT for PropertyTestingKit is not wholesale replacement of the coverage-guided approach, but rather **augmentation with explicit optimization capabilities**:

1. **Coverage for discovery, utility for exploitation**: Use coverage to find interesting code regions, then use utility-guided SA to thoroughly explore those regions when value profile targets are detected.

2. **Automatic by default, explicit when needed**: Keep the zero-annotation coverage-guided approach as the default (matches user expectations for fuzzing), but provide utility hints as an opt-in power-user feature for optimization-oriented properties.

3. **Temperature as unifying metaphor**: PropertyTestingKit's energy mechanism and TPBT's temperature schedules serve similar purposes. Explicitly modeling corpus entry "temperature" could unify these concepts and provide more principled exploration/exploitation balance.

4. **Value profiles are automatic utilities**: PropertyTestingKit already has a form of automatic utility through value profile distance tracking. Treating these distances more explicitly as utility signals (as TPBT does) could improve solver effectiveness without requiring manual annotation.

The TPBT paper demonstrates that search-guided PBT can solve problems that random PBT cannot. PropertyTestingKit can incorporate this insight by enhancing its value profile solving with SA-based focused search, adding optional utility hints for power users, and using temperature-based decay to balance exploration and exploitation. This provides TPBT-like capabilities while maintaining the library's core strengths: zero-annotation fuzzing, Swift Testing integration, and coverage-guided bug finding.

## Sources

- [Targeted property-based testing - ACM Digital Library](https://dl.acm.org/doi/10.1145/3092703.3092711)
- [Targeted property-based testing - ResearchGate PDF](https://www.researchgate.net/publication/318377087_Targeted_property-based_testing)
- [Tutorial for targeted property-based testing - PropEr Documentation](https://proper-testing.github.io/tutorials/PropEr_testing_with_search_strategies.html)
- [Automating Targeted Property-Based Testing - ICST 2018](https://proper-testing.github.io/papers/icst2018.pdf)
- [Support 'targeted PBT' for generating examples - Hypothesis Issue #1779](https://github.com/HypothesisWorks/hypothesis/issues/1779)
- [Coverage-Guided, Property Based Testing - FuzzChick Paper](https://lemonidas.github.io/pdf/FuzzChick.pdf)
- [Fuzzing vs property testing - Ted Kaminski Blog](https://www.tedinski.com/2018/12/11/fuzzing-and-property-testing.html)
