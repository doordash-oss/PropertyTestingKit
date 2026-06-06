# PropertyTestingKit

Coverage-guided fuzz testing for Swift.

## Overview

PropertyTestingKit brings coverage-guided fuzzing to Swift Testing:

- **Coverage-guided fuzzing** - Automatically discover inputs that exercise new code paths
- **Corpus persistence** - Save and replay interesting inputs across test runs
- **Regression testing** - Replay saved corpus to catch regressions
- **Schedule fuzzing** - Deterministically explore concurrent task interleavings to surface order-dependent races
- **High throughput** - ~35M iterations/sec with full per-test concurrent coverage isolation

## Requirements

- macOS 26+ / iOS 26+
- Swift 6.3+

## Installation

### Swift Package Manager

Add PropertyTestingKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/alex-reilly-dd/PropertyTestingKit.git", from: "0.0.1"),
],
targets: [
    .testTarget(
        name: "YourTests",
        dependencies: ["PropertyTestingKit"]
    ),
]
```

## Usage

### Coverage-Guided Fuzzing

The `fuzz` function automatically generates inputs that maximize code coverage:

```swift
import Testing
import PropertyTestingKit

@Test func testDatabaseQuery() async throws {
    try await fuzz(seeds: [
        ("users", 0),
        ("users", 100),
        ("orders", -1),
    ]) { table, limit in
        let query = buildQuery(table: table, limit: limit)
        let result = database.execute(query)

        // Properties that should hold for all inputs
        #expect(result.isValid || result.hasError)
        if limit < 0 {
            #expect(result.hasError, "Negative limit should error")
        }
    }
}
```

**How it works:**
1. Starts with seed values (yours + type defaults from `MutatorProviding.defaultMutator`)
2. Runs each input and captures coverage
3. Inputs that hit new code paths are saved to the corpus
4. Mutates interesting inputs to discover more paths
5. Stops when the time limit is reached
6. Saves minimal corpus to disk for future runs

**On subsequent runs:**
- Replays saved corpus to check for crashes (regression testing)

### Corpus Storage

The corpus is saved alongside your test files:

```
Tests/
  MyTests/
    ParserTests.swift
    Corpus/                      # Created automatically
      testParser/
        corpus.json              # Saved inputs + coverage signatures
```

Commit the `Corpus/` directory to version control for deterministic CI runs.

### Fuzzing vs. regression

There are two entry points. `fuzz(...)` explores inputs and maintains a corpus;
`regress(...)` only replays a saved corpus to verify it still passes. The split is
deliberate: regression takes none of the fuzz-only knobs (`seeds`, `coverageStrategy`,
`parallelism`), and its plugins are `AnalysisPlugin`s that can only observe (`stop` /
`recordIssue`) — so it's impossible, at compile time, to hand a replay a configuration or
a plugin that would explore or mutate the corpus.

`fuzz(...)` takes a `persistence:` policy controlling how it treats an existing corpus:

| `CorpusPersistence` | Behavior |
|------|----------|
| `.auto` | Replay the corpus if one exists, otherwise fuzz fresh and save (default) |
| `.replace` | Delete any existing corpus, fuzz fresh, and save |
| `.extend` | Load the existing corpus as seeds, fuzz, and save |
| `.ephemeral` | Fuzz in memory only — ignore any existing corpus and don't save (nothing touches disk) |

**Per-test control:**

```swift
@Test func testParser() async throws {
    // Force re-fuzzing even if a corpus exists
    try await fuzz(persistence: .replace) { (input: String) in
        parse(input)
    }
}

@Test func testExtendCorpus() async throws {
    // Build on the existing corpus with a longer duration
    try await fuzz(persistence: .extend, duration: .seconds(120)) { (input: String) in
        parse(input)
    }
}

@Test func testParserRegression() async throws {
    // Replay the saved corpus only — fails if any saved input now trips the test
    try await regress { (input: String) in
        parse(input)
    }
}
```

**Suite-level control via environment:**

Users may want to run background fuzzing campaigns outside of the standard CI loop uising `FUZZ_CORPUS_MODE=refuzzextend`. This allows a balance to be struck between fast deterministic test runs and thorough testing. 

```bash
# Re-fuzz all tests, replacing existing corpora
FUZZ_CORPUS_MODE=refuzzreplace swift test

# Extend existing corpora with more fuzzing (2 minute duration)
FUZZ_CORPUS_MODE=refuzzextend FUZZ_DURATION=120 swift test

# CI mode: force every fuzz test to replay-only — no exploration (fast, deterministic).
# regress(...) tests always replay regardless of this variable.
FUZZ_CORPUS_MODE=regressiononly swift test
```

### Custom Seeds

Provide domain-specific seeds to guide the fuzzer toward edge cases:

```swift
@Test func testNumberParser() async throws {
    try await fuzz(seeds: [
        "0", "-0", "+0",           // Zero variants
        String(Int.max),           // Boundary
        String(Int.min),           // Boundary
        "1.5", "1e10",             // Invalid formats
        "   42   ",                // Whitespace
    ]) { input in
        if let n = NumberParser.parse(input) {
            // Round-trip property
            #expect(NumberParser.parse(String(n)) == n)
        }
    }
}
```

### Custom Mutators

Use domain-specific mutation strategies instead of the default `MutatorProviding` conformance:

```swift
@Test func testInputValidation() async throws {
    // Single mutator with multiple strategies
    try await fuzz(using: String.mutators(.sql, .xss)) { input in
        let sanitized = sanitize(input)
        #expect(!sanitized.contains("DROP TABLE"))
        #expect(!sanitized.contains("<script>"))
    }
}

@Test func testAPIEndpoint() async throws {
    // Multiple mutators for multiple inputs
    try await fuzz(
        using: String.mutators(.urls), Int.mutators(.ports)
    ) { (url: String, port: Int) in
        let result = connect(to: url, port: port)
        #expect(result.isValid || result.hasError)
    }
}
```

**Built-in String strategies:**
- `.phoneNumbers` - Phone number formats (+1-800-555-1234, etc.)
- `.emails` - Email addresses and edge cases
- `.urls` - URLs including protocol-relative and javascript:
- `.sql` - SQL injection payloads (DROP TABLE, OR 1=1, etc.)
- `.xss` - XSS payloads (script tags, event handlers, etc.)
- `.unicode` - Unicode edge cases (emoji, RTL, zero-width, etc.)
- `.whitespace` - Various whitespace characters
- `.empty` - Empty and near-empty strings
- `.boundaries` - Length boundaries (0, 1, 255, 256, 65535)

**Built-in Int strategies:**
- `.boundaries` - Integer boundaries (0, ±1, Int.max, Int.min, etc.)
- `.ports` - Common port numbers (22, 80, 443, 8080, 65535, etc.)
- `.httpStatusCodes` - HTTP status codes (200, 404, 500, etc.)
- `.negative` - Negative values
- `.powers` - Powers of two

**Built-in Double strategies:**
- `.boundaries` - Floating point boundaries
- `.special` - NaN, infinity, ulp
- `.percentages` - Values in 0-1 range with edge cases

Strategies can be composed — mutations from all strategies are applied to seeds from all strategies, enabling cross-strategy fuzzing (e.g., SQL mutations applied to XSS seeds).

### MutatorProviding Protocol

Types conforming to `MutatorProviding` provide a default mutator for fuzzing. When no explicit mutator is passed to `fuzz()`, the type's `defaultMutator` is used automatically.

```swift
extension MyType: MutatorProviding {
    public static var defaultMutator: Mutator<MyType> {
        Mutator(
            seeds: [
                MyType(field: "default"),
                MyType(field: "edge-case"),
            ],
            mutate: { value in
                // Return variations of value
                [MyType(field: value.field.uppercased())]
            },
            generate: { rng in
                // Generate a random value
                MyType(field: String((0..<5).map { _ in
                    Character(UnicodeScalar(UInt8.random(in: 65...90, using: &rng)))
                }))
            }
        )
    }
}
```

Built-in `MutatorProviding` conformances: `Bool`, `Int`, `UInt`, `UInt8`, `Double`, `Character`, `String`, `Optional`, `Array`

The `Mutator` struct has three components:
- **`seeds`**: Starting values for fuzzing
- **`mutate`**: Takes a value and returns variations of it
- **`generate`**: Creates a fresh random value (called when the mutation queue is exhausted)

You can omit `generate` — it defaults to picking a random seed:

```swift
let mutator = Mutator<Int>(
    seeds: [0, 1, -1, Int.max],
    mutate: { [$0 + 1, $0 - 1, $0 * 2] }
)
```

### When Fuzzing Finds a Bug

When fuzzing discovers a failing input, you'll see a detailed report:

```
Fuzz test failure #1

Failing input:
{
  "userId": -9223372036854775808,
  "name": "x"
}

Error:
ValidationError: User ID cannot be negative

Fuzz run stats:
  - Total inputs tested: 847
  - Stop reason: timeLimit
```

The failure includes:
- **Failing input**: The exact input that caused the failure (JSON-formatted for complex types)
- **Error**: The error that was thrown
- **Fuzz run stats**: Context about the fuzzing session

To reproduce the failure, the failing input is automatically saved to the corpus and will be replayed on subsequent test runs.

### Coverage Gap Detection

Find functions with incomplete test coverage using the coverage gap plugin:

```swift
@Test func testParser() async throws {
    try await fuzz(
        plugins: { [.corpusMutation(), .coverageGap()] }
    ) { (input: String) in
        parse(input)
    }
}
```

After fuzzing completes, coverage gaps are reported as test issues:

```
Coverage gap: parseNumber in Parser.swift is 75% covered (lines: 42, 47, 51)
```

This helps identify:
- Branches not exercised by the fuzzer
- Dead code or unreachable paths
- Areas needing additional seeds or mutators

See [Plugins](#plugins) for more details on the plugin system.

### Plugins

The fuzzer uses a plugin system to customize behavior:

```swift
try await fuzz(
    plugins: { [.corpusMutation(), .plateauDetector()] }
) { (input: String) in
    parse(input)
}
```

A plugin receives synchronous events (per-iteration) and async events (start, end, failure),
and can return actions (stop, queue inputs, record issues, etc.). There are two plugin types:

- **`FuzzPlugin`** — full plugins that may emit write actions (queue inputs, mutate, submit to
  the corpus). Valid only in `fuzz(...)`.
- **`AnalysisPlugin`** — observe-only plugins whose actions are limited to `stop` / `recordIssue`.
  Valid in both `regress(...)` and `fuzz(...)` (auto-lifted via `.asFuzzPlugin()`). The
  observe-only factories below (e.g. `.coverageGap()`, the stopping detectors) are
  `AnalysisPlugin`s, which is why a regression replay can never be handed a corpus-mutating plugin.

#### Built-in plugins

| Plugin | Category | Description |
|---------|----------|-------------|
| `.mutation()` | Mutation | Basic: queues mutations when new coverage is found |
| `.corpusMutation()` | Mutation | AFL-style: re-mutates random interesting inputs when queue drains (default) |
| `.energyMutation()` | Mutation | Entropic: Shannon entropy weighted selection from interesting inputs |
| `.shrinking()` | Shrinking | Delta-debugging shrink on failure to find minimal reproducer |
| `.plateauDetector()` | Stopping | Stops when coverage discovery rate drops below threshold |
| `.stadsDetector()` | Stopping | Statistical stopping using STADS methodology |
| `.saturationDetector()` | Stopping | Stops when coverage growth saturates |
| `.coverageGap()` | Analysis | Reports partially-covered functions after fuzzing completes |

#### Custom plugins

Create a custom plugin by constructing `FuzzPlugin` directly (use `AnalysisPlugin` instead if
it only observes, so it also works in `regress(...)`):

```swift
let loggingPlugin = FuzzPlugin<String>(
    id: "logger",
    handleSync: { event in
        switch event {
        case .iteration(let ctx):
            if ctx.newCoverage != nil {
                print("New coverage from: \(ctx.input)")
            }
        }
        return []
    },
    handleAsync: { event in
        switch event {
        case .start(let ctx):
            print("Fuzzing started, max duration: \(ctx.maxDuration)")
        case .end:
            print("Fuzzing complete")
        case .failureFound(let ctx):
            print("Failure: \(ctx.input)")
        }
        return []
    }
)

try await fuzz(
    plugins: { [.corpusMutation(), loggingPlugin] }
) { (input: String) in
    parse(input)
}
```

### Schedule Fuzzing (concurrency races)

Order-dependent concurrency bugs are notoriously hard to reproduce: they depend on how the
runtime happens to interleave concurrent tasks. Pass `scheduleFuzzing: true` and the fuzzer
also explores the *interleaving order* of the tasks your test spawns — turning a rare race
into a deterministic, replayable failure.

This is inspired by **ConFuzz** (Padhiyar & Sivaramakrishnan, [_Coverage-guided Property Fuzzing
for Event-driven Programs_, PADL 2021](https://kcsrk.info/papers/confuzz_padl21.pdf)), which has
AFL mutate both program inputs *and* the concurrent schedule, using coverage feedback to drive
assertions to fail.

```swift
@Test func concurrentCounterIsConsistent() async throws {
    try await fuzz(scheduleFuzzing: true) { (workers: Int) in
        let counter = Counter()  // your type under test
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(1 + abs(workers % 8)) {
                group.addTask { await counter.bump() }
            }
        }
        // If `Counter` has an order-dependent race, schedule fuzzing finds the
        // interleaving that violates this — and saves it for replay.
        #expect(await counter.value == 1 + abs(workers % 8))
    }
}
```

**How it works:**

Normally the Swift runtime decides when each of your concurrent tasks gets to run, and that
timing shifts from run to run — which is exactly why races are flaky and hard to reproduce.
Schedule control takes that decision away from the runtime and gives it to the fuzzer:

1. **It intercepts task scheduling.** For the tasks your test spawns (`Task {}`, task groups,
   continuations), it captures them instead of letting the runtime dispatch them freely, and
   runs them **one at a time on a single thread** — a fully serialized, deterministic drain.
2. **The schedule bytes decide who runs next.** Whenever more than one task is runnable, the
   scheduler has to choose one. That choice is driven by the fuzzed bytes: the *k*-th decision
   reads byte *k* and picks `byte % (number of runnable tasks)`. So one byte string describes
   one exact interleaving, end to end.
3. **The fuzzer searches interleavings like it searches inputs.** Mutating the bytes reorders
   *who runs when*, exploring the space of possible interleavings. A byte string that trips your
   assertions is a concrete schedule — saved to the corpus and **replayed deterministically**,
   so a once-in-a-thousand race becomes a test that fails the same way every time.

Everything outside your test's tasks runs untouched. Practically: the interleaving is treated
as just more fuzzed input (so it's mutated, persisted, and replayed like any input, while your
`test` closure still receives only its own `(repeat each Input)`); `parallelism` is forced to 1
since the schedule itself now controls ordering; and the default `corpusMutation` plugin is used
(custom `plugins` are not applied to scheduled runs). The machinery lives in the separate
`ScheduleControl` module, which `scheduleFuzzing: true` wires into the fuzz loop for you.

### Building with Coverage

Your test target must be compiled with SanitizerCoverage flags. Add these to your `Package.swift`:

```swift
.testTarget(
    name: "MyTests",
    dependencies: ["PropertyTestingKit"],
    swiftSettings: [
        .unsafeFlags([
            "-sanitize-coverage=edge,pc-table"
        ])
    ]
)
```

Then run tests normally:

```bash
swift test
```

## Performance

Benchmarked on Apple M3 Max (12 P-cores @ 4.05 GHz, 4 E-cores @ 2.75 GHz, 64 GB RAM):

| Configuration | Throughput | Per Core Per GHz |
|---------------|------------|------------------|
| Single `fuzz()` call | ~35M iter/sec | ~587K iter/GHz/sec |
| 8 concurrent `fuzz()` calls | ~33M iter/sec | ~554K iter/GHz/sec |
| 16 concurrent `fuzz()` calls | ~32M iter/sec | ~537K iter/GHz/sec |

## License

This project is licensed under the Apache License 2.0.
See [LICENSE](LICENSE) for details.

## Notices

See [NOTICE.txt](NOTICE.txt) for third-party components and attributions.

## Contributor License Agreement (CLA)

Contributions to this project require agreeing to the DoorDash Contributor License Agreement.
See [CONTRIBUTOR_LICENSE_AGREEMENT.md](CONTRIBUTOR_LICENSE_AGREEMENT.md).
