# Property Testing Like AFL

**Article:** Elhage, N. (2020). Property Testing Like AFL. _Personal Blog_.

**Source:** https://blog.nelhage.com/post/property-testing-like-afl/

---

## Summary

Nelson Elhage's article addresses a critical gap in property-based testing (PBT) tools when used as regression test suites for large codebases: the failure to provide speed and reproducibility required for CI/CD environments. While traditional property testing generates random inputs at runtime, this approach creates slow test execution and nondeterministic behavior that makes it unsuitable for continuous integration. The article proposes a hybrid workflow that borrows techniques from modern coverage-guided fuzzing tools like AFL to solve these problems.

The key insight is that "property-based testing and fuzzing are essentially the same practice," but they've evolved with different priorities. Fuzzing tools prioritize production-ready test suites with deterministic replay, while property testing tools prioritize continuous discovery of new test cases. Elhage proposes combining the best of both worlds: maintain a curated corpus of test cases as hard-coded examples in version control (fast and deterministic), while providing a separate generation phase that uses coverage-guided exploration to discover and minimize test cases before committing them. This creates three distinct modes: traditional quick regression testing using committed examples, automated corpus generation with coverage guidance, and unbounded asynchronous fuzzing for continuous bug discovery.

The proposed system addresses practical engineering concerns: developers get fast, deterministic test runs by default (using only committed examples), but can invoke a generation command when they want to expand test coverage. The fuzzer uses AFL-style techniques including coverage-guided minimization to maintain a minimal corpus that exercises maximum code coverage while keeping execution time low. Failed test cases are automatically preserved and presented in a copy-paste-ready format for easy addition to the committed corpus, ensuring regressions never recur.

---

## Key Insights

1. **Property Testing and Fuzzing Are Converging**
   - Both techniques generate diverse inputs and check invariant properties
   - The fundamental difference is operational: PBT tools focus on discovery, fuzzers on regression prevention
   - Modern workflows should integrate both priorities rather than choosing one

2. **Speed and Reproducibility Are Blockers for PBT Adoption**
   - Random generation at runtime makes tests slow (generating thousands of cases per test)
   - Nondeterministic behavior breaks CI/CD pipelines and makes failures hard to reproduce
   - These issues prevent PBT from being practical for large codebases despite theoretical benefits

3. **Corpus Management Enables Deterministic Testing**
   - Store generated test cases as human-readable literals in version control
   - Default test runs execute only this fixed corpus (fast, deterministic)
   - Corpus becomes a form of "learned wisdom" about edge cases worth checking

4. **Coverage Guidance Should Drive Corpus Generation**
   - Use AFL-style coverage instrumentation to identify inputs exercising new code paths
   - Apply corpus minimization (like AFL's `afl-cmin`) to maintain smallest set covering all paths
   - Seed generation with existing examples when code changes to guide exploration

5. **Separate Discovery and Regression Testing**
   - Quick mode: Run committed corpus only (suitable for every commit)
   - Generation mode: Coverage-guided exploration to expand corpus (run before commits or periodically)
   - Continuous fuzzing mode: Unbounded async exploration that doesn't block development

6. **Failing Cases Should Auto-Persist**
   - When property checks fail, automatically save the failing input
   - Present failures in copy-paste-ready format for adding to committed corpus
   - Treat each failure as permanent addition to regression suite

7. **Minimize Test Corpus Automatically**
   - Apply set-cover minimization to reduce corpus size while preserving coverage
   - Balance between minimizing execution time and preserving diverse examples
   - Re-minimize periodically as code evolves

8. **Hypothesis Already Implements Most of This**
   - Hypothesis includes persistent failure database and coverage guidance
   - HypoFuzz (inspired by these ideas) provides separate fuzzing mode
   - The conceptual framework described in the article has proven implementable

---

## Applicability to PropertyTestingKit

### Extremely High Relevance

PropertyTestingKit already implements many of Elhage's key recommendations, but could better align its workflow with the three-mode approach described in the article. This is less about adding new features and more about restructuring how existing features are presented and used.

**Current PropertyTestingKit State:**

PropertyTestingKit already has:
- Corpus persistence (saved to disk as `corpus.json`)
- Coverage-guided fuzzing
- Corpus minimization (greedy set-cover algorithm)
- Multiple corpus modes (auto, refuzzReplace, refuzzExtend, regressionOnly)

**Gap Analysis:**

The primary gap is **workflow clarity and defaults**. PropertyTestingKit's current design treats corpus persistence as an implementation detail rather than as the central organizing principle. Elhage's article suggests the corpus should be the primary artifact, with fuzzing as a generation step.

Specific misalignments:
1. Corpus is stored as JSON, not as "human-readable literals" in test code
2. No clear distinction between "quick regression" and "generation" workflows
3. Developers must understand corpus modes rather than having intuitive defaults
4. No standardized way to review and commit corpus additions
5. Failing test cases aren't automatically formatted for easy corpus inclusion

### Workflow Alignment Opportunities

**Insight 1: Make Corpus the Source of Truth**

**Current behavior:** PropertyTestingKit saves corpus to `Corpus/testName/corpus.json` and developers commit this directory.

**Elhage's vision:** Test cases should be visible in test code as hard-coded seed values that serve double duty as documentation.

**Recommendation:** **Hybrid approach** - maintain both committed JSON corpus AND make it easy to view/edit:

```swift
// PropertyTestingKit could generate/update seed lists from corpus
@Test func testParser() throws {
    try fuzz(seeds: [
        // Auto-generated from corpus.json (or manually curated)
        "",
        "hello",
        "{\"key\": \"value\"}",
        "x".repeating(1000),
        // ... corpus entries as readable literals
    ]) { input in
        parse(input)
    }
}
```

**Implementation options:**
1. **Tool to convert corpus to seed code:** `swift run ptk corpus-export testParser` generates Swift code
2. **Macro to import corpus:** `@CorpusSeeds("testParser")` expands to seed list from JSON
3. **Dual storage:** Store both JSON (for metadata) and Swift literals (for readability)

**Trade-off:** Human-readable seeds work well for primitives (String, Int) but become impractical for complex types (deeply nested structs, large arrays). JSON storage is more practical for complex cases.

**Estimated effort:** Medium (2-3 weeks)

---

**Insight 2: Three-Mode Workflow**

**Elhage's three modes:**
1. **Quick regression** - Run committed corpus only (fast, deterministic)
2. **Corpus generation** - Coverage-guided fuzzing to expand corpus
3. **Continuous fuzzing** - Unbounded async exploration

**PropertyTestingKit's current modes:**
- `.auto` - Run regression if corpus exists, otherwise fuzz
- `.regressionOnly` - Run regression only
- `.refuzzReplace` - Always fuzz, replace corpus
- `.refuzzExtend` - Load corpus as seeds, continue fuzzing

**Mapping:**
- `.regressionOnly` ≈ Elhage's "quick regression"
- `.refuzzReplace`/`.refuzzExtend` ≈ Elhage's "corpus generation"
- (Missing) ≈ Elhage's "continuous fuzzing"

**Recommendation:** Reframe corpus modes around workflow intent rather than technical behavior:

```swift
enum FuzzWorkflow {
    case regression              // Run corpus only (fast CI mode)
    case generate(iterations: Int) // Expand corpus with coverage-guided fuzzing
    case continuous              // Unbounded fuzzing until stopped (async)
}

@Test func testParser() throws {
    try fuzz(workflow: .regression) { input in
        parse(input)
    }
}
```

**Environment variable alignment:**
```bash
# CI default: fast regression testing
FUZZ_WORKFLOW=regression swift test

# Pre-commit: expand corpus intelligently
FUZZ_WORKFLOW=generate swift test

# Background: continuous discovery
FUZZ_WORKFLOW=continuous swift test &
```

**Benefits:**
- Clearer intent: "regression" vs "generate" vs "continuous"
- Better defaults: `.regression` should be default (matches CI needs)
- Explicit about time commitment: regression is fast, generation is bounded, continuous is unbounded

**Estimated effort:** Low (1 week to refactor mode naming and defaults)

---

**Insight 3: Auto-Persist Failures in Copy-Paste Format**

**Elhage's vision:** When a test fails, present the failing input in a format ready to copy into the seeds list.

**Current PropertyTestingKit:** Failures are reported but not formatted for easy seed addition.

**Recommendation:** On test failure, output copy-paste-ready seed code:

```swift
// Test failure output:
Test failed with input: "malformed{json"

Add this to your seeds to prevent regression:

try fuzz(seeds: [
    // existing seeds...
    "malformed{json",  // Add this line
]) { input in
    parse(input)
}
```

**Implementation:**
1. Capture failing input in test failure context
2. Format input as Swift literal (escaped strings, readable numbers, etc.)
3. Include in failure message with instructions
4. Optionally: Save to `.failing-cases` file that can be merged into seeds

**Estimated effort:** Low (1 week)

---

**Insight 4: Coverage-Guided Corpus Minimization**

**Current PropertyTestingKit:** Already implements greedy set-cover minimization in `Corpus.minimized()`.

**Elhage insight:** Minimization should happen automatically and continuously, not just at end.

**Recommendation:** Enhance existing minimization:

1. **Periodic minimization during fuzzing:**
   ```swift
   // Every N iterations, re-minimize corpus to keep it small
   if iterations % 1000 == 0 {
       corpus.minimize(preserveDiversity: true)
   }
   ```

2. **Preserve diversity, not just coverage:**
   - Current: Minimize to smallest set covering all coverage
   - Enhanced: Weight smaller/simpler inputs when coverage is equal
   - Enhanced: Preserve diverse input "shapes" (different lengths, types, patterns)

3. **Incremental minimization:**
   - Don't re-minimize entire corpus each time
   - Track which entries are "redundant" and only reconsider those
   - Use incremental set-cover algorithms

**Alignment with Elhage:** AFL's `afl-cmin` tool is separate from fuzzing; PropertyTestingKit could offer similar:

```bash
# Standalone corpus minimization tool
swift run ptk corpus-minimize testParser

# Shows before/after stats:
# Before: 1,247 corpus entries, 42s execution time
# After: 156 corpus entries, 3.2s execution time
# Coverage preserved: 100%
```

**Estimated effort:** Medium (2-3 weeks for enhanced minimization + CLI tool)

---

**Insight 5: Seed Generation from Existing Examples**

**Elhage insight:** When code changes, use existing corpus entries as seeds for new fuzzing rounds to guide exploration efficiently.

**PropertyTestingKit current:** `.refuzzExtend` loads existing corpus as seeds, but this isn't the default behavior.

**Recommendation:** Make seed-from-corpus the default when re-fuzzing:

```swift
// Auto mode should be smarter:
enum CorpusMode {
    case auto  // If corpus exists AND coverage differs, refuzz with corpus as seeds
               // Otherwise just run regression
}
```

**Current `.auto` behavior:**
- If corpus exists: Run regression
- If coverage differs: Re-fuzz from scratch

**Enhanced `.auto` behavior:**
- If corpus exists: Run regression
- If coverage differs: Re-fuzz using corpus entries as seeds (not from scratch)
- This leverages existing "known interesting" inputs to explore changes faster

**Estimated effort:** Low (1 week to adjust auto mode logic)

---

**Insight 6: Separate Asynchronous Fuzzing**

**Elhage's third mode:** Continuous unbounded fuzzing that doesn't block development.

**Current PropertyTestingKit:** All fuzzing is synchronous and blocks test completion.

**Recommendation:** Add async continuous fuzzing mode:

```swift
// Continuous mode: Run indefinitely until stopped
@Test func testParser() throws {
    try fuzz(workflow: .continuous) { input in
        parse(input)
    }
}
```

**Behavior:**
- Run in background (via environment: `FUZZ_WORKFLOW=continuous swift test &`)
- Save findings to separate `.fuzz-findings/` directory
- Developer reviews findings periodically and promotes to corpus
- Never blocks CI/CD pipeline

**Use case:** Run overnight on developer machines or dedicated fuzzing servers, triage findings in the morning.

**Implementation approach:**
1. Continuous mode runs until process killed (no iteration/time limits)
2. Findings saved incrementally to avoid loss on termination
3. Separate findings directory keeps them out of committed corpus until reviewed

**Estimated effort:** Medium (2-3 weeks for async mode + findings workflow)

---

### Design Recommendations: Aligning with Elhage's Vision

**Recommendation 1: Restructure Default Workflow (High Priority)**

**Problem:** Current defaults don't match CI/CD reality. Most test runs should be fast regressions, not fuzzing.

**Solution:** Make regression the default, fuzzing opt-in:

```swift
// Default behavior: run corpus only (fast, deterministic)
@Test func testParser() throws {
    try fuzz { input in
        parse(input)
    }
}
// Uses environment FUZZ_WORKFLOW (defaults to "regression")

// Explicit generation when expanding corpus
@Test func testParser_generate() throws {
    try fuzz(workflow: .generate(iterations: 50_000)) { input in
        parse(input)
    }
}
```

**Environment-driven workflow:**
```bash
# Default CI: fast regression (seconds)
swift test

# Pre-commit: expand corpus (minutes)
FUZZ_WORKFLOW=generate swift test

# Background: continuous discovery (indefinite)
FUZZ_WORKFLOW=continuous swift test &
```

**Benefits:**
- Fast by default (matches Elhage's vision)
- Deterministic by default (no CI flakiness)
- Fuzzing becomes explicit generation step
- Clear separation of regression vs discovery

**Estimated effort:** Medium (2-3 weeks)
- Change default workflow semantics
- Update documentation and examples
- Add workflow-driven execution modes
- Ensure backward compatibility

---

**Recommendation 2: Improve Corpus Visibility (Medium Priority)**

**Problem:** Corpus stored as opaque JSON makes it hard to review/understand test coverage.

**Solution:** Generate human-readable seed representations:

```swift
// Tool to export corpus as Swift code
$ swift run ptk corpus-export testParser

// Generated output (can be pasted into test):
let testParserCorpus: [String] = [
    "",
    "hello",
    "{\"key\": \"value\"}",
    String(repeating: "x", count: 1000),
    // ... more entries
]

@Test func testParser() throws {
    try fuzz(seeds: testParserCorpus) { input in
        parse(input)
    }
}
```

**Benefits:**
- Corpus becomes visible in code reviews
- Easy to manually curate (add/remove entries)
- Serves as documentation of known edge cases
- Can be versioned and reviewed like normal code

**Alternative: Macro approach:**
```swift
@Test func testParser() throws {
    // Macro loads corpus.json and expands to seed array
    try fuzz(seeds: #corpus("testParser")) { input in
        parse(input)
    }
}
```

**Estimated effort:** Low-Medium (1-2 weeks)

---

**Recommendation 3: Enhance Failure Reporting (Quick Win)**

**Problem:** When fuzzing finds failures, not clear how to add them to corpus permanently.

**Solution:** Auto-format failures as seeds:

```swift
// On failure, print:
===================================================================
FUZZ FAILURE: testParser
-------------------------------------------------------------------
Input: "malformed{json"

To prevent regression, add to seeds:

try fuzz(seeds: [
    // ...existing seeds
    "malformed{json",  // <- ADD THIS
]) { input in
    parse(input)
}
===================================================================
```

**Estimated effort:** Low (1 week)

---

**Recommendation 4: Corpus Minimization Tool (Medium Priority)**

**Problem:** Corpus grows over time, slowing down regression tests.

**Solution:** Provide standalone minimization tool:

```bash
$ swift run ptk corpus-minimize testParser --target-time=5s

Analyzing corpus...
  Current: 1,247 entries, 42.3s execution time

Minimizing (preserving 100% coverage)...
  [========================================] 100%

Results:
  Minimized: 156 entries, 4.8s execution time
  Coverage preserved: 2,341 regions
  Reduction: 87.5% fewer entries, 88.7% faster

Corpus saved to: Tests/Corpus/testParser/corpus.json
```

**Benefits:**
- Keep regression tests fast as corpus grows
- Explicit tool matches AFL's `afl-cmin` workflow
- Can be run periodically or in CI

**Estimated effort:** Medium (2-3 weeks for CLI tool + enhanced minimization)

---

## Summary

Elhage's article validates PropertyTestingKit's core approach (coverage-guided corpus management) but highlights workflow gaps. PropertyTestingKit already implements the technical foundations but presents them in ways that don't match the workflow needs Elhage identifies.

**Key takeaways:**

1. **Workflow over features:** PropertyTestingKit has the right features but wrong defaults. Regression should be default, fuzzing should be explicit generation step.

2. **Corpus visibility matters:** Current JSON storage is practical but opaque. Tools to view/export corpus as readable code would improve developer experience.

3. **Three distinct modes:** Elhage's regression/generate/continuous model maps better to developer workflows than current technical mode names.

4. **Failure persistence:** Auto-formatting failures as copy-paste-ready seeds reduces friction for building robust regression suites.

5. **Hypothesis proves it works:** The article's vision has been validated by Hypothesis/HypoFuzz implementation in Python ecosystem.

**Priority Recommendations:**

1. **High:** Restructure default workflow (regression by default, fuzzing explicit)
2. **Medium:** Add corpus visibility tools (export as Swift code)
3. **Medium:** Implement continuous fuzzing mode with separate findings directory
4. **Low-Medium:** Enhance corpus minimization and provide CLI tool
5. **Quick win:** Auto-format failures as copy-paste-ready seeds

PropertyTestingKit is well-positioned to adopt Elhage's vision with mostly workflow and presentation changes rather than major technical overhauls. The article provides excellent validation that PropertyTestingKit's technical approach is sound, while highlighting opportunities to improve the developer experience and CI/CD integration.
