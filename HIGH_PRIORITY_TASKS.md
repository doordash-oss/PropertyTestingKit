# High Priority Implementation Tasks

Based on research analysis from 40+ papers. These offer significant impact with reasonable implementation effort.

## Phase 1: Core Workflow Improvements

- [x] **5. Coverage Plateau Detection with Early Stopping** (1 week) - COMPLETED
  - Created `CoveragePlateauDetector.swift` with sliding window rate tracking
  - Track discovery rate over configurable window size
  - Exponential moving average for trend detection
  - Integrated into FuzzEngine with configurable `PlateauConfig`
  - Added `PlateauStats` to `FuzzStats` for visibility
  - Stop reason tracking (time_limit, coverage_plateau, legacy_plateau, etc.)

- [x] **8. Per-Execution Timeout / Hang Detection** (1 week) - COMPLETED
  - Added `perInputTimeout` config option (seconds)
  - Uses DispatchSemaphore for timeout detection
  - Hangs tracked separately from failures in `FuzzStats`
  - Added `hangs` count to statistics
  - Exposed in public API: `fuzz(perInputTimeout: 0.5) { ... }`

- [x] **7. Failure Preservation and Reporting** (1-2 weeks) - COMPLETED
  - Added `FailureInfo` struct to capture error details
  - Added `CorpusEntryType` enum (coverage, failure, hang, valueProfile)
  - Extended `CorpusEntry` with `entryType` and `failure` fields
  - Added `addFailure()` and `addHang()` methods to Corpus
  - Updated `minimized()` to preserve failure/hang entries
  - Added `generateRegressionTestCode()` and `generateAllRegressionTests()`
  - Backward compatible with existing corpus files

## Phase 2: Seed Selection & Scheduling

- [x] **1. Entropic Seed Selection (Shannon Entropy)** (2-3 weeks) - COMPLETED
  - Created `EntropicScheduler.swift` with Shannon entropy calculations
  - Tracks (index, bucket) pairs as features for fine-grained coverage
  - Global feature frequency tracking with saturating counters
  - Rare feature identification (frequency < abundance threshold)
  - Entropy-weighted seed selection for prioritizing rare features
  - Integrated into Corpus with `enableEntropic()` / `disableEntropic()`
  - Periodic entropy recomputation for efficiency

- [x] **6. Rare Branch Targeting (FairFuzz-Inspired)** (1-2 weeks) - COMPLETED
  - Created `RareBranchTracker.swift` with power-of-two threshold
  - Track hit counts per coverage index across corpus
  - Identify rare branches (hit count ≤ threshold)
  - Extended `Corpus.selectForMutation(preferring:probability:)`
  - Config options: `enableRareBranchTargeting`, `rareBranchSelectionProbability`
  - Verbose logging shows rare branch statistics

- [x] **3. Swarm Testing (Mutator Subset Selection)** (1-2 weeks) - COMPLETED
  - Created `SwarmTesting.swift` with MutatorCategory enum
  - `SwarmConfig`: enabled, mutatorInclusionProbability (default 0.5), configurationWindow
  - `SwarmScheduler` manages configuration sampling and tracking
  - `SwarmStats` tracks coverage hits per configuration
  - Integrated into FuzzEngine fuzzing loop
  - Verbose logging shows configuration changes

## Phase 3: Adaptive Mutation

- [x] **4. Adaptive Mutation Scheduling (MOPT/PSO)** (2-3 weeks) - COMPLETED
  - Created `AdaptiveMutationScheduler.swift` with MOPT-style scheduling
  - `MutationStrategy` enum: singleComponent, multiComponent, arithmetic, stringDictionary, valueProfileDirected, customMutator, freshGeneration
  - Three-phase pipeline: pilot (uniform), core (weighted), pacemaker (periodic uniform)
  - Tracks strategy success rates and adjusts selection probabilities
  - Integrated into FuzzEngine with `AdaptiveMutationConfig`
  - Added `mutateWithStrategy()` method for strategy-specific mutations
  - Added verbose logging for strategy effectiveness reporting

## Phase 4: Shrinking

- [x] **2. Test Case Shrinking / Delta Debugging** (3-4 weeks) - COMPLETED
  - Created `TestCaseShrinker.swift` with delta debugging algorithm
  - `Shrinkable` protocol for structure-aware shrinking
  - Default conformances: Array, String, Data
  - `IntegerShrinker` for numeric value shrinking
  - `MultiComponentShrinker` for tuple/struct inputs
  - `ShrinkConfig` with timeout, max executions, granularity settings
  - `ShrinkStats` for reduction statistics and reporting
  - Two-phase shrinking: chunk removal + element simplification

---

## Implementation Progress

Started: 2024-12-14
Completed: 2024-12-14

### Completed (8/8)
- [x] Coverage Plateau Detection with Early Stopping
- [x] Per-Execution Timeout / Hang Detection
- [x] Failure Preservation and Reporting
- [x] Entropic Seed Selection (Shannon Entropy)
- [x] Rare Branch Targeting (FairFuzz-Inspired)
- [x] Swarm Testing (Mutator Subset Selection)
- [x] Adaptive Mutation Scheduling (MOPT/PSO)
- [x] Test Case Shrinking / Delta Debugging

### Remaining (0/8)
All high-priority tasks completed!

### New Files Created
- `Sources/PropertyTestingKit/Fuzzing/CoveragePlateauDetector.swift`
- `Sources/PropertyTestingKit/Fuzzing/EntropicScheduler.swift`
- `Sources/PropertyTestingKit/Fuzzing/RareBranchTracker.swift`
- `Sources/PropertyTestingKit/Fuzzing/SwarmTesting.swift`
- `Sources/PropertyTestingKit/Fuzzing/AdaptiveMutationScheduler.swift`
- `Sources/PropertyTestingKit/Fuzzing/TestCaseShrinker.swift`

### Modified Files
- `Sources/PropertyTestingKit/Fuzzing/FuzzEngine.swift` - plateau detection, timeout, rare branch, swarm, adaptive mutation, stats
- `Sources/PropertyTestingKit/Fuzzing/FuzzAPI.swift` - perInputTimeout parameter
- `Sources/PropertyTestingKit/Fuzzing/Corpus.swift` - failure preservation, entropic selection, rare branch selection
