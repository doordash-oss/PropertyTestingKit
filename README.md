# PropertyTestingKit

Coverage-guided fuzz testing for Swift.

## Overview

PropertyTestingKit brings coverage-guided fuzzing to Swift Testing:

- **Coverage-guided fuzzing** - Automatically discover inputs that exercise new code paths
- **Corpus persistence** - Save and replay interesting inputs across test runs
- **Regression detection** - Automatically re-fuzz when code changes affect coverage
- **High throughput** - ~35M iterations/sec with full coverage isolation

## Performance

Benchmarked on Apple M3 Max (12 P-cores @ 4.05 GHz, 4 E-cores @ 2.75 GHz, 64 GB RAM):

| Configuration | Throughput | Per Core Per GHz |
|---------------|------------|------------------|
| Single `fuzz()` call | ~35M iter/sec | ~587K iter/core/GHz/sec |
| 8 concurrent `fuzz()` calls | ~33M iter/sec | ~554K iter/core/GHz/sec |
| 16 concurrent `fuzz()` calls | ~32M iter/sec | ~537K iter/core/GHz/sec |

Throughput scales nearly linearly — running 16 concurrent fuzz tests retains ~91% of single-call throughput. Coverage tracking uses lock-free data structures and SIMD-optimized scanning, ensuring minimal overhead even under heavy concurrency.

## Requirements

- macOS 26+ / iOS 26+
- Swift 6.3+

## Installation

### Swift Package Manager

Add PropertyTestingKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/alex-reilly-dd/PropertyTestingKit.git", from: "1.0.0"),
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
- Replays saved corpus to verify coverage unchanged
- If coverage differs (code changed), automatically re-fuzzes

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

### Corpus Modes

Control how the fuzzer interacts with saved corpora:

| Mode | Behavior |
|------|----------|
| `.auto` | Run regression if corpus exists, otherwise fuzz (default) |
| `.refuzzReplace` | Always fuzz fresh, replacing existing corpus |
| `.refuzzExtend` | Load corpus as seeds, continue fuzzing to find more |
| `.regressionOnly` | Only run regression, skip tests with no corpus |

**Per-test control:**

```swift
@Test func testParser() async throws {
    // Force re-fuzzing even if corpus exists
    try await fuzz(corpusMode: .refuzzReplace) { (input: String) in
        parse(input)
    }
}

@Test func testExtendCorpus() async throws {
    // Build on existing corpus with a longer duration
    try await fuzz(corpusMode: .refuzzExtend, duration: .seconds(120)) { (input: String) in
        parse(input)
    }
}
```

**Suite-level control via environment:**

```bash
# Re-fuzz all tests, replacing existing corpora
FUZZ_CORPUS_MODE=refuzzreplace swift test

# Extend existing corpora with more fuzzing (2 minute duration)
FUZZ_CORPUS_MODE=refuzzextend FUZZ_DURATION=120 swift test

# CI mode: only run regression tests (fast, deterministic)
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

**Bool:**
```swift
try await fuzz(using: Bool.mutator()) { flag in ... }
```

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

### Configuration

```swift
try await fuzz(
    seeds: [...],                  // Domain-specific seed values
    duration: .seconds(60),        // Max fuzzing time (default: 60s)
    corpusMode: .auto,             // Corpus behavior (default: .auto)
    parallelism: 8                 // Parallel engines (default: CPU count)
) { input in
    // test
}
```

Environment variables:
- `FUZZ_VERBOSE=1` - Enable detailed logging
- `FUZZ_DURATION=N` - Override max duration (seconds)
- `FUZZ_CORPUS_MODE=<mode>` - Control corpus behavior (see [Corpus Modes](#corpus-modes))

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
        makeHandlers: { [.corpusMutation(), .coverageGap()] }
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

The fuzzer uses a plugin handler system to customize behavior. Plugins are passed via the `makeHandlers` parameter, which is a factory that creates a fresh set of handlers per parallel engine:

```swift
try await fuzz(
    makeHandlers: { [.corpusMutation(), .plateauDetector()] }
) { (input: String) in
    parse(input)
}
```

Each `FuzzPluginHandler` receives synchronous events (per-iteration) and async events (start, end, failure), and can return actions (stop, queue inputs, record issues, etc.).

#### Built-in Plugin Handlers

| Handler | Category | Description |
|---------|----------|-------------|
| `.mutation()` | Mutation | Basic: queues mutations when new coverage is found |
| `.corpusMutation()` | Mutation | AFL-style: re-mutates random interesting inputs when queue drains (default) |
| `.energyMutation()` | Mutation | Entropic: Shannon entropy weighted selection from interesting inputs |
| `.shrinking()` | Shrinking | Delta-debugging shrink on failure to find minimal reproducer |
| `.plateauDetector()` | Stopping | Stops when coverage discovery rate drops below threshold |
| `.stadsDetector()` | Stopping | Statistical stopping using STADS methodology |
| `.saturationDetector()` | Stopping | Stops when coverage growth saturates |
| `.coverageGap()` | Analysis | Reports partially-covered functions after fuzzing completes |

#### Stopping Condition Examples

```swift
// Default: only time limit applies
try await fuzz { input in ... }

// Stop early when coverage plateaus
try await fuzz(
    makeHandlers: { [.corpusMutation(), .plateauDetector()] }
) { input in ... }

// Statistical stopping with custom config
try await fuzz(
    makeHandlers: { [
        .corpusMutation(),
        .stadsDetector(minDiscoveryProbability: 0.001, confirmationChecks: 3, checkInterval: 100)
    ] }
) { input in ... }

// Saturation-based stopping
try await fuzz(
    makeHandlers: { [
        .corpusMutation(),
        .saturationDetector(minSaturation: 0.99, windowSize: 500)
    ] }
) { input in ... }
```

#### Custom Plugin Handlers

Create custom handlers by constructing `FuzzPluginHandler` directly:

```swift
let loggingHandler = FuzzPluginHandler<String>(
    id: "logger",
    handleSync: { event in
        switch event {
        case .iteration(let ctx):
            if ctx.discoveredNewCoverage {
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
    makeHandlers: { [.corpusMutation(), loggingHandler] }
) { (input: String) in
    parse(input)
}
```

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

## API Reference

### Fuzzing

| Function | Description |
|----------|-------------|
| `fuzz(seeds:duration:corpusMode:test:)` | Coverage-guided fuzz testing (infers mutators from `MutatorProviding`) |
| `fuzz(using:seeds:duration:corpusMode:test:)` | Fuzz testing with explicit mutators |

### Core Types

| Type | Description |
|------|-------------|
| `MutatorProviding` | Protocol for types that provide a default `Mutator` |
| `Mutator<Value>` | Composable mutation strategy (seeds + mutate + generate) |
| `FuzzResult` | Result of a fuzz run with corpus and stats |
| `CorpusMode` | Controls corpus behavior (`.auto`, `.refuzzReplace`, `.refuzzExtend`, `.regressionOnly`) |
| `FuzzPluginHandler` | Plugin handler with sync/async event processing |

### Built-in Plugin Handlers

| Handler | Description |
|---------|-------------|
| `.corpusMutation()` | AFL-style corpus mutation (default) |
| `.energyMutation()` | Entropic energy-based mutation selection |
| `.shrinking()` | Delta-debugging failure shrinking |
| `.plateauDetector()` | Stops when coverage discovery plateaus |
| `.stadsDetector()` | Statistical stopping (STADS) |
| `.saturationDetector()` | Stops when coverage growth saturates |
| `.coverageGap()` | Reports partially-covered functions |

## How It Works

PropertyTestingKit uses SanitizerCoverage with custom task-based isolation:

1. **Edge Instrumentation**: Uses `-sanitize-coverage=edge` which inserts `__sanitizer_cov_trace_pc_guard` callbacks at every branch
2. **Task-Keyed Isolation**: Coverage maps are keyed by `swift_task_getCurrent()`, providing true per-task isolation even when Swift Testing runs tasks on shared threads
3. **Source Mapping**: DWARF debug info is parsed via LLVM to map program counters to file:line locations
4. **Corpus Management**: Saves inputs that discover new coverage, replays them on subsequent runs

The fuzzer follows an AFL-inspired approach:
- Seeds with boundary values from `MutatorProviding.defaultMutator`
- Captures coverage signature for each input
- Adds inputs with new signatures to the corpus
- Mutates corpus entries to discover more paths
- Minimizes corpus to smallest set covering all paths

## License

Apache 2.0 License. See [LICENSE](LICENSE) for details.

## Acknowledgments

### Research

- **Miller et al. 1990** - ["An Empirical Study of the Reliability of UNIX Utilities"](https://pages.cs.wisc.edu/~bart/fuzz/fuzz.html) - The original fuzz testing paper that introduced random input testing and timeout-based hang detection
- **Zalewski (AFL)** - [American Fuzzy Lop](https://lcamtuf.coredump.cx/afl/) - Coverage-guided fuzzing techniques and corpus management strategies
- **Elhage 2020** - ["Property Testing Like AFL"](https://blog.nelhage.com/post/property-testing-like-afl/) - Workflow combining property testing with coverage-guided fuzzing, including stopping when coverage stops improving

### Libraries

- **[ConcurrencyKit](https://github.com/concurrencykit/ck)** - Lock-free hash table (`ck_ht`) used for task-keyed coverage maps, enabling high-throughput concurrent fuzzing
- Uses **SanitizerCoverage** (`__sanitizer_cov_trace_pc_guard`) for edge instrumentation with custom task-keyed isolation via `swift_task_getCurrent()`
- **LLVM** for DWARF-based source symbolication (mapping PCs to file:line locations)
