# PropertyTestingKit

Coverage-guided fuzz testing for Swift.

## Overview

PropertyTestingKit brings coverage-guided fuzzing to Swift Testing:

- **Coverage-guided fuzzing** - Automatically discover inputs that exercise new code paths
- **Corpus persistence** - Save and replay interesting inputs across test runs
- **Regression detection** - Automatically re-fuzz when code changes affect coverage
- **Variadic inputs** - Fuzz functions with multiple parameters

## Requirements

- macOS 15.0+ / iOS 18.0+
- Swift 6.0+
- Xcode 16.0+

## Installation

### Swift Package Manager

Add PropertyTestingKit to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_ORG/PropertyTestingKit.git", from: "1.0.0"),
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
5. Stops when coverage plateaus or limits are reached
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
    try fuzz { (config: Config) in
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

### Building with Coverage

Coverage instrumentation must be enabled:

```bash
swift test --enable-code-coverage
```

## Additional Features

### Measure Coverage

The simplest way to see what code a test exercises:

```swift
import PropertyTestingKit

@Test func testUserCreation() throws {
    let (result, coverage) = try measureSourceCoverage {
        UserService().createUser(id: "123", name: "Alice")
    }

    #expect(result == true)

    // See exactly what executed
    for region in coverage.executedRegions {
        print("\(region.filename):\(region.lineStart) - \(region.executionCount)x")
    }
}
```

### Counter-Level Coverage

For lightweight coverage detection without source mapping:

```swift
import PropertyTestingKit

@Test func testCodePathA() {
    let diff = measureCoverage {
        myFunction(usePathA: true)
    }

    print("Executed \(diff?.executedRegions ?? 0) new code regions")
}
```

### Coverage Trait for Test Suites

Apply the `.coverage` trait to generate per-test profraw files:

```swift
import Testing
import PropertyTestingKit

@Suite(.serialized, .coverage)
struct MyFeatureTests {
    @Test func testFeatureA() { ... }
    @Test func testFeatureB() { ... }
}
```

> **Note:** Use `.serialized` with `.coverage` because LLVM profile counters are global state.

Run with coverage enabled:

```bash
swift test --enable-code-coverage
```

### Source-Level Coverage API

Get detailed coverage with file and line information:

```swift
let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
let coverage = reader.resolveCoverage()

for function in coverage.functions {
    print("\(function.name): \(function.executionCount) executions")

    for region in function.regions {
        print("  \(region.filename):\(region.lineStart)-\(region.lineEnd)")
        print("  Executed: \(region.executionCount)x")
    }
}
```

### Filtering Coverage

Focus on your project's code, excluding dependencies:

```swift
let (_, coverage) = try measureSourceCoverage {
    myFunction()
}

// Already filtered by default - excludes /usr, /System, .build/checkouts/, etc.
print("Project functions: \(coverage.functions.count)")

// Or include everything
let (_, fullCoverage) = try measureSourceCoverage(includeAllFiles: true) {
    myFunction()
}
```

## API Reference

### Fuzzing

| Function | Description |
|----------|-------------|
| `fuzz(seeds:iterations:duration:test:)` | Coverage-guided fuzz testing |

### Fuzzing Types

| Type | Description |
|------|-------------|
| `Fuzzable` | Protocol for types that can be fuzzed |
| `FuzzResult` | Result of a fuzz run with corpus and stats |
| `Corpus` | Collection of interesting inputs with coverage signatures |

### Coverage Measurement

| Function | Description |
|----------|-------------|
| `measureCoverage(_:)` | Lightweight counter-level diff |
| `measureSourceCoverage(_:)` | Full source-level coverage with file/line info |

### Macros

| Macro | Description |
|-------|-------------|
| `@Fuzzable` | Generate `fuzz` property via cartesian product |

## How It Works

PropertyTestingKit uses LLVM's coverage instrumentation directly:

1. **Counter Access**: Reads LLVM's in-memory coverage counters via `__llvm_profile_*` runtime functions
2. **Coverage Mapping**: Parses `__llvm_covmap` sections from the binary to map counters to source locations
3. **Difference-Based**: Snapshots counters before/after code execution to isolate what each test exercises
4. **Corpus Management**: Saves inputs that discover new coverage, replays them on subsequent runs

The fuzzer follows an AFL-inspired approach:
- Seeds with boundary values from `Fuzzable.fuzz`
- Captures coverage signature for each input
- Adds inputs with new signatures to the corpus
- Mutates corpus entries to discover more paths
- Minimizes corpus to smallest set covering all paths

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- Uses [LLVMCoverageKit](https://github.com/alex-reilly-dd/LLVMCoverageKit) for coverage mapping parsing
- Built on LLVM's coverage infrastructure
