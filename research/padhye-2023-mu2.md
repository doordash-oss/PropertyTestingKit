# Guiding Greybox Fuzzing with Mutation Testing (Mu2)

**Authors:** Vasudev Vikram, Isabella Laybourn, Ao Li, Nicole Nair, Kelton OBrien, Rafaello Sanna, and Rohan Padhye
**Publication:** ISSTA 2023 (ACM SIGSOFT International Symposium on Software Testing and Analysis)
**Award:** ACM SIGSOFT Distinguished Paper Award
**Paper URL:** https://rohan.padhye.org/files/mu2-issta23.pdf
**Code:** https://github.com/cmu-pasta/mu2

## Paper Summary

Greybox fuzzing and mutation testing have traditionally been independent areas of software testing research. Coverage-guided fuzzers like AFL and libFuzzer excel at discovering new code paths but struggle with bugs that lie in already-explored paths. Mutation testing, on the other hand, evaluates test quality by measuring how well tests detect artificially injected faults (mutants), but has primarily been used for regression test assessment rather than test generation.

Mu2 bridges this gap by integrating mutation testing directly into the greybox fuzzing loop. Instead of relying solely on edge coverage as a guidance metric, Mu2 uses **mutation score** (the number of mutants killed) as a complementary signal for selecting and prioritizing test inputs. The key insight is that inputs which kill more mutants are better at distinguishing correct behavior from buggy behavior, making them valuable seeds for further mutation even if they don't discover new coverage.

The paper addresses the computational challenge of mutation testing (evaluating every input against potentially thousands of mutants) through dynamic optimizations: (a) sound pruning that eliminates mutants which cannot be killed by a given input based on execution analysis, and (b) aggressive pruning that selects only a bounded subset of candidate mutants per iteration. Mu2 implements bytecode-level mutation operators in Java and uses a differential oracle to detect semantic differences between the original program and mutants without requiring explicit crash oracles. Results on five real-world Java benchmarks show that Mu2 synthesizes test corpora with higher mutation scores than the state-of-the-art Java fuzzer Zest, while discovering bugs that pure coverage-guided approaches miss.

## Key Strategies/Techniques

### 1. Mutation Score as Fuzzing Guidance
- **Core Innovation:** Use mutation-killing ability (not just coverage) as a fitness metric for corpus selection
- **Dual Optimization:** Inputs are saved if they either (a) discover new edge coverage OR (b) kill previously-living mutants
- **Energy Allocation:** Inputs that kill more mutants receive higher energy (more mutations) in subsequent fuzzing iterations

### 2. Differential Oracle for Semantic Validation
- **Problem:** Traditional fuzzing oracles only detect crashes/aborts, missing semantic bugs
- **Solution:** Compare program output on original code vs. mutants to detect behavioral differences
- **Annotations:** Uses `@Diff` and `@Comparison` annotations to specify differential test goals
- **Advantage:** Enables detection of bugs in functional correctness without requiring manual assertions

### 3. Dynamic Mutant Pruning Optimizations

**Cartography Phase:**
- Before fuzzing, instrument the program to identify all mutation opportunities
- Track which mutations are reachable during normal execution
- Create a `CartographyClassLoader` that logs mutation sites and generates `MutationInstance` objects

**Sound Optimizations:**
- Only test mutants that were executed during the original program run
- Skip mutants in unreached code paths (cannot be killed by this input)
- Dramatically reduces the mutant evaluation space without false negatives

**Aggressive Optimizations:**
- Bound the number of mutants evaluated per fuzzing iteration (trading completeness for throughput)
- Prioritize mutants based on execution frequency and mutation type
- Timeout protection to prevent infinite loops in mutants

### 4. Bytecode-Level Mutation Operators
- **Implementation:** Operate on Java bytecode rather than source code for efficiency
- **Example Operators:**
  - `I_ADD_TO_SUB`: Change integer addition to subtraction
  - `VOID_REMOVE_STATIC`: Remove void static method calls
  - `S_IRETURN_TO_0`: Force short returns to return zero
- **Advantage:** Precise, compiler-independent mutations without source recompilation

### 5. ClassLoader-Based Mutant Isolation
- Separate `MutationClassLoader` instances for each mutant
- Enables parallel mutation evaluation without interference
- Avoids expensive recompilation per mutant
- `targetIncludes` parameter optimizes by segregating instrumented classes

### 6. Integration with Existing Fuzzers
- Built on top of JQF (Java QuickCheck Fuzzing) platform
- Compatible with existing coverage-guided fuzzing infrastructure (Zest)
- Can be retrofitted to other fuzzers as a guidance layer
- Reported 9.6x speedup over PIT mutation testing framework for in-memory analysis

## Applicability to PropertyTestingKit

### High Applicability: Core Concepts

**1. Mutation Score as Complementary Guidance**
- **Current State:** PropertyTestingKit uses edge coverage and value profile guidance (comparison tracking)
- **Opportunity:** Add mutation-killing as a third dimension of "interestingness"
- **Implementation Path:**
  - Extend `CoverageSignature` to include a "mutation signature" field tracking which mutants were killed
  - Modify `Corpus.addIfInteresting` to save inputs that kill new mutants
  - Add `MutationSignature` struct similar to `CoverageSignature`

**2. Value Profile Synergy**
- **Existing Infrastructure:** PropertyTestingKit already has `ValueProfileTracker` for comparison tracking
- **Natural Extension:** Mutation testing is essentially comparison tracking taken to its logical conclusion
- **Advantage:** Both techniques target the same problem (solving hard predicates) but at different granularities
- **Recommendation:** Use mutation testing for high-value comparisons that value profiling identifies as challenging

**3. Corpus Management Alignment**
- **Current Architecture:** PropertyTestingKit already has corpus persistence, minimization, and energy-based mutation selection
- **Natural Fit:** Add mutation score to corpus entry metadata alongside coverage signature
- **Energy Formula:** Enhance `selectForMutation()` to consider mutation score: `energy = f(coverage_uniqueness, mutants_killed, execution_time)`

### Medium Applicability: With Adaptation

**4. Swift-Specific Mutation Operators**
- **Challenge:** Mu2 uses Java bytecode mutations; Swift uses LLVM IR/MachO
- **Approach 1 (Lightweight):** Source-level mutations using SwiftSyntax
  - Mutate Swift AST nodes before compilation
  - Examples: negate boolean conditions, swap comparison operators, change arithmetic operators
  - Pros: Easy to implement, no runtime instrumentation needed
  - Cons: Requires recompilation per mutant (slow)

- **Approach 2 (Advanced):** LLVM IR-level mutations
  - Hook into Swift's LLVM compilation pipeline
  - Mutate IR instructions before code generation
  - Similar to Mu2's bytecode approach
  - Pros: Fast, precise mutations
  - Cons: Complex integration, toolchain dependency

- **Approach 3 (Pragmatic):** Symbolic mutation via test comparison
  - Don't generate actual mutants; instead, detect mutation-like behaviors at runtime
  - Use PropertyTestingKit's existing coverage infrastructure to identify "mutation-equivalent" paths
  - Pros: No compilation overhead, works with existing infrastructure
  - Cons: Less precise than explicit mutations

**5. Differential Oracle for Swift Testing**
- **Challenge:** Swift Testing framework doesn't have built-in differential testing
- **Solution:** Extend PropertyTestingKit with differential test support
  ```swift
  @Test func testParser() throws {
      try fuzzDifferential(
          implementations: [parserV1, parserV2],
          oracle: { results in results.allSatisfy { $0 == results[0] } }
      ) { input in
          // Test both implementations, verify they agree
      }
  }
  ```
- **Use Case:** Detect semantic regressions when refactoring without crashes

### Low Applicability: Platform Limitations

**6. Dynamic Mutant Evaluation at Runtime**
- **Mu2 Approach:** Load mutated classes at runtime via ClassLoader
- **Swift Challenge:** Swift doesn't have runtime class loading/code replacement
- **Workaround:** Pre-compile mutants as separate test binaries
  - Build multiple test targets, each with different mutation applied
  - Run fuzzer against each variant in parallel
  - Collect mutation scores across all runs
- **Trade-off:** Much slower than Mu2's approach, but achieves same goal

**7. Cartography Phase**
- **Mu2 Approach:** Runtime instrumentation to identify reachable mutations
- **Swift Alternative:** Use LLVM coverage data to identify executed code regions
- **Advantage:** PropertyTestingKit already has coverage infrastructure via `InMemoryCoverageReader`
- **Implementation:** Map coverage regions to potential mutation sites (e.g., all comparison operators in executed functions)

## Concrete Recommendations

### Phase 1: Foundation (1-2 weeks)

**1. Add Lightweight Mutation Testing Support**

Create a mutation signature concept parallel to coverage signature:

```swift
// Sources/PropertyTestingKit/Fuzzing/MutationSignature.swift
public struct MutationSignature: Hashable, Codable, Sendable {
    /// IDs of mutants killed by this input
    public let killedMutants: Set<MutantID>

    public struct MutantID: Hashable, Codable, Sendable {
        let file: String
        let line: Int
        let operator: MutationOperator
    }

    public enum MutationOperator: String, Codable {
        case negateCondition      // if x > y  ->  if x <= y
        case swapComparison       // if x > y  ->  if x < y
        case changeArithmetic     // x + y     ->  x - y
        case returnZero           // return x  ->  return 0
        case removeStatement      // doSomething() -> /* removed */
    }
}

// Extend Corpus entry to track mutation score
extension Corpus.Entry {
    var mutationSignature: MutationSignature? { get set }
}
```

**2. Integrate with Existing Value Profile Infrastructure**

Treat mutation-killing as a special case of value profile progress:

```swift
// In FuzzEngine.swift, around line 593
let vpImprovements = config.enableValueProfile ? valueProfileTracker.processComparisons() : []
let mutationProgress = config.enableMutationTesting ? mutationTracker.detectKilledMutants() : []

if addedForCoverage {
    iterationsSinceNewCoverage = 0
} else if !vpImprovements.isEmpty || !mutationProgress.isEmpty {
    // Progress on comparisons OR mutation killing
    corpus.add(input: repeat each input, signature: signature, mutationSig: currentMutationSignature)
    priorityMutationIndex = corpus.count - 1
    iterationsSinceNewCoverage = 0
}
```

**3. Add Symbolic Mutation Detection**

Instead of generating actual mutants, detect when inputs reveal mutation-equivalent behaviors:

```swift
// Detect patterns like "input A and B differ only in one value but produce different outcomes"
// This approximates mutation testing without recompilation
class SymbolicMutationDetector {
    func detectEquivalentMutations(
        input1: T,
        input2: T,
        coverage1: CoverageSignature,
        coverage2: CoverageSignature
    ) -> Set<MutantID> {
        // If inputs are "1-edit distance" apart but have different coverage,
        // they likely killed a "virtual mutant" at that edit location
        guard input1.editDistance(from: input2) == 1 else { return [] }
        guard coverage1 != coverage2 else { return [] }

        // Infer virtual mutant from the difference
        return inferMutantFromDiff(input1, input2)
    }
}
```

### Phase 2: Enhanced Implementation (2-4 weeks)

**4. Source-Level Mutation via SwiftSyntax**

Generate simple mutations using SwiftSyntax for targeted testing:

```swift
import SwiftSyntax
import SwiftParser

class SwiftMutationGenerator {
    func generateMutants(sourceFile: URL) throws -> [Mutant] {
        let source = try String(contentsOf: sourceFile)
        let tree = Parser.parse(source: source)

        var mutants: [Mutant] = []

        // Walk AST and generate mutations
        tree.walk(MutationVisitor { node in
            switch node {
            case let binOp as BinaryOperatorExprSyntax:
                // Mutate operators: + -> -, > -> <, etc.
                mutants.append(mutateBinaryOp(binOp))
            case let condition as ConditionExprSyntax:
                // Negate conditions
                mutants.append(negateCondition(condition))
            default:
                break
            }
        })

        return mutants
    }
}
```

**5. Differential Testing API**

Add first-class support for differential oracles:

```swift
public extension FuzzEngine {
    func runDifferential<Output: Equatable>(
        implementations: [(Input) -> Output],
        test: (Input) throws -> Void
    ) -> FuzzResult<Input> {
        // Treat each implementation as a "mutant"
        // Save inputs where implementations disagree
        run { input in
            let outputs = implementations.map { $0(input) }
            if !outputs.allSatisfy({ $0 == outputs[0] }) {
                // This input killed a "mutant" (revealed implementation difference)
                currentMutationSignature.killedMutants.insert(...)
            }
            try test(input)
        }
    }
}
```

**6. Mutation-Guided Input Generation**

Use mutation analysis to guide which mutations to prioritize:

```swift
// In mutateInput(), prioritize mutations that target known weak mutants
private func mutateInput(_ input: Input) -> [Input] {
    var mutations = input.mutate()

    // Add targeted mutations for mutants we haven't killed yet
    if config.enableMutationTesting {
        let liveM mutants = mutationTracker.getLiveMutants()
        for mutant in liveMutants.prefix(10) {
            // Generate input specifically designed to kill this mutant
            if let targetedInput = generateMutantKillingInput(from: input, targeting: mutant) {
                mutations.append(targetedInput)
            }
        }
    }

    return mutations
}
```

### Phase 3: Advanced Integration (4-8 weeks)

**7. Pre-Compiled Mutant Testing**

Generate test binaries with mutations and run fuzzer in "multi-variant" mode:

```bash
# Build script: generate multiple binaries with different mutations
swift build -c release --define MUTANT_1  # Enables mutation #1 at compile time
swift build -c release --define MUTANT_2  # Enables mutation #2 at compile time
# ... etc

# Run fuzzer against all variants in parallel
./fuzz-all-mutants --corpus=./corpus --duration=60
```

```swift
#if MUTANT_1
    // Mutated version: change > to <
    if x < y { ... }
#else
    // Original version
    if x > y { ... }
#endif
```

**8. Integration with Build System**

Add mutation testing mode to PropertyTestingKit's build scripts:

```bash
# scripts/fuzz-with-mutations.sh
#!/bin/bash
# 1. Generate mutants using SwiftSyntax
# 2. Build test suite for each mutant
# 3. Run fuzzer against original + all mutants in parallel
# 4. Collect mutation scores and update corpus
```

**9. Visualization and Reporting**

Extend corpus reporting to show mutation coverage:

```swift
struct MutationReport {
    let totalMutants: Int
    let killedMutants: Int
    let liveMutants: [MutantID]
    let mutationScore: Double  // killedMutants / totalMutants

    let coverageVsMutationScore: [(coverage: Int, mutationScore: Double)]
    // Shows relationship between edge coverage and mutation score
}
```

### Quick Win: Implement Today (1-2 days)

**Start with Differential Testing for Custom Types**

Users can immediately benefit from mutation-testing concepts via differential testing:

```swift
// Example: Test a refactored parser against the old implementation
@Test func testParserRefactoring() throws {
    try fuzz { (input: String) in
        let oldResult = OldParser.parse(input)
        let newResult = NewParser.parse(input)

        // Fail if implementations disagree (differential oracle)
        #expect(oldResult == newResult,
                "Parser refactoring changed behavior on: \(input)")
    }
}
```

This requires minimal changes to PropertyTestingKit but provides immediate mutation-testing value. Add a helper:

```swift
public func fuzzDifferential<Input, Output: Equatable>(
    _ impl1: @escaping (Input) -> Output,
    _ impl2: @escaping (Input) -> Output,
    test: (Input) throws -> Void
) throws -> FuzzResult<Input> {
    var differences: [(Input, Output, Output)] = []

    return fuzz { input in
        let out1 = impl1(input)
        let out2 = impl2(input)

        if out1 != out2 {
            differences.append((input, out1, out2))
            // This input "killed a mutant" (revealed difference)
        }

        try test(input)
    }
}
```

## Alignment with PropertyTestingKit's Architecture

PropertyTestingKit is **remarkably well-positioned** to adopt Mu2's techniques:

### Existing Strengths to Leverage

1. **Coverage Infrastructure:** PropertyTestingKit already has sophisticated coverage tracking via LLVM profiling, which is more advanced than typical Java bytecode coverage
2. **Value Profile Guidance:** The existing `ValueProfileTracker` is conceptually similar to mutation testing (both target hard predicates)
3. **Corpus Management:** Energy-based mutation selection, minimization, and persistence are already implemented
4. **Variadic Input Support:** PropertyTestingKit's parameter pack support enables complex multi-input mutation testing
5. **Custom Mutators:** The `Mutator` protocol provides extension points for mutation-aware strategies

### Strategic Fit

- **Non-Crash Oracles:** Swift Testing's `#expect` provides rich assertion semantics, perfect for differential oracles
- **Performance:** PropertyTestingKit targets 60-second fuzz runs; lightweight mutation detection fits this budget
- **Developer Experience:** Mutation testing aligns with PropertyTestingKit's goal of making property-based testing accessible

### Implementation Priority

1. **High Priority:** Differential testing API (easy, high value, works today)
2. **Medium Priority:** Symbolic mutation detection (reuses existing infrastructure)
3. **Lower Priority:** Explicit mutant generation (complex, Swift-specific tooling required)

The key insight from Mu2 is that **mutation testing doesn't have to be expensive**. By using dynamic pruning (only test reachable mutants) and treating mutation-killing as guidance rather than a goal, PropertyTestingKit can gain the benefits of mutation testing without the traditional performance penalties.

---

## Sources

- [Guiding Greybox Fuzzing with Mutation Testing (PDF)](https://rohan.padhye.org/files/mu2-issta23.pdf)
- [ISSTA 2023 Conference Page](https://2023.issta.org/details/issta-2023-technical-papers/66/Guiding-Greybox-Fuzzing-with-Mutation-Testing)
- [Mu2 GitHub Repository](https://github.com/cmu-pasta/mu2)
- [ACM Digital Library Entry](https://dl.acm.org/doi/abs/10.1145/3597926.3598107)
- [NSF PAGES Abstract](https://par.nsf.gov/biblio/10444294-guiding-greybox-fuzzing-mutation-testing)
- [Mu2 README](https://github.com/cmu-pasta/mu2/blob/main/README.md)
