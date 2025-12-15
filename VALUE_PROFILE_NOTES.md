# Value Profile Guidance Implementation Notes

## Overview

Value profile guidance helps the fuzzer crack "magic number" comparisons by tracking how close inputs get to satisfying comparisons, not just which branches are taken.

**Example:** For `if (x == 12345)`, branch coverage only tells us "taken" or "not taken". Value profile guidance tells us the distance between `x` and `12345`, allowing targeted mutations.

---

## Compiler Flags

Enable with `-sanitize=undefined -sanitize-coverage=trace-cmp`:

```bash
swift build -Xswiftc -sanitize=undefined -Xswiftc -sanitize-coverage=trace-cmp
```

This instruments all integer comparisons (`icmp` instructions) to call hooks with both operands.

---

## Architecture

```
┌─────────────────┐    Instrumented     ┌──────────────────────┐
│  Test Function  │ ───comparisons────> │  ValueProfileHooks.c │
│   if (x == 42)  │                     │  (C hooks capture    │
└─────────────────┘                     │   operands)          │
                                        └──────────────────────┘
                                                  │
                                                  ▼
                                        ┌──────────────────────┐
                                        │  ValueProfile.swift  │
                                        │  (Swift tracker,     │
                                        │   target extraction) │
                                        └──────────────────────┘
                                                  │
                                                  ▼
                                        ┌──────────────────────┐
                                        │   FuzzEngine.swift   │
                                        │  (Priority chaining, │
                                        │   targeted mutation) │
                                        └──────────────────────┘
```

---

## C Hooks (ValueProfileHooks.c)

LLVM calls these hooks for each comparison when `-sanitize-coverage=trace-cmp` is enabled:

| Hook | Called For |
|------|------------|
| `__sanitizer_cov_trace_const_cmp{1,2,4,8}` | Comparisons with compile-time constants (magic numbers) |
| `__sanitizer_cov_trace_cmp{1,2,4,8}` | Comparisons between two runtime values |
| `__sanitizer_cov_trace_switch` | Switch statements |

**Storage:** Thread-local array of up to 4096 `VPComparisonRecord` entries per test execution.

**Record fields:**
- `pc` - Return address (identifies which comparison)
- `arg1` - First operand (constant if `is_const`)
- `arg2` - Second operand (runtime value)
- `distance` - `abs(arg1 - arg2)`
- `size` - Comparison size in bytes
- `is_const` - Whether one operand was a compile-time constant

---

## Swift Tracker (ValueProfile.swift)

### ComparisonRecord

Swift representation of captured comparison with bucketed distance (AFL-style):

```swift
public var bucketedDistance: UInt8 {
    switch distance {
    case 0: return 0      // Solved!
    case 1: return 1
    case 2: return 2
    case 3: return 3
    case 4...7: return 4
    case 8...15: return 5
    case 16...31: return 6
    case 32...127: return 7
    default: return 8     // Far away
    }
}
```

### ValueProfileTracker

Tracks minimum distances seen per (location, constant) pair:

```swift
private var minimumDistances: [LocationKey: UInt64] = [:]

struct LocationKey: Hashable {
    let pc: UInt64
    let constantValue: UInt64
}
```

**Key methods:**

- `enable()` / `disable()` - Control hook recording
- `reset()` - Clear comparison log before each test
- `processComparisons()` - Returns comparisons that made progress (got closer)
- `extractTargets()` - Returns unsolved `ComparisonTarget`s for targeted mutation
- `stats()` - Returns `(trackedLocations, solvedComparisons)`

---

## Targeted Mutation Strategies

### ComparisonTarget

Represents a comparison we're trying to satisfy:

```swift
public struct ComparisonTarget: Hashable {
    public let target: UInt64   // The magic number
    public let current: UInt64  // Current input value
    public let isSigned: Bool
}
```

### 1. Binary Search Mutations

For `x == 12345`, generate values that narrow the gap:

```swift
func binarySearchMutations() -> [Int] {
    // Direct target: [12345, 12344, 12346]
    // Midpoints: [(current + target) / 2]
    // Quarter points for faster convergence
}
```

### 2. Modulo-Aware Mutations

For constraints like `(a + b) % 1000 == 777`:

```swift
func moduloAwareMutations() -> [Int] {
    // Generate target + k*modulus for common moduli
    // [10, 100, 256, 1000, 1024, 10000, 65536, 100000]
    // Returns: [777, 1777, 2777, -223, ...]
}
```

### 3. Pair Mutations

For multi-value constraints like `a + b == target`:

```swift
func pairMutations(otherValue: Int) -> [Int] {
    // For a + b == target: return target - otherValue
    // Also tries modular arithmetic variations
}
```

---

## Priority Chaining (FuzzEngine.swift)

**Problem:** When input A makes progress on comparison 1 (e.g., gets `x` closer to 111), we need to continue mutating A to solve comparisons 2 and 3 (getting `y` to 222, `z` to 333).

**Solution:** Priority chaining tracks which corpus entry made progress and prioritizes it for the next mutation round.

```swift
/// Index of corpus entry that most recently made value profile progress.
private var priorityMutationIndex: Int?

/// Saved targets from the test that made value profile progress.
private var savedTargets: [ValueProfileTracker.ComparisonTarget] = []
```

### Flow

1. **On VP progress:** Save the corpus entry index and extract targets
   ```swift
   } else if !vpImprovements.isEmpty {
       corpus.add(input: repeat each input, signature: signature, parentIndex: parentIndex)
       priorityMutationIndex = corpus.count - 1
       savedTargets = valueProfileTracker.extractTargets()
   }
   ```

2. **On next mutation:** Use priority entry and saved targets
   ```swift
   if let priorityIdx = priorityMutationIndex, priorityIdx < corpus.count {
       selectedIndex = priorityIdx
       usingPriority = true
       let targets = savedTargets  // Use saved targets, not fresh extraction
   }
   ```

3. **Generate targeted mutations:** Use the saved targets
   ```swift
   if usingPriority && !targetMutations.isEmpty {
       mutated = targetMutations.randomElement()!
       if targetMutations.count <= 1 {
           priorityMutationIndex = nil  // Clear when exhausted
           savedTargets = []
       }
   }
   ```

---

## Test Cases Solved

### Single Magic Number
```swift
func hardToGuess(_ x: Int) -> String {
    if x == 12345 { return "magic" }
    return "normal"
}
// Solved: binary search mutations find 12345 quickly
```

### Three-Value Sequence
```swift
func extremeSequence(_ a: Int, _ b: Int, _ c: Int) -> String {
    if a == 111 && b == 222 && c == 333 { return "sequence" }
    return "no-match"
}
// Solved: priority chaining solves a=111, then b=222, then c=333
```

### Modulo Sum Constraint
```swift
func veryHardModuloSum(_ a: Int, _ b: Int) -> String {
    let remainder = (a &+ b) % 1000
    if remainder == 777 { return "modulo-match" }
    return "modulo-mismatch"
}
// Solved: modulo-aware mutations + pair mutations find (a, b) where a+b ≡ 777 (mod 1000)
```

---

## Limitations

### What Works
- Integer comparisons (`==`, `<`, `>`, etc.)
- Switch statements
- Multi-value constraints (with priority chaining)
- Modulo constraints (with modulo-aware mutations)

### What Doesn't Work
- **String comparisons** - Swift's `String.==` is a function call, not an `icmp` instruction
- **Floating-point** - Not instrumented by `-sanitize-coverage=trace-cmp`
- **Custom equality** - Overloaded `==` operators that don't compile to `icmp`

---

## String Comparison Approaches

Since LLVM's trace-cmp only instruments primitive integer comparisons, Swift strings require alternative approaches:

| Approach | How it Works | Effort | Invasiveness |
|----------|--------------|--------|--------------|
| **TrackedString wrapper** | Wrapper type intercepts `==`, `hasPrefix`, etc. | Done (POC) | Function signatures |
| **Swift macro** | `@FuzzableStrings` transforms comparisons at compile time | Medium | Annotation only |
| **libFuzzer weak hooks** | `__sanitizer_weak_hook_strcmp` for C strings | Low | None (but doesn't work for Swift strings) |
| **User dictionary** | User provides known magic strings | Low | Manual |
| **Character-by-character** | Brute-force discovery | High runtime | None |

The **TrackedString wrapper** POC was successfully implemented at `/tmp/string_hook_poc/`. It captures all string comparisons with both operands and tracks distances.

---

---

## String Allocation Hooks (Implemented)

Since LLVM's trace-cmp doesn't instrument Swift string comparisons, we implemented runtime string capture using fishhook.

### How It Works

1. **fishhook** rebinds Swift's `_builtinStringLiteral` initializer at runtime
2. Every string literal creation is intercepted and recorded
3. Captured strings are used as mutation candidates for String inputs

### Architecture

```
┌─────────────────┐     fishhook      ┌──────────────────────┐
│ Swift runtime   │ ────rebind────>   │ StringAllocationHooks│
│ _builtinString  │                   │ (C, captures strings)│
│ Literal         │                   └──────────────────────┘
└─────────────────┘                             │
                                                ▼
                                      ┌──────────────────────┐
                                      │  StringDictionary    │
                                      │  (Swift wrapper)     │
                                      └──────────────────────┘
                                                │
                                                ▼
                                      ┌──────────────────────┐
                                      │   FuzzEngine         │
                                      │ stringDictionary     │
                                      │ Mutations()          │
                                      └──────────────────────┘
```

### Files

- `Sources/StringAllocationHooks/StringAllocationHooks.c` - C hooks using fishhook
- `Sources/StringAllocationHooks/fishhook.c` - Facebook's fishhook library
- `Sources/PropertyTestingKit/Fuzzing/StringDictionary.swift` - Swift wrapper
- Integration in `FuzzEngine.swift` - Capture during tests, use in mutations

### Usage

Enabled by default via `FuzzEngine.Config.enableStringCapture`:

```swift
let config = FuzzEngine.Config(enableStringCapture: true)
```

The fuzzer automatically:
1. Starts capture before each test
2. Stops and accumulates after each test
3. Uses captured strings for String component mutations

### Mutation Strategies

For String inputs, the fuzzer tries:
1. **Direct substitution** - Replace with captured dictionary strings
2. **Related strings** - Strings with similar prefixes
3. **Concatenation** - `candidate + current` and `current + candidate`

### Test Results

| Test Case | Strings to Find | Result |
|-----------|-----------------|--------|
| `"admin_root"` (10 chars) | admin, _root | ✅ Found via concatenation |
| `"token_2024_secret"` (18 chars) | token_, 2024, _secret | ❌ Needs 3-way concat |

### Limitations

1. **Large strings** - Only captures creation, not heap buffer contents
2. **Multi-part concatenation** - Current mutations only do 2-way combinations
3. **Darwin only** - fishhook uses Mach-O, not portable to Linux

---

## Future Work

- [ ] Add 3-way concatenation mutations for multi-part strings
- [ ] Explore hooking String.+ operator for concatenation results
- [ ] Add floating-point comparison hooks (would need custom instrumentation)
- [ ] Consider Linux support via different hooking mechanism
