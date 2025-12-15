# On Measuring and Visualizing Fuzzer Performance

**Blog Post:** "On Measuring and Visualizing Fuzzer Performance" (August 2020)
**Author:** Cornelius Aschermann
**Source:** https://hexgolems.com/2020/08/on-measuring-and-visualizing-fuzzer-performance/

## Summary

This blog post by Cornelius Aschermann addresses critical gaps in how fuzzer effectiveness is evaluated and proposes novel sampling-based measurement approaches to improve assessment accuracy. Aschermann critiques the three primary existing evaluation methods—bug discovery, time-to-known-bug, and code coverage—highlighting their significant limitations. Bug discovery is valuable but coarse-grained and requires extensive manual triage. Time-to-known-bug is useful for validation but has limited applicability to research due to scarce datasets. Code coverage, while correlating with bug-finding ability, suffers from being binary (covered/uncovered) and often shows nearly identical results across different fuzzers in large-scale benchmarks like FuzzBench.

The core proposal is a sampling-based methodology that randomly samples test inputs during execution rather than analyzing only the final fuzzer queue. This approach provides minimal performance overhead while enabling detailed insights and unbiased comparisons across different fuzzer architectures (including those using symbolic execution or other non-random approaches). The key innovation is moving from binary "covered/uncovered" metrics to richer data: execution frequency analysis (how often basic blocks are hit across the campaign) and state coverage measurement (distinct paths reaching code locations, variable value diversity, path exploration diversity). This methodology addresses three of four key goals: providing fine-grained progress indicators, applicability to real-world targets, and enabling cross-fuzzer comparability.

Aschermann presents this as preliminary work and invites community feedback, acknowledging that one gap remains: measuring fuzzers that use advanced analytics like symbolic execution without random exploration. The post advocates for standardized evaluation practices that provide more nuanced, actionable insights than current binary coverage metrics, enabling researchers and practitioners to better understand fuzzer behavior and make meaningful comparisons between tools.

## Key Insights

1. **Limitations of Binary Coverage**: Traditional "covered/uncovered" metrics are too coarse for modern fuzzer evaluation. In large-scale benchmarks, most fuzzers achieve nearly identical code coverage despite having fundamentally different architectures and strategies.

2. **Execution Frequency Matters**: Instead of just tracking whether a basic block was ever executed, measuring how frequently blocks are executed throughout the fuzzing campaign reveals which fuzzers more thoroughly explore code paths and which might be hitting code regions rarely or by accident.

3. **Sampling-Based Measurement**: Random sampling of test inputs during execution provides detailed insights with minimal performance overhead. This avoids the bias inherent in analyzing only the final fuzzer queue, which may not represent the full exploration performed during the campaign.

4. **State Coverage Beyond Basic Blocks**: Effective fuzzer measurement should track:
   - Distinct execution paths reaching individual code locations
   - Diversity of variable values observed during fuzzing
   - Path exploration diversity (not just path existence)

5. **Unbiased Cross-Fuzzer Comparison**: Sampling enables fair comparison across different fuzzer architectures, including coverage-guided fuzzers, symbolic execution tools, and hybrid approaches, without favoring any particular implementation strategy.

6. **Fine-Grained Progress Indicators**: Rather than waiting for bug discovery or measuring only final coverage, sampling provides continuous, granular feedback about fuzzer progress throughout the campaign, enabling more responsive tuning and analysis.

7. **Real-World Target Applicability**: Unlike metrics that depend on known bugs or synthetic targets, sampling-based approaches work equally well on any program, making them suitable for evaluating fuzzers on real-world software where ground truth is unknown.

## Applicability to PropertyTestingKit

### Alignment with Current Architecture

PropertyTestingKit's architecture has several characteristics that make Aschermann's insights highly relevant:

1. **Coverage-Guided Foundation**: PropertyTestingKit already uses coverage signatures (based on AFL's bucketed counter approach) to guide fuzzing and maintain a corpus of interesting inputs. The infrastructure exists to capture execution frequency data, which Aschermann identifies as crucial.

2. **Bucketed Counter System**: The `CoverageSignature` implementation (in `/Sources/PropertyTestingKit/Fuzzing/CoverageSignature.swift`) already tracks execution frequency through AFL-style buckets (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+), which moves beyond binary coverage toward the execution frequency analysis Aschermann proposes.

3. **Corpus-Based Testing**: PropertyTestingKit maintains a corpus of interesting inputs during fuzzing, similar to AFL and libFuzzer. However, as Aschermann notes, analyzing only the final corpus can be misleading—it represents surviving inputs, not the full exploration performed.

4. **Statistics Tracking**: The `FuzzStats` structure (in `FuzzEngine.swift`) tracks basic metrics like total inputs, new paths, mutations, generations, and duration, but these are still coarse-grained measures that don't capture execution frequency or state diversity.

### Current Measurement Gaps

PropertyTestingKit's current metrics suffer from the same limitations Aschermann identifies:

1. **Binary Path Discovery**: The `newPaths` metric counts how many new coverage signatures were found, but doesn't distinguish between:
   - A path hit once by accident vs. explored repeatedly
   - A path that enables further exploration vs. a dead end
   - A path representing shallow vs. deep program state

2. **No Execution Frequency Visibility**: While the bucketed counters capture execution frequency per-input, PropertyTestingKit doesn't aggregate or visualize this across the entire campaign. Users can't see which code regions are thoroughly explored vs. barely touched.

3. **Limited Progress Indicators**: The current metrics show total inputs tested and paths discovered, but don't provide fine-grained insight into whether the fuzzer is making meaningful progress or has plateaued.

4. **No Cross-Run Comparison**: PropertyTestingKit lacks infrastructure for comparing fuzzer effectiveness across different runs, mutation strategies, or configuration changes in a principled way.

5. **Final Queue Bias**: Regression mode replays the final corpus, but doesn't capture inputs that contributed to exploration during fuzzing but didn't survive corpus minimization or energy allocation adjustments.

### Applicable Concepts

Several of Aschermann's proposals can directly improve PropertyTestingKit:

1. **Execution Frequency Aggregation**: Track and visualize how frequently each coverage counter was incremented across the entire fuzzing campaign, not just whether it was hit. This reveals which code regions are thoroughly exercised vs. barely reached.

2. **Sampling-Based Corpus Analysis**: Rather than only saving corpus entries that add new coverage, periodically sample inputs during fuzzing to capture the full exploration trajectory. This enables post-fuzzing analysis of:
   - Which strategies were exploring which regions
   - How execution frequency evolved over time
   - Whether the fuzzer got stuck in local optima

3. **State Coverage Metrics**: Extend beyond basic block coverage to measure:
   - Number of distinct value profile targets encountered
   - Diversity of comparison operand values seen
   - Path diversity within the same coverage signature

4. **Progress Visualization**: Instead of just "X inputs tested, Y paths found," track and display:
   - Coverage accumulation over time (cumulative curve)
   - Execution frequency heatmaps showing which regions are well-explored
   - Plateau detection (is the fuzzer still making progress?)

5. **Comparative Benchmarking**: Implement infrastructure for comparing multiple fuzzing runs on the same target, visualizing:
   - Which configuration achieved higher execution frequency in target regions
   - Which strategies discovered coverage faster
   - Which approaches more thoroughly explored discovered paths

## Concrete Recommendations

### Short-Term (High Value, Low Complexity)

1. **Execution Frequency Aggregation** (2-3 days)
   - Extend `FuzzStats` to track aggregate execution frequencies per counter index
   - During fuzzing, accumulate counter delta values (not just track "new coverage")
   - Report summary statistics: mean, median, max execution frequency per discovered region
   - **Files to modify**:
     - `FuzzEngine.swift`: Add frequency tracking to stats
     - `CoverageSignature.swift`: Add method to extract raw bucket values
   - **Expected benefit**: Users can distinguish between well-explored code regions (high frequency) and barely-touched regions (low frequency), guiding debugging and test improvement efforts

2. **Coverage Timeline Tracking** (2-3 days)
   - Record timestamps when new coverage is discovered during fuzzing
   - Output cumulative coverage curve (time/inputs vs. total paths discovered)
   - Detect plateaus (no new coverage for N seconds/inputs)
   - **Files to modify**: `FuzzEngine.swift` (add timeline tracking to fuzz loop)
   - **New files**: `Sources/PropertyTestingKit/Fuzzing/CoverageTimeline.swift`
   - **Expected benefit**: Identify when fuzzing has stopped being productive, enabling early termination or strategy adjustment; visualize fuzzing effectiveness over time

3. **Enhanced Statistics Output** (1-2 days)
   - Add per-counter execution frequency distribution to `FuzzStats`
   - Include "coverage depth" metric: average execution frequency across discovered paths
   - Report "exploration efficiency": new coverage per 1000 inputs
   - **Files to modify**: `FuzzEngine.swift`, `FuzzStats` definition
   - **Expected benefit**: More actionable metrics for comparing fuzzing runs and understanding campaign effectiveness

### Medium-Term (Significant Value, Moderate Complexity)

4. **Sampling-Based Input Logging** (1 week)
   - Implement periodic sampling of tested inputs (e.g., every 100th input) during fuzzing
   - Save samples with metadata: timestamp, coverage signature, execution frequencies, mutation strategy
   - Store in separate `samples/` directory alongside corpus
   - **New files**:
     - `Sources/PropertyTestingKit/Fuzzing/InputSampler.swift`
     - `Sources/PropertyTestingKit/Fuzzing/SampledInput.swift`
   - **Files to modify**: `FuzzEngine.swift` (integrate sampling)
   - **Expected benefit**: Post-campaign analysis of fuzzer behavior, understanding exploration patterns, debugging coverage plateaus

5. **Coverage Heatmap Generation** (1-2 weeks)
   - Analyze saved samples or final corpus to generate execution frequency heatmaps
   - Output JSON/CSV with per-counter aggregated frequencies
   - Provide script to visualize heatmaps (potentially integrate with coverage reports)
   - **New files**:
     - `Sources/PropertyTestingKit/Fuzzing/CoverageHeatmap.swift`
     - `scripts/visualize-coverage.py` (or Swift script)
   - **Expected benefit**: Visual understanding of which code regions are well-explored vs. under-explored, guiding test improvement and identifying fuzzer weaknesses

6. **Comparative Run Analysis** (1-2 weeks)
   - Infrastructure for running multiple fuzzing campaigns with different configurations
   - Compare runs on: coverage accumulation rate, execution frequency distributions, final coverage depth
   - Output comparative reports showing which configuration performed better and why
   - **New files**:
     - `Sources/PropertyTestingKit/Fuzzing/ComparativeAnalysis.swift`
     - `scripts/compare-fuzz-runs.swift`
   - **Expected benefit**: Evidence-based tuning of mutation strategies, energy allocation, and other fuzzing parameters; identify optimal configurations for different target characteristics

7. **State Coverage Metrics** (2-3 weeks)
   - Track distinct value profile comparison values seen (not just whether targets were hit)
   - Count unique paths reaching same coverage signature (use full stack traces or path hashes)
   - Measure "state diversity": how many distinct program states were explored
   - **Files to modify**:
     - `ValueProfile.swift`: Add tracking of distinct comparison operand values
     - `FuzzEngine.swift`: Integrate state diversity metrics
   - **Expected benefit**: Move beyond binary coverage to understand depth of exploration; identify when fuzzer is hitting same code in same way repeatedly (low state diversity) vs. exploring diverse behaviors (high state diversity)

### Long-Term (Research-Level, High Complexity)

8. **Real-Time Progress Visualization** (3-4 weeks)
   - Web-based dashboard showing live fuzzing progress
   - Display coverage accumulation curves, execution frequency heatmaps, plateau detection
   - Support comparing multiple concurrent fuzzing campaigns
   - **Scope**: Significant infrastructure (web server, real-time data streaming, visualization framework)
   - **Technologies**: Swift NIO for server, WebSocket for streaming, JavaScript visualization library
   - **Expected benefit**: Real-time insight into fuzzing effectiveness, enabling responsive tuning and early stopping when campaigns plateau

9. **Fuzzer Performance Database** (4-6 weeks)
   - Centralized database storing detailed metrics from all fuzzing runs
   - Track performance across targets, configurations, mutation strategies
   - Machine learning-based analysis to predict optimal configurations for new targets based on historical data
   - **New files**:
     - `Sources/PropertyTestingKit/Fuzzing/PerformanceDatabase.swift`
     - Schema for SQLite/PostgreSQL database
   - **Expected benefit**: Accumulate organizational knowledge about fuzzer effectiveness; automatically suggest optimal configurations for new targets; identify systematic strengths/weaknesses of different strategies

10. **Symbolic Coverage Integration** (6-8 weeks)
    - Extend state coverage metrics to track symbolic constraints solved (if symbolic execution is added)
    - Measure "constraint diversity": how many distinct path constraints were satisfied
    - Enable fair comparison between coverage-guided, symbolic, and hybrid approaches
    - **Scope**: Requires symbolic execution infrastructure (possibly Swift-STP integration)
    - **Expected benefit**: Principled comparison of different fuzzing paradigms; identify which approaches work best for different target characteristics

### Implementation Priority

**Immediate (Next Sprint):**
- Execution Frequency Aggregation (#1)
- Coverage Timeline Tracking (#2)
- Enhanced Statistics Output (#3)

These provide quick wins with minimal complexity, immediately improving the actionability of fuzzing metrics.

**Next Quarter:**
- Sampling-Based Input Logging (#4)
- Coverage Heatmap Generation (#5)
- State Coverage Metrics (#7)

These provide deeper insights into fuzzer behavior and enable more sophisticated analysis.

**Future Research:**
- Comparative Run Analysis (#6)
- Real-Time Progress Visualization (#8)
- Fuzzer Performance Database (#9)

These represent longer-term infrastructure investments that enable systematic fuzzer improvement and organizational learning.

## Conclusion

Aschermann's critique of binary coverage metrics and proposal for sampling-based, frequency-aware fuzzer measurement is highly applicable to PropertyTestingKit. The library already uses bucketed counters that capture execution frequency per-input, but lacks infrastructure for aggregating and analyzing this data across entire campaigns. Implementing execution frequency tracking, coverage timelines, and sampling-based logging would provide users with much richer insights into fuzzer effectiveness, moving beyond simple "paths discovered" counts to understanding how thoroughly code regions are explored.

The most impactful near-term improvements are:
1. **Aggregate and report execution frequency statistics** to distinguish well-explored vs. barely-touched code
2. **Track coverage accumulation over time** to detect plateaus and measure exploration efficiency
3. **Implement sampling-based logging** to enable post-campaign analysis of fuzzer behavior

These changes align with PropertyTestingKit's coverage-guided philosophy while addressing the measurement gaps Aschermann identifies. The result would be more actionable metrics, better debugging support, and principled comparison of fuzzing strategies—moving PropertyTestingKit from "did we find new coverage?" to "how effectively did we explore the program's state space?"
