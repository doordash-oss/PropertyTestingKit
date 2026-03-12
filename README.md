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

@Test func testDatabaseQuery() throws {
    try fuzz(seeds: [
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
1. Starts with seed values (yours + type defaults from `Fuzzable.fuzz`)
2. Runs each input and captures coverage
3. Inputs that hit new code paths are saved to the corpus
4. Mutates interesting inputs to discover more paths
5. Stops when time or iteration limits are reached
6. Saves minimal corpus to disk for future runs

**On subsequent runs:**
- Replays saved corpus to verify coverage unchanged
- If coverage differs (code changed), automatically re-fuzzes

### Corpus Storage

The corpus is saved alongside your test files:

```
Tests/
  MyTests/
    Fuzzing/
      ParserTests.swift
      Corpus/                    # Created automatically
        testParser/
          corpus.json            # Saved inputs + coverage signatures
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
@Test func testParser() throws {
    // Force re-fuzzing even if corpus exists
    try fuzz(corpusMode: .refuzzReplace) { (input: String) in
        parse(input)
    }
}

@Test func testExtendCorpus() throws {
    // Build on existing corpus
    try fuzz(corpusMode: .refuzzExtend, iterations: 50_000) { (input: String) in
        parse(input)
    }
}
```

**Suite-level control via environment:**

```bash
# Re-fuzz all tests, replacing existing corpora
FUZZ_CORPUS_MODE=refuzzreplace swift test

# Extend existing corpora with more fuzzing
FUZZ_CORPUS_MODE=refuzzextend FUZZ_ITERATIONS=50000 swift test

# CI mode: only run regression tests (fast, deterministic)
FUZZ_CORPUS_MODE=regressiononly swift test
```

### Custom Seeds

Provide domain-specific seeds to guide the fuzzer toward edge cases:

```swift
@Test func testNumberParser() throws {
    try fuzz(seeds: [
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

Use domain-specific mutation strategies instead of the default `Fuzzable` conformance:

```swift
@Test func testInputValidation() throws {
    // Single mutator with multiple strategies
    try fuzz(using: String.mutators(.sql, .xss)) { input in
        let sanitized = sanitize(input)
        #expect(!sanitized.contains("DROP TABLE"))
        #expect(!sanitized.contains("<script>"))
    }
}

@Test func testAPIEndpoint() throws {
    // Multiple mutators for multiple inputs
    try fuzz(
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
try fuzz(using: Bool.mutator()) { flag in ... }
```

Strategies can be composed - mutations from all strategies are applied to seeds from all strategies, enabling cross-strategy fuzzing (e.g., SQL mutations applied to XSS seeds).

### Fuzzable Protocol

Types conforming to `Fuzzable` provide default seed values and mutation strategies:

```swift
extension String: Fuzzable {
    public static var fuzz: [String] {
        ["", "a", "hello", "hello world", String(repeating: "x", count: 1000)]
    }

    public func mutate() -> [String] {
        // Return variations of self
    }
}
```

Built-in `Fuzzable` conformances: `Bool`, `Int`, `String`, `Optional`, `Array`

When no custom mutators are provided to `fuzz()`, it uses the type's `Fuzzable` conformance.

### @Fuzzable Macro

Generate fuzz values for custom types via cartesian product:

```swift
@Fuzzable
struct Config {
    let retries: Int      // Uses Int.fuzz
    let timeout: Double   // Uses Double.fuzz
    let enabled: Bool     // Uses Bool.fuzz
}

// Config.fuzz generates all combinations automatically
@Test func testAllConfigs() throws {
    try fuzz { config in
        MyService(config: config).validate()
    }
}
```

### Configuration

```swift
try fuzz(
    seeds: [...],           // Domain-specific seed values
    iterations: 10_000,     // Max fuzzing iterations (default: 10,000)
    duration: 60            // Max time in seconds (default: 60)
) { input in
    // test
}
```

Environment variables:
- `FUZZ_VERBOSE=1` - Enable detailed logging
- `FUZZ_ITERATIONS=N` - Override max iterations
- `FUZZ_DURATION=N` - Override max duration
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
  - Unique coverage paths: 23
  - Stop reason: iteration_limit
```

The failure includes:
- **Failing input**: The exact input that caused the failure (JSON-formatted for complex types)
- **Error**: The error that was thrown
- **Fuzz run stats**: Context about the fuzzing session

To reproduce the failure, the failing input is automatically saved to the corpus and will be replayed on subsequent test runs.

### Hang Detection

Detect infinite loops or deadlocks with per-input timeouts:

```swift
@Test func testParser() throws {
    try fuzz(
        perInputTimeout: 1.0  // 1 second timeout per input
    ) { (input: String) in
        parse(input)  // Will be interrupted if it takes > 1s
    }
}
```

When a hang is detected:
- The input is recorded as a "hang" (separate from failures)
- The test continues with other inputs
- Stats include both failure and hang counts

### Coverage Gap Detection

Find functions with incomplete test coverage using the coverage gap analysis plugin:

```swift
@Test func testParser() throws {
    try fuzz(
        analysisPlugins: [.coverageGaps()]
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

The fuzzer supports a plugin system for customizing behavior. Plugins are grouped into three categories:

#### Observer Plugins

Receive lifecycle notifications during fuzzing (read-only, don't influence behavior):

```swift
try fuzz(
    observerPlugins: [MyLoggingPlugin()]
) { input in ... }
```

Observer plugins implement `FuzzObserverPlugin` and receive callbacks for:
- `onStart(context:)` - Fuzzing started
- `onIteration(context:)` - Each iteration completed
- `onBatchComplete(context:)` - Batch of mutations completed
- `onEnd(context:)` - Fuzzing ended

#### Stopping Condition Plugins

Control when fuzzing should stop:

```swift
// Default: only iteration/time limits apply
try fuzz { input in ... }

// Enable plateau detection (stops when no new coverage is found)
try fuzz(stoppingPlugins: [.plateauDetector()]) { input in ... }

// Custom plateau detection configuration
try fuzz(
    stoppingPlugins: [.plateauDetector(windowSize: 200, minDiscoveryRate: 0.01)]
) { input in ... }
```

#### Analysis Plugins

Run after fuzzing completes to analyze results:

```swift
try fuzz(
    analysisPlugins: [.coverageGaps()]
) { input in ... }
```

#### Built-in Plugins

| Plugin | Type | Description |
|--------|------|-------------|
| `PlateauDetectorPlugin` | Stopping | Stops fuzzing when coverage discovery rate drops below threshold. |
| `CoverageGapPlugin` | Analysis | Detects partially-covered functions and reports uncovered regions. |

**Plateau Detector Configuration:**

```swift
.plateauDetector(
    windowSize: 100,        // Iterations per window (default: maxIterations/10)
    minDiscoveryRate: 0.001, // Stop if rate drops below this (default: 0.001)
    confirmationWindows: 3   // Consecutive low windows before stopping (default: 3)
)
```

**Coverage Gap Configuration:**

```swift
.coverageGaps(
    minCoveragePercentage: 5.0,  // Only report functions with >5% coverage
    excludedPathPrefixes: [],     // Paths to exclude from analysis
    onlyReportSignificant: true   // Filter to significant gaps only
)
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
| `fuzz(seeds:iterations:duration:corpusMode:test:)` | Coverage-guided fuzz testing |
| `fuzz(using:seeds:iterations:duration:corpusMode:test:)` | Fuzz testing with custom mutators |

### Fuzzing Types

| Type | Description |
|------|-------------|
| `Fuzzable` | Protocol for types that can be fuzzed |
| `FuzzResult` | Result of a fuzz run with corpus and stats |
| `Corpus` | Collection of interesting inputs with coverage signatures |
| `CorpusMode` | Controls corpus behavior (`.auto`, `.refuzzReplace`, `.refuzzExtend`, `.regressionOnly`) |

### Plugin Protocols

| Protocol | Description |
|----------|-------------|
| `FuzzObserverPlugin` | Receives lifecycle notifications (start, iteration, batch, end) |
| `StoppingConditionPlugin` | Determines when fuzzing should stop |
| `AnalysisPlugin` | Runs post-fuzzing analysis and generates reports |

### Built-in Plugins

| Plugin | Description |
|--------|-------------|
| `.plateauDetector()` | Stops when coverage discovery plateaus |
| `.coverageGaps()` | Detects functions with incomplete coverage |

### Macros

| Macro | Description |
|-------|-------------|
| `@Fuzzable` | Generate `fuzz` property via cartesian product |

## How It Works

PropertyTestingKit uses SanitizerCoverage with custom task-based isolation:

1. **Edge Instrumentation**: Uses `-sanitize-coverage=edge` which inserts `__sanitizer_cov_trace_pc_guard` callbacks at every branch
2. **Task-Keyed Isolation**: Coverage maps are keyed by `swift_task_getCurrent()`, providing true per-task isolation even when Swift Testing runs tasks on shared threads
3. **Source Mapping**: DWARF debug info is parsed via LLVM to map program counters to file:line locations
4. **Corpus Management**: Saves inputs that discover new coverage, replays them on subsequent runs

The fuzzer follows an AFL-inspired approach:
- Seeds with boundary values from `Fuzzable.fuzz`
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
