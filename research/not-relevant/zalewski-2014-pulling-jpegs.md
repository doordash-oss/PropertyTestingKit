# Pulling JPEGs Out of Thin Air (2014)

**Author:** Michal Zalewski (lcamtuf)
**Source:** https://lcamtuf.blogspot.com/2014/11/pulling-jpegs-out-of-thin-air.html
**Date:** November 2014
**Tool:** American Fuzzy Lop (AFL)

---

## Summary

Zalewski's famous blog post demonstrates AFL's remarkable capability to synthesize valid JPEG files from minimal seed inputs through coverage-guided fuzzing alone. Starting with a trivial 5-byte input containing just the string "hello", AFL successfully generated a valid JPEG image after approximately six hours on an 8-core system, without any prior knowledge of the JPEG file format specification.

The demonstration illustrates the power of coverage-guided fuzzing as an emergent property discovery mechanism. AFL's lightweight assembly-level instrumentation detected when mutations produced different internal behavior in the `djpeg` decoder. When the fuzzer set the first byte to `0xff`, it observed different code paths being executed, recognized this as progress, and preserved this mutation as a seed for subsequent generations. Through iterative mutation and selection guided purely by code coverage feedback, AFL progressively discovered the JPEG format's structural requirements: header identification (`0xff` marker), format markers (`0xd8` byte), control structures including SOF (Start of Frame), Huffman tables, quantization tables, SOS (Start of Scan) markers, and ultimately valid file structure.

The first successfully generated image was a minimal 3x784 pixel grayscale image, which then served as a seed for producing increasingly complex variations. Zalewski also demonstrated that this format-agnostic approach worked across multiple file types including bash scripts, GIFs, ELF executables, and UTF-8 files. The key limitation identified was that AFL struggles with atomically-executed checks involving large search spaces, such as magic password comparisons (e.g., `if strcmp(input, "SecretPassword123") == 0`), which prevented successful PNG generation or complex HTML synthesis from scratch.

---

## Key Strategies/Techniques

1. **Coverage-Guided Mutation Selection**
   - AFL instruments target binaries at the assembly level to detect code path changes
   - Mutations that trigger new code paths are preserved as corpus seeds
   - Coverage feedback acts as a fitness function without requiring format knowledge

2. **Progressive Structure Discovery**
   - Format requirements emerge through iterative refinement
   - Each successful mutation builds on previous discoveries
   - Complex structures are discovered hierarchically (header → markers → control structures → data)

3. **Lightweight Instrumentation**
   - Assembly-level branch instrumentation with minimal performance overhead
   - Enables fast iteration through millions of test cases
   - No heavyweight symbolic execution or constraint solving required

4. **Format-Agnostic Approach**
   - No format specifications or grammars required
   - Works across diverse file types (JPEG, GIF, ELF, bash scripts)
   - Purely driven by observable program behavior under test

5. **Corpus-Based Evolution**
   - Interesting inputs (those triggering new coverage) become seeds
   - Mutations are applied to corpus entries, not random data
   - Corpus quality improves over time as better seeds are discovered

6. **Bucketed Hit Counts**
   - AFL uses bucketed execution counts (1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+)
   - Stabilizes coverage signatures despite minor loop iteration variations
   - Distinguishes "ran once" from "ran many times" without infinite granularity

---

## Applicability to PropertyTestingKit

### High Relevance: Core Mechanisms Already Implemented

PropertyTestingKit already implements the foundational techniques that enabled AFL's JPEG synthesis:

1. **Coverage-Guided Fuzzing** ✅
   - PropertyTestingKit uses Swift's SanitizerCoverage instrumentation for branch tracking
   - `CoverageSignature` implements AFL-style bucketed hit counts (identical categories: 0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+)
   - Coverage feedback guides corpus selection and mutation prioritization

2. **Corpus Management** ✅
   - `Corpus<Input>` tracks entries with their coverage signatures
   - `addIfInteresting()` preserves only inputs that contribute unique coverage
   - Energy-based scheduling (`selectForMutation()`) prioritizes entries covering rare code paths
   - Corpus minimization reduces to smallest set covering all paths

3. **Structured Mutation** ✅
   - `Fuzzable` protocol provides domain-specific mutations (vs. AFL's byte-level)
   - `Mutator` protocol enables composable mutation strategies
   - Type-aware mutations preserve validity (e.g., mutating `Int` produces valid `Int`)

4. **Value Profile Guidance** ✅
   - Already implemented via `-sanitize-coverage=trace-cmp` hooks
   - Tracks comparison distances to guide mutations toward magic numbers
   - Priority chaining solves multi-constraint problems (e.g., `a == 111 && b == 222 && c == 333`)

### Moderate Relevance: Techniques Partially Applicable

1. **Format Discovery Through Fuzzing**
   - **Zalewski's approach:** Byte-level mutations discover binary format structure
   - **PropertyTestingKit's context:** Targets Swift code with structured inputs (not binary parsers)
   - **Applicability:** Limited direct applicability—Swift Testing primarily exercises application logic rather than binary format parsers
   - **Potential use case:** If testing Swift binary parsers (e.g., custom image decoders, network protocol implementations), PropertyTestingKit could discover format requirements similarly

2. **Minimal Seed Requirements**
   - **Zalewski's demonstration:** Started with arbitrary "hello" string
   - **PropertyTestingKit's design:** `Fuzzable` protocol requires thoughtful seed values in `fuzz` property
   - **Trade-off:** PropertyTestingKit uses structured seeds (e.g., `Int.fuzz` includes boundary values like 0, -1, Int.max) for faster convergence on Swift logic
   - **Assessment:** PropertyTestingKit's structured approach is more appropriate for Swift Testing scenarios than pure byte-level fuzzing from arbitrary seeds

3. **Assembly-Level Instrumentation Overhead**
   - **AFL's advantage:** Minimal overhead via assembly instrumentation
   - **PropertyTestingKit's overhead:** Swift SanitizerCoverage has higher overhead than AFL's custom instrumentation
   - **Constraint:** Cannot modify Swift compiler without significant engineering effort
   - **Mitigation:** Already uses SanitizerCoverage as best available Swift instrumentation

### Low Relevance: Techniques Not Directly Applicable

1. **Binary File Format Synthesis**
   - PropertyTestingKit targets Swift code logic, not binary format synthesis
   - Swift Testing scenarios rarely involve generating valid file formats from scratch
   - Most PropertyTestingKit use cases involve testing business logic with structured data types

2. **Large Search Space Magic Values**
   - Zalewski identifies this as AFL's limitation (preventing PNG generation)
   - PropertyTestingKit already addresses this limitation via value profile guidance
   - String dictionary capture (using fishhook) provides magic string discovery
   - PropertyTestingKit's hybrid approach (structured mutations + value profile) handles cases AFL couldn't solve

---

## Concrete Recommendations

### 1. No Major Architectural Changes Needed

PropertyTestingKit already implements the core techniques that made AFL's JPEG synthesis successful. The existing architecture (coverage-guided corpus management, bucketed signatures, structured mutation) is well-suited to Swift Testing scenarios.

### 2. Consider Binary Parser Testing Use Cases

If there's interest in supporting Swift binary parser testing (e.g., custom image decoders, network protocol handlers, file format parsers), consider:

- **Add `Data` / `[UInt8]` fuzzing support:** Implement byte-level mutations similar to AFL
- **Byte-level mutators:** Bit flips, byte insertions/deletions, block replacements
- **Dictionary-based mutations:** Extract constants from target binary and use as mutation sources
- **Format discovery benchmarks:** Create test suite demonstrating format discovery capabilities

**Implementation sketch:**
```swift
extension Data: Fuzzable {
    public static var fuzz: [Data] {
        [
            Data(),                          // Empty
            Data([0xff]),                    // Single byte
            Data([0xff, 0xd8]),              // JPEG header
            Data(repeating: 0, count: 256),  // Block of zeros
            Data((0..<256).map { UInt8($0) }) // All byte values
        ]
    }

    public func mutate() -> [Data] {
        var mutations: [Data] = []

        // Bit flips
        for i in indices {
            var copy = self
            copy[i] ^= 1 << Int.random(in: 0..<8)
            mutations.append(copy)
        }

        // Byte insertions
        mutations.append(self + Data([UInt8.random(in: 0...255)]))

        // Byte deletions
        if !isEmpty {
            mutations.append(Data(dropLast()))
        }

        // Block replacements (dictionary-based)
        // Use constants extracted from target binary

        return mutations
    }
}
```

### 3. Document Format Discovery Capabilities

Even without binary parser-specific features, PropertyTestingKit can demonstrate emergent behavior discovery:

- **Add examples:** Show how fuzzing discovers input structure requirements in Swift code
- **Comparison to AFL:** Document how structured mutations achieve similar goals
- **Blog post/case study:** "Discovering Swift API Requirements Through Coverage-Guided Fuzzing"

**Example scenario:**
```swift
func parseConfig(_ input: String) -> Config? {
    guard input.hasPrefix("CONFIG:") else { return nil }
    let parts = input.dropFirst(7).split(separator: ",")
    guard parts.count == 3 else { return nil }
    guard let port = Int(parts[0]) else { return nil }
    return Config(port: port, host: String(parts[1]), key: String(parts[2]))
}
```

PropertyTestingKit would discover:
1. "CONFIG:" prefix requirement (via string mutations)
2. Comma-separated structure (via string mutations)
3. Three-part structure (via array length mutations)
4. Integer first field (via type-aware mutations)

This demonstrates the same emergent structure discovery as AFL's JPEG synthesis, adapted to Swift's type system.

### 4. Enhance String Dictionary Capture

The existing string dictionary capture (via fishhook) already addresses Zalewski's "magic value" limitation. Consider enhancements:

- **Multi-part concatenation:** Current implementation does 2-way concatenation; extend to 3-way for strings like "token_2024_secret"
- **Prefix/suffix extraction:** Given captured string "admin_root", extract "admin" and "root" as separate dictionary entries
- **Cross-platform support:** Explore alternatives to fishhook for Linux compatibility

### 5. Benchmark Against AFL-Style Format Discovery

Create a benchmark suite demonstrating format discovery capabilities:

```swift
// Test: Can PropertyTestingKit discover a simple tagged format?
func parseTaggedValue(_ input: String) -> Int? {
    guard input.hasPrefix("VALUE=") else { return nil }
    return Int(input.dropFirst(6))
}

@Test func discoverTaggedFormat() throws {
    try fuzz { (input: String) in
        if let value = parseTaggedValue(input) {
            // Successfully discovered "VALUE=" prefix + integer structure
        }
    }
}
```

Track metrics:
- Time to discover "VALUE=" prefix
- Number of iterations required
- Corpus size at discovery
- Compare structured mutations vs. byte-level mutations

### 6. Value Profile Already Solves AFL's Limitations

Zalewski noted AFL struggles with "atomically-executed checks involving large search spaces" (e.g., `strcmp(input, "SecretPassword123")`). PropertyTestingKit already addresses this:

- **Integer comparisons:** Value profile guidance with binary search mutations
- **String comparisons:** Dictionary capture + targeted mutations
- **Multi-value constraints:** Priority chaining solves sequences like `a == 111 && b == 222 && c == 333`

Document these capabilities as improvements over AFL's limitations.

---

## Conclusion

Zalewski's "Pulling JPEGs Out of Thin Air" demonstrates that coverage-guided fuzzing enables emergent discovery of complex structure without prior knowledge. PropertyTestingKit already implements the foundational techniques (coverage guidance, bucketed signatures, corpus management, structured mutation) that made this demonstration successful. The key difference is that PropertyTestingKit targets Swift code with structured types rather than binary parsers, making byte-level format discovery less relevant.

PropertyTestingKit's hybrid approach—combining AFL's coverage-guided corpus management with structured mutations, value profile guidance, and string dictionary capture—is well-suited to Swift Testing scenarios and already addresses limitations Zalewski identified in AFL. No major architectural changes are needed, but there are opportunities to:

1. Add binary parser testing support if use cases emerge
2. Create benchmarks demonstrating format/structure discovery in Swift code
3. Enhance string dictionary capture for multi-part concatenation
4. Document PropertyTestingKit's advantages over pure byte-level fuzzing

The current implementation represents a mature evolution of AFL's techniques, adapted thoughtfully to Swift's type system and Testing framework.
