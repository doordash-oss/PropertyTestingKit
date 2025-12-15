# IJON: Exploring Deep State Spaces via Fuzzing

**Paper:** "IJON: Exploring Deep State Spaces via Fuzzing" (S&P 2020)
**Authors:** Cornelius Aschermann, Sergej Schumilo, Ali Abbasi, Thorsten Holz
**Affiliation:** Ruhr-Universität Bochum
**Venue:** 2020 IEEE Symposium on Security and Privacy, San Francisco, CA, pages 1597-1612
**Source:** https://wcventure.github.io/FuzzingPaper/Paper/SP20_IJON.pdf
**Alternative:** https://nyx-fuzz.com/papers/ijon.pdf
**Code:** https://github.com/RUB-SysSec/ijon
**IEEE Xplore:** https://ieeexplore.ieee.org/document/9152719/
**Algorithm Documentation:** https://github.com/fuzzuf/fuzzuf/blob/master/docs/algorithms/ijon/algorithm_en.md

## Paper Summary

IJON addresses a fundamental limitation of modern coverage-guided fuzzers: while tools like AFL excel at finding shallow bugs through automated exploration, they struggle with programs that have complex state spaces, checksum validations, hash lookups, or multi-stage constraints. These "roadblocks" prevent fuzzers from reaching deeper program states where interesting bugs might hide. Traditional solutions are limited to adding dictionaries or seed inputs, but these mechanisms are insufficient for targets that require specific sequences of state transitions or precise internal values to progress.

IJON introduces a lightweight annotation mechanism that allows human analysts to guide coverage-guided fuzzers by selectively exposing internal program state as additional feedback. Rather than relying solely on code coverage, IJON lets developers annotate their programs with hints about what internal values matter for exploration. For example, annotating a player's x-coordinate in Super Mario Bros turns the fuzzer into a position maximizer, enabling it to complete game levels. Similarly, exposing hash table bucket counts helps the fuzzer discover hash collisions. The key insight is that by treating state values as pseudo-coverage (maximizing interesting values or marking new states as "coverage"), the fuzzer can systematically explore state spaces that would otherwise be inaccessible.

The evaluation demonstrates that IJON-annotated AFL can solve previously unsolvable challenges from the DARPA Cyber Grand Challenge (CGC), play and complete video games like Super Mario Bros, navigate complex mazes, and bypass hash-based lookups. In a random subset of 30 CGC targets, IJON managed to produce crashes in 10 targets that resisted other approaches. For Super Mario Bros, IJON solved nearly all levels in minutes by simply exposing the player's x-coordinate—AFL became capable of completing all but 3 levels (one unsolvable due to an emulation bug, one solvable but requiring more time due to fuzzing randomness). For maze solving, AFL with IJON was more than 20 times faster than AFL without annotations. With typically one-line annotations, IJON enables fuzzers to solve problems that resisted fully automated fuzzing, symbolic execution, and even previous human-guided fuzzing attempts. The approach is implemented as an extension to multiple AFL variants (AFLFAST, LAF-INTEL, QSYM, ANGORA) and runs as a slave fuzzer in multi-instance setups, sharing successful inputs with other fuzzers while isolating intermediate exploration noise.

## Key Strategies/Techniques

1. **Annotation-Based State Exposure**: IJON provides a C macro API for developers to expose internal program state to the fuzzer:
   - `IJON_MAX(value)` / `IJON_MIN(value)`: Track maximum/minimum values seen, turning the fuzzer into a hill-climbing optimizer
   - `IJON_SET(value)` / `IJON_INC(value)`: Treat state values as pseudo-coverage by marking specific bitmap entries
   - `IJON_ENABLE()` / `IJON_DISABLE()`: Conditionally enable coverage feedback only when certain states are reached
   - Annotations are typically 1-2 lines of code inserted at strategic program locations

2. **Max-Map Mechanism**: IJON extends AFL's shared memory with a "max-map" containing 512 slots (by default), each tracking the maximum value seen for a specific program location. When an input produces a higher value in any slot, it's added to a separate IJON corpus. The scheduler uses branching logic: 80% of the time it selects from the IJON queue (applying havoc mutations directly), 20% of the time from the AFL queue (using standard flow). This allows the fuzzer to pursue both code coverage and state value optimization simultaneously. The fuzzer only stores the input that produces the best value for each slot and discards old inputs that resulted in smaller values.

3. **Virtual State Dimensions**: IJON-STATE annotation creates a Cartesian product of code coverage and state values. Instead of just tracking "edge X was executed," the fuzzer tracks "edge X was executed while in state S." This produces more fine-grained feedback, distinguishing program paths not just by code location but by the internal state context in which they execute. This is crucial for state machines where the same code has different semantics depending on current state.

4. **Selective Coverage Control**: IJON-ENABLE/DISABLE annotations let analysts guide exploration by gating coverage feedback on preconditions. For example, in a maze solver, coverage might only count when the player reaches a certain checkpoint, focusing fuzzing effort on progressing past that point rather than exploring dead ends.

5. **Multi-Fuzzer Coordination**: IJON runs as a slave fuzzer alongside unmodified AFL instances. When IJON solves a challenging structure (e.g., finding the hash collision that unlocks a path), the resulting input goes into the shared corpus. Other fuzzers pick it up and continue exploring, while IJON's intermediate exploration noise stays isolated. This architecture allows targeted human guidance without contaminating the main fuzzing campaign.

6. **Distance and Hash Helper Functions**: Beyond the core primitives, IJON provides utilities like `ijon_strdist()` and `ijon_memdist()` for measuring string/memory distances, and hash functions (`ijon_hashint()`, `ijon_hashstr()`, `ijon_hashmem()`, `ijon_hashstack()`) for creating unique identifiers from complex state. These enable sophisticated state tracking without manual slot management.

7. **Checksum Handling Strategy**: For targets with checksum validation, IJON demonstrates a practical workflow: (1) patch out the checksum check initially, (2) fuzz until a crash is found, (3) annotate the checksum difference value to expose feedback, (4) run AFL in crash exploration mode to force consistency. This approach allows the fuzzer to automatically generate valid checksums within seconds, addressing a well-documented fuzzing challenge where practitioners manually remove hard constraints.

8. **Maze Solving with Coordinate Tracking**: For maze navigation, IJON uses `IJON_SET` (rather than `IJON_INC`) with combined x,y coordinates. This treats any newly visited position as new coverage without caring about visit frequency. The annotation is a single line that makes all maze variants solvable—problems that no other automated tool could solve.

9. **State Machine Message Sequences**: For protocol fuzzing with state machines, IJON appends the command index (message type) to a state change log after each successfully parsed message. This helps the fuzzer explore diverse message sequences and state transitions systematically.

10. **Hash Map Lookup Optimization**: IJON can expose hash table bucket counts or collision rates, helping the fuzzer discover inputs that trigger worst-case hash map behavior (collisions, rehashing, load factor thresholds). This turns the fuzzer into a hash collision finder.

## Implementation Details

**Compilation:** IJON is implemented as LLVM instrumentation, requiring compilation with the IJON-enhanced compiler:
```bash
cd llvm_mode
LLVM_CONFIG=llvm-config-6.0 CC=clang-6.0 make
```

**Command-Line Usage:**
```bash
# Run IJON fuzzer (fuzzuf implementation)
fuzzuf ijon -i path/to/seeds/ path/to/PUT @@

# AFL with IJON extension (typically as slave fuzzer)
afl-fuzz -S ijon -i seeds -o findings -- ./target @@

# Disable normal instrumentation if using extensive MAX/MIN annotations
AFL_INST_RATIO=1 make
```

**API Functions Available:**
- State management: `ijon_xor_state()`, `ijon_push_state()`
- Feedback control: `ijon_map_inc()`, `ijon_map_set()`
- Distance metrics: `ijon_strdist()`, `ijon_memdist()`
- Value tracking: `ijon_max()`, `ijon_min()`
- Hash utilities: `ijon_simple_hash()`, `ijon_hashint()`, `ijon_hashstr()`, `ijon_hashmem()`, `ijon_hashstack()`
- Coverage control: `ijon_enable_feedback()`, `ijon_disable_feedback()`

**Macro Convenience Wrappers:**
- `IJON_INC(x)` - Increment with automatic location hashing
- `IJON_SET(x)` - Set value operations
- `IJON_MAX(x)` - Maximum tracking
- `IJON_MIN(x)` - Minimum tracking
- `IJON_DIST(x,y)` - Distance between values
- `IJON_STRDIST(x,y)` - String distance
- `IJON_CMP(x,y)` - Comparison feedback

**Architecture:** IJON retains most AFL functionality while adding:
- Modified havoc mutation procedures optimized for state exploration
- Separate IJON seed queue tracking 64-bit non-negative integer arrays
- 80/20 selection branching between IJON queue (direct havoc) and AFL queue (standard flow)
- Post-execution IJON queue updates based on maximum value feedback

## Applicability to PropertyTestingKit

### Alignment with Current Architecture

PropertyTestingKit already implements several foundational concepts that IJON builds upon:

1. **Coverage-Guided Foundation**: PropertyTestingKit uses LLVM coverage instrumentation (`CoverageSignature.swift`, AFL-style bucketing) to track which code paths are exercised. This is the same foundation IJON extends—it doesn't replace coverage, it augments it with state feedback.

2. **Value Profile Guidance**: PropertyTestingKit's `ValueProfile.swift` implements comparison tracking with distance metrics, which is conceptually similar to IJON's max-map mechanism. Both systems recognize that getting "closer" to a target value (even without reaching it) represents progress worth preserving. The `ComparisonRecord` tracks distances to magic numbers, and `scoreBonus()` rewards inputs that reduce these distances.

3. **Corpus Management**: PropertyTestingKit maintains a corpus of interesting inputs (`Corpus.swift`) with coverage signatures. Adding IJON-style state tracking would extend this to track "state signatures" alongside coverage signatures, allowing the corpus to preserve inputs that achieved novel states even if they didn't trigger new code paths.

4. **Mutation Infrastructure**: The existing `Mutator` system provides strategies for generating variations. IJON's directed mutations (binary search toward constants, modulo-aware mutations) could be integrated as additional mutation strategies triggered by value profile feedback.

5. **Swift Testing Integration**: PropertyTestingKit targets Swift Testing framework with `@Test` functions. IJON-style annotations would fit naturally as helper functions developers call within their test closures to expose relevant state.

### Practical Applications for PropertyTestingKit

IJON's techniques are highly applicable to PropertyTestingKit's domain—especially for Swift code with complex internal state:

1. **Parser Fuzzing**: When fuzzing parsers that have multi-stage validation (e.g., JSON parser checking depth, string length, nesting level), developers could annotate parse depth or nesting level. The fuzzer would then systematically explore deeper nesting levels, finding stack overflow or quadratic complexity bugs that shallow inputs miss.

2. **State Machine Testing**: Swift code with explicit state machines (network protocols, game logic, UI flows) could expose the current state enumeration. IJON would ensure the fuzzer exercises all state transitions, not just the most common paths from the initial state.

3. **Collection Operations**: Code that behaves differently based on collection sizes (hash table load factors, array resize thresholds, tree rebalancing) could expose these metrics. The fuzzer would discover edge cases around these boundaries that random generation might miss.

4. **Game Logic and Simulation**: The Super Mario Bros example directly translates to Swift game development. Exposing player position, score, game state, or level progression would help the fuzzer explore deeper game states and find bugs in late-game logic.

5. **Cryptographic and Hash Functions**: Code using checksums, hashes, or cryptographic validation could expose partial match distances (number of matching bytes/bits), helping the fuzzer make incremental progress toward satisfying these constraints.

6. **Resource Constraints**: Exposing memory usage, file handle counts, or connection pool sizes would help the fuzzer discover resource exhaustion bugs by systematically pushing these metrics to their limits.

### Challenges and Limitations

1. **API Design for Swift**: IJON's C macro API (`IJON_MAX(x)`) doesn't translate directly to Swift. PropertyTestingKit would need to design a Swift-native annotation API that feels natural in Swift Testing's declarative style. Options include:
   - Global functions: `Fuzz.track(maxValue: player.x, label: "position")`
   - Test closure context: `track(max: player.x)` available within `fuzz { ... }` closure
   - Property wrappers: `@FuzzTrack(.maximize) var playerX: Int`

2. **Shared Memory Architecture**: IJON extends AFL's shared memory region with the max-map. PropertyTestingKit runs in-process within Swift Testing, not as a separate fuzzer binary. The equivalent would be thread-local or test-scoped storage for tracking maximum values, which is simpler but loses the multi-process coordination aspect.

3. **Slot Management**: IJON uses 512 max-map slots by default, requiring hash functions to map tracking calls to slots. PropertyTestingKit could use a simpler approach: a dictionary keyed by source location (file + line number) or explicit label strings, avoiding slot collisions entirely since it's single-process.

4. **User Complexity**: IJON requires users to understand their program's internal state and identify which values matter for exploration. This is more manual than PropertyTestingKit's current "just call `fuzz { ... }`" approach. Clear documentation and examples would be essential to make annotations approachable for Swift developers.

5. **Value Profile Integration**: PropertyTestingKit's existing value profile tracking captures comparisons automatically via compiler instrumentation. IJON's manual annotations complement this but don't replace it. The challenge is integrating both: automatic comparison tracking for discovering magic numbers, and manual annotations for higher-level state that comparisons don't capture (e.g., hash table size, game level progress).

6. **Multi-Fuzzer Coordination**: IJON's slave fuzzer architecture prevents intermediate exploration noise from contaminating other fuzzers. PropertyTestingKit's single-instance per-test model means IJON-style tracking would need to be more selective about what gets added to the corpus (e.g., only add inputs that either improve max values OR discover new coverage, not intermediate attempts).

### Synergies with Existing Features

IJON concepts complement PropertyTestingKit's existing features:

1. **Value Profile Mutations**: The existing `ComparisonTarget.binarySearchMutations()` and `moduloAwareMutations()` in `ValueProfile.swift` are already IJON-like directed mutations. These could be extended to work with manual max-tracking: when a user annotates a value to maximize, generate mutations using the same binary search approach currently used for comparison targets.

2. **Custom Mutators**: PropertyTestingKit's `Mutator` system allows domain-specific strategies. IJON-tracked state could inform custom mutators: e.g., a mutator for game inputs could prioritize actions that increase the tracked position coordinate.

3. **Corpus Persistence**: PropertyTestingKit saves corpora to disk (`Corpus/` directory). IJON-tracked maximum values could be persisted alongside coverage signatures, allowing regression tests to verify not just that code paths are exercised but that deep states are still reachable.

4. **Energy-Based Scheduling**: The corpus already uses energy-based selection (prioritizing entries that produced new coverage). IJON's max-map could extend this: inputs that achieved high values in tracked metrics get higher energy scores, making them more likely to be mutated further.

## Concrete Recommendations

### High Priority (Implement These First)

1. **Add Manual State Tracking API** (2-3 days)
   - Create `StateTracker` class similar to `ValueProfileTracker` in `ValueProfile.swift`
   - API: `StateTracker.track(max: value, label: String)` callable within fuzz closure
   - Track maximum value seen per label, similar to IJON's max-map
   - Return `StateProgress` result indicating whether this execution improved any tracked values
   - **Files to create**: `Sources/PropertyTestingKit/Fuzzing/StateTracker.swift`
   - **Expected benefit**: Enable developers to guide fuzzing for state-heavy targets (games, parsers, state machines)

2. **Integrate State Tracking with Corpus Selection** (1-2 days)
   - Extend `CorpusEntry` to include `stateImprovements: [String: UInt64]` (labels -> max values achieved)
   - When an input improves a tracked value, add it to corpus even if coverage didn't increase
   - Modify `pickCorpusEntry()` in `FuzzEngine.swift` to consider state improvements in energy calculation
   - **Files to modify**: `Corpus.swift` (add state tracking to entries), `FuzzEngine.swift` (corpus selection logic)
   - **Expected benefit**: Preserve inputs that make state progress, crucial for deep state exploration

3. **State-Aware Directed Mutations** (2-3 days)
   - When an input improves a tracked integer value, apply `ComparisonTarget.binarySearchMutations()` logic
   - Generate mutations that interpolate between current and potential higher values
   - Use existing `ValueProfile.swift` mutation helpers for this
   - **Files to modify**: `FuzzEngine.swift` (add state-directed mutation strategy)
   - **Expected benefit**: Systematic exploration toward state boundaries (e.g., maximizing depth, position, count)

4. **Documentation and Examples** (2 days)
   - Add "State-Guided Fuzzing" section to README with examples:
     - Maze solver: track position coordinates
     - Parser: track parse depth and input complexity
     - Game: track level progress and score
   - Create example test demonstrating state tracking with a simple game or parser
   - **Files to modify**: `README.md`, add example in `Tests/PropertyTestingKitTests/Examples/`
   - **Expected benefit**: Make feature discoverable and usable by Swift developers

### Medium Priority (Nice to Have)

5. **Conditional Coverage (IJON-ENABLE/DISABLE equivalent)** (3-4 days)
   - Add `StateTracker.conditionalCoverage(enabled: Bool)` to gate coverage tracking
   - When disabled, coverage counters are captured but not used for corpus decisions
   - Useful for focusing fuzzing on post-checkpoint code
   - **Implementation challenge**: Requires extending `CoverageSignature` to support conditional capture
   - **Expected benefit**: Prevent fuzzer from wasting effort on dead-end paths before reaching key states

6. **Virtual State Signatures** (3-4 days)
   - Extend `CoverageSignature` to include state labels and values in signature hash
   - Two inputs with same coverage but different tracked state values get different signatures
   - Similar to IJON-STATE creating Cartesian product of coverage × state
   - **Files to modify**: `CoverageSignature.swift` (add state dimension), `Corpus.swift` (track state signatures)
   - **Expected benefit**: Finer-grained corpus diversity for state machines where code location alone is insufficient

7. **State Tracking for Collections** (2-3 days)
   - Helper API: `StateTracker.track(collectionSize: array.count, label: "array")`
   - Automatically applies to common Swift collections (Array, Dictionary, Set)
   - Helps discover boundary bugs around collection size thresholds
   - **Files to modify**: `StateTracker.swift` (add collection helpers)
   - **Expected benefit**: Easier annotation for common use case of tracking collection growth

### Low Priority (Research/Experimental)

8. **Automatic State Discovery (SandPuppy-style)** (1-2 weeks)
   - Research project: automatically identify state-representative variables
   - Analyze coverage traces to find variables that correlate with coverage increases
   - Automatically instrument these variables without manual annotations
   - **Complexity**: Requires program analysis, potentially LLVM instrumentation pass
   - **Expected benefit**: Combine IJON's power with fully automated fuzzing (no manual annotations needed)

9. **Multi-Test State Persistence** (3-4 days)
   - Persist state tracking progress across test runs
   - Build a project-wide "state database" of maximum values achieved
   - Initialize new fuzzing runs with historical maximums to avoid re-exploration
   - **Files to create**: Persistent storage in `Corpus/` directory for state history
   - **Expected benefit**: Faster convergence by building on previous fuzzing knowledge

10. **Integration with Custom Mutators** (2-3 days)
    - Allow custom mutators to query `StateTracker` for current progress
    - Mutators can generate values targeted at improving tracked metrics
    - E.g., `String.mutators(.deepNesting)` could check tracked parse depth and generate deeply nested structures
    - **Files to modify**: `Mutator.swift` (pass StateTracker to mutation strategies)
    - **Expected benefit**: Domain-specific mutators become state-aware, focusing effort on progress

### Implementation Sketch: Basic State Tracking

```swift
// Sources/PropertyTestingKit/Fuzzing/StateTracker.swift
public final class StateTracker: Sendable {
    private struct Entry {
        var maxValue: UInt64
        var bestInput: Any? // Store input that achieved this max
    }

    private var tracked: [String: Entry] = [:]
    private let lock = NSLock()

    /// Track a maximum value for a labeled metric
    public func track(max value: UInt64, label: String) {
        lock.lock()
        defer { lock.unlock() }

        let current = tracked[label]?.maxValue ?? 0
        if value > current {
            tracked[label] = Entry(maxValue: value, bestInput: nil)
        }
    }

    /// Check if current execution improved any tracked values
    public func hasImprovements() -> [String: UInt64] {
        // Returns labels and new maximum values that were improved
    }

    /// Generate directed mutations toward higher values
    public func directedMutations(for label: String, currentValue: Int) -> [Int] {
        // Use binary search logic from ValueProfile.swift
        guard let entry = tracked[label] else { return [] }
        let target = ComparisonTarget(
            target: entry.maxValue,
            current: UInt64(currentValue),
            isSigned: true
        )
        return target.binarySearchMutations()
    }
}

// Usage in test - Game Progression (Super Mario Bros-style):
@Test func testGameProgression() throws {
    let stateTracker = StateTracker()

    try fuzz(using: .game) { (input: GameInput) in
        let game = Game()
        game.processInput(input)

        // Expose game state to fuzzer
        stateTracker.track(max: UInt64(game.player.x), label: "position")
        stateTracker.track(max: UInt64(game.currentLevel), label: "level")

        #expect(!game.hasCrashed)
    }
}

// Usage in test - Maze Navigation:
@Test func testMazeSolver() throws {
    let stateTracker = StateTracker()

    try fuzz { (input: String) in
        let maze = Maze()
        let position = maze.navigate(commands: input)

        // Track position as combined state (like IJON_SET)
        let positionHash = UInt64(position.x * 1000 + position.y)
        stateTracker.track(max: positionHash, label: "maze_position")

        #expect(!maze.hitWall)
    }
}

// Usage in test - Parser Depth:
@Test func testParserDepth() throws {
    let stateTracker = StateTracker()

    try fuzz { (input: String) in
        let parser = JSONParser()
        let result = parser.parse(input)

        // Expose parse depth to find deep nesting bugs
        stateTracker.track(max: UInt64(parser.maxDepth), label: "nesting")
        stateTracker.track(max: UInt64(parser.arrayCount), label: "arrays")

        #expect(!result.crashed)
    }
}

// Usage in test - Hash Map Collisions:
@Test func testHashMapWorstCase() throws {
    let stateTracker = StateTracker()

    try fuzz { (keys: [String]) in
        let map = HashMap<String, Int>()
        for (i, key) in keys.enumerated() {
            map[key] = i
        }

        // Expose collision rate to find adversarial inputs
        stateTracker.track(max: UInt64(map.maxBucketSize), label: "collisions")

        #expect(map.count == keys.count)
    }
}

// Usage in test - State Machine Message Sequences:
@Test func testProtocolStateMachine() throws {
    let stateTracker = StateTracker()
    var stateLog: [UInt8] = []

    try fuzz { (messages: [Message]) in
        let protocol = NetworkProtocol()

        for message in messages {
            if protocol.handle(message) {
                // Track successful state transitions
                stateLog.append(message.commandID)
                stateTracker.track(max: UInt64(stateLog.count), label: "sequence_length")
            }
        }

        #expect(!protocol.isInInvalidState)
    }
}
```

### Success Metrics

To evaluate IJON-inspired features:

1. **Deep State Coverage**: Measure whether annotated tests reach deeper program states (e.g., later game levels, deeper parse trees) compared to unannotated fuzzing
2. **Challenging Target Solving**: Create benchmark tests with known roadblocks (checksum validation, hash lookup, multi-stage state machines) and measure solve rates with/without state tracking
3. **Annotation Burden**: Track how many lines of annotation code users need to write (goal: 1-3 lines per test, matching IJON's promise)
4. **Performance Overhead**: Measure fuzzing throughput with state tracking enabled vs. disabled (goal: <10% overhead)
5. **Corpus Quality**: Compare corpus sizes and coverage achieved with state tracking vs. without for state-heavy targets

### Related Work Integration

PropertyTestingKit already has research summaries for related techniques. IJON combines well with:

1. **DART (delta-debugging)**: Use IJON to reach deep states, then use delta-debugging to minimize failing inputs
2. **RLCheck (reinforcement learning)**: IJON's manual annotations could be learning targets for RL—automatically discover which state variables to track
3. **Traditional fuzzing (Miller)**: IJON shows when pure randomness isn't enough and human insight adds value
4. **SandPuppy (Automatic State Discovery)**: A follow-on technique that automatically identifies state-representative variables and applies IJON-style instrumentation. SandPuppy collects runtime variable-value traces from an initial fuzzing run and analyzes them along with program source to determine which variables correlate with coverage progress. This eliminates IJON's manual annotation requirement while preserving its deep state exploration benefits—a promising direction for PropertyTestingKit's future development.

## Conclusion

IJON's annotation-based state exposure is highly applicable to PropertyTestingKit. The core concepts—tracking maximum values, treating state as pseudo-coverage, directed mutations toward targets—align well with PropertyTestingKit's existing architecture (value profile guidance, corpus management, mutation strategies). The main implementation challenges are designing a Swift-native annotation API and integrating state tracking with the existing coverage-guided corpus selection.

The highest-impact recommendation is implementing basic state tracking (recommendations 1-4 above), which could be completed in about 1-2 weeks. This would enable PropertyTestingKit to fuzz state-heavy targets like parsers, games, and state machines that are currently difficult to thoroughly explore. The API should be simple enough that developers can add 1-3 lines of annotation per test to expose critical state variables, matching IJON's promise of lightweight guidance with significant exploration benefits.

IJON demonstrates that coverage-guided fuzzing is more powerful when augmented with human insight about what internal state matters. PropertyTestingKit is well-positioned to bring this capability to Swift Testing, making deep state exploration accessible to Swift developers without requiring them to understand AFL internals or C macro programming.
