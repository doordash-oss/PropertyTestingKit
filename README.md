# PropertyTestingKit

Per-test code coverage and property-based testing utilities for Swift Testing.

## Overview

PropertyTestingKit provides tools for understanding exactly what code your tests exercise:

- **Per-test coverage** - Measure which code paths each individual test executes
- **In-memory coverage** - Zero-overhead coverage tracking without file I/O
- **Source-level detail** - Get file names, line numbers, and execution counts
- **`@Fuzzable` macro** - Generate test inputs via cartesian product

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

### Quick Start: Measure Coverage

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

### @Fuzzable Macro

Generate all combinations of test inputs:

```swift
import PropertyTestingKit

@Fuzzable
struct TestInput {
    let enabled: Bool
    let mode: Mode
}

enum Mode: CaseIterable {
    case fast, slow
}

extension Bool {
    static var fuzz: [Bool] { [true, false] }
}

extension Mode {
    static var fuzz: [Mode] { Mode.allCases }
}

// TestInput.fuzz generates:
// [TestInput(enabled: true, mode: .fast),
//  TestInput(enabled: true, mode: .slow),
//  TestInput(enabled: false, mode: .fast),
//  TestInput(enabled: false, mode: .slow)]

@Test(arguments: TestInput.fuzz)
func testAllCombinations(input: TestInput) {
    // Test each combination
}
```

## API Reference

### Coverage Measurement

| Function | Description |
|----------|-------------|
| `measureCoverage(_:)` | Lightweight counter-level diff |
| `measureSourceCoverage(_:)` | Full source-level coverage with file/line info |
| `CoverageCounters.snapshot()` | Capture raw counter state |

### Coverage Data Types

| Type | Description |
|------|-------------|
| `ResolvedCoverage` | Source-level coverage for all functions |
| `ResolvedFunctionCoverage` | Coverage for a single function |
| `ResolvedRegionCoverage` | Coverage for a source region (line range) |
| `CounterDiff` | Difference between two counter snapshots |

### Traits

| Trait | Description |
|-------|-------------|
| `.coverage` | Generate per-test profraw files |

### Macros

| Macro | Description |
|-------|-------------|
| `@Fuzzable` | Generate `fuzz` property via cartesian product |

## How It Works

PropertyTestingKit uses LLVM's coverage instrumentation directly:

1. **Counter Access**: Reads LLVM's in-memory coverage counters via `__llvm_profile_*` runtime functions
2. **Coverage Mapping**: Parses `__llvm_covmap` sections from the binary to map counters to source locations
3. **Difference-Based**: Snapshots counters before/after code execution to isolate what each test exercises
4. **No File I/O**: Operates entirely in-memory for minimal overhead

This approach:
- Doesn't interfere with Xcode's coverage tooling
- Works with Swift Testing's parallel execution (when using `.serialized`)
- Provides instant results without profdata merging

## Building with Coverage

Coverage instrumentation must be enabled at build time:

```bash
# Command line
swift test --enable-code-coverage

# Or in Xcode
# Edit Scheme → Test → Options → Code Coverage ✓
```

Check if coverage is available at runtime:

```swift
if CoverageTrait.isAvailable {
    print("Coverage instrumentation is enabled")
}
```

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- Uses [LLVMCoverageKit](https://github.com/alex-reilly-dd/LLVMCoverageKit) for coverage mapping parsing
- Built on LLVM's coverage infrastructure
