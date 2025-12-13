# Ideas from Prior Art

Techniques from research that could improve PropertyTestingKit, organized by priority and effort.

## High Priority / High Impact

### 1. Internal Shrinking (Hypothesis)
**Source:** MacIver & Donaldson, ECOOP 2020

**Current state:** No shrinking - when tests fail, we report the raw failing input.

**Technique:** Instead of shrinking values directly, shrink the "choice sequence" that generated them:
- Record all random choices made during input generation
- On failure, use delta debugging to find minimal choice sequence that still fails
- Replay reduced choices through generators to get minimal failing input

**Benefits:**
- Automatically produces minimal counterexamples
- Works with any generator without custom shrinker code
- Shrinking "just works" for composed types

**Effort:** High - requires rearchitecting generation to use choice sequences

---

### 2. Energy-Based Mutation Scheduling (AFL/FuzzChick)
**Source:** AFL, FuzzChick OOPSLA 2019

**Current state:** Basic rarity-based selection in `selectForMutation()` - entries covering rare indices get higher priority.

**Improvements:**
- **Recency bonus:** Recently-discovered entries may lead to more discoveries
- **Mutation depth:** Track how many mutations deep from seeds; prefer shallower
- **Discovery rate:** Boost entries whose mutations frequently find new coverage
- **Havoc mode:** Periodically do aggressive multi-mutations to escape local optima

**Effort:** Medium - extend existing `selectForMutation()` and track more metadata

---

### 3. Value Profile Guidance (libFuzzer)
**Source:** libFuzzer `-use_value_profile=1`

**Current state:** Only branch coverage feedback.

**Technique:** Track comparison operand values, not just branches taken:
- When code executes `if (x == MAGIC)`, track how close `x` is to `MAGIC`
- Mutate inputs that get "closer" to satisfying comparisons
- Use hamming distance for strings, arithmetic distance for numbers

**Benefits:** Helps crack "magic number" checks that branch coverage alone can't guide toward.

**Effort:** High - requires compiler instrumentation we may not have access to. Could approximate with Swift runtime introspection.

---

### 4. Corpus Distillation (MoonLight)
**Source:** Herrera et al., 2019

**Current state:** Greedy set-cover minimization in `Corpus.minimized()`.

**Improvements:**
- **Weighted minimization:** Prefer smaller/simpler inputs when coverage is equal
- **Dynamic programming:** MoonLight's approach finds better minimal sets
- **Incremental distillation:** Distill periodically during fuzzing, not just at end

**Effort:** Medium - improve existing `minimized()` algorithm

---

## Medium Priority

### 5. Structured Mutation Awareness (Zest/JQF)
**Source:** Padhye et al., ISSTA 2019

**Current state:** Mutations are structure-aware (via `Mutator` protocol) but don't track validity.

**Technique:**
- Track which mutations produce valid vs invalid inputs
- Boost mutation strategies that maintain validity
- Learn which parts of input are "structural" vs "payload"

**Benefits:** Spend more time on semantically meaningful mutations.

**Effort:** Medium - add validity tracking to mutation feedback loop

---

### 6. Targeted Branch Mutations (FairFuzz)
**Source:** Lemieux & Sen, ASE 2018

**Current state:** No targeting - mutations are applied uniformly.

**Technique:**
- Identify "rare branches" (branches hit by few corpus entries)
- When mutating, prefer mutations that might hit rare branches
- Track which input components affect which branches

**Benefits:** Faster coverage of hard-to-reach code paths.

**Effort:** High - requires branch-to-input correlation analysis

---

### 7. User-Defined Labels/Metrics (HypoFuzz)
**Source:** HypoFuzz features

**Current state:** Only coverage signatures guide fuzzing.

**Technique:** Let users provide additional feedback:
```swift
try fuzz { input in
    let result = process(input)
    fuzzEvent("processed-\(result.type)")  // Custom coverage buckets
    fuzzTarget(result.complexity)           // Maximize this metric
}
```

**Benefits:** Domain knowledge can guide fuzzer toward interesting states.

**Effort:** Low-Medium - add event/target APIs that feed into coverage signature

---

### 8. Parallel Fuzzing (QuickerCheck)
**Source:** QuickerCheck 2024

**Current state:** Single-threaded fuzzing.

**Technique:**
- Run multiple fuzzing workers in parallel
- Share corpus discoveries via synchronized database
- Partition seed space across workers

**Benefits:** Linear speedup on multi-core machines.

**Effort:** Medium - need thread-safe corpus, but our coverage counters are global (process-wide).

**Caveat:** LLVM coverage counters are per-process, so true parallelism requires multi-process architecture.

---

## Lower Priority / Research Ideas

### 9. Mutation Testing Feedback (Mu2)
**Source:** ISSTA 2023

**Technique:** Use mutation scores (how many code mutants an input kills) as feedback instead of just coverage.

**Benefits:** Better fault detection, not just coverage.

**Effort:** Very High - requires code mutation infrastructure.

---

### 10. LLM-Guided Mutation
**Source:** CovRL-Fuzz, various 2024 papers

**Technique:** Use LLMs to suggest semantically meaningful mutations based on code context.

**Effort:** High, experimental.

---

### 11. Data Coverage (USENIX Security 2024)
**Source:** Wang et al.

**Technique:** Track data values flowing through the program, not just control flow.

**Benefits:** Finds bugs that require specific data patterns.

**Effort:** Very High - requires data flow instrumentation.

---

## Quick Wins

### A. Configurable Stopping Heuristics
**Current:** Fixed plateau threshold (1000 iterations without new coverage).

**Improvement:**
- Adaptive plateau based on corpus size
- Coverage velocity tracking (slow down = likely plateau)
- User-configurable stopping conditions

**Effort:** Low

---

### B. Better Mutation Diversity
**Current:** Each mutation mutates one component at a time.

**Improvement:**
- Multi-component mutations (mutate 2+ components together)
- Crossover between corpus entries
- Splice mutations (combine parts of different inputs)

**Effort:** Low-Medium

---

### C. Input Size Biasing
**Current:** No size preference.

**Improvement:**
- Bias toward smaller inputs (faster execution, easier debugging)
- Track input "size" in corpus metadata
- Prefer smaller inputs when coverage is equal

**Effort:** Low

---

### D. Execution Time Tracking
**Current:** No per-input timing.

**Improvement:**
- Track execution time per corpus entry
- Deprioritize slow inputs for mutation
- Warn about inputs that timeout

**Effort:** Low

---

## Summary: Recommended Roadmap

### Phase 1: Quick Wins
- [ ] Input size biasing in corpus selection
- [ ] Multi-component mutations
- [ ] Execution time tracking
- [ ] Adaptive stopping heuristics

### Phase 2: Core Improvements
- [ ] Enhanced energy-based scheduling (recency, depth, discovery rate)
- [ ] Weighted corpus distillation
- [ ] User-defined events/metrics API

### Phase 3: Major Features
- [ ] Internal shrinking (Hypothesis-style)
- [ ] Parallel fuzzing (multi-process)
- [ ] Validity-aware mutations

### Phase 4: Advanced Research
- [ ] Value profile guidance (if feasible with Swift)
- [ ] Targeted branch mutations
- [ ] Data coverage
