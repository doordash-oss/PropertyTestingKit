# Prior Art: Coverage-Guided Fuzzing & Property Testing

## Foundational Tools

| Tool | Language | Type | Key Features |
|------|----------|------|--------------|
| [AFL](https://github.com/google/AFL) | C/C++ | Coverage-guided fuzzing | Pioneered coverage-guided fuzzing with instrumentation |
| [libFuzzer](https://llvm.org/docs/LibFuzzer.html) | C/C++ | In-process fuzzing | LLVM-integrated, corpus management, value profile guidance |
| [QuickCheck](https://hackage.haskell.org/package/QuickCheck) | Haskell | Property testing | Original PBT framework, shrinking, type-based generation |

## Hybrid Approaches (Fuzzing + Property Testing)

| Tool | Language | Description |
|------|----------|-------------|
| [Google FuzzTest](https://github.com/google/fuzztest) | C++ | First to bridge fuzzing and PBT - rich API like property testing with coverage-guided engine like AFL/libFuzzer |
| [JQF/Zest](https://github.com/rohanpadhye/JQF) | Java | Coverage-guided property testing; uses QuickCheck-style generators with AFL-like feedback |
| [HypoFuzz](https://hypofuzz.com/) | Python | Coverage-guided backend for Hypothesis tests; runs existing PBT tests with fuzzing |
| [FuzzChick](https://lemonidas.github.io/pdf/FuzzChick.pdf) | Coq | Academic: Coverage-guided property-based testing (CGPT) |

## Property Testing Frameworks

| Tool | Language | Key Features |
|------|----------|--------------|
| [Hypothesis](https://hypothesis.readthedocs.io/) | Python | Most mature Python PBT; sophisticated shrinking, database persistence |
| [fast-check](https://fast-check.dev/) | TypeScript/JS | Smart shrinking on `oneof`, biased generation, used by Jest/Ramda |
| [proptest](https://crates.io/crates/proptest) | Rust | Hypothesis-inspired; per-value strategies (not per-type like QuickCheck) |
| [quickcheck](https://github.com/BurntSushi/quickcheck) | Rust | QuickCheck port; type-based generation with shrinking |
| [Gopter](https://github.com/leanovate/gopter) | Go | Shrinking, stateful testing with `commands` package |

## Go Ecosystem

| Tool | Description |
|------|-------------|
| [Native Go Fuzzing](https://go.dev/doc/security/fuzz/) (1.18+) | Built-in coverage-guided fuzzing with `Fuzz` prefix functions |
| [go-fuzz](https://github.com/dvyukov/go-fuzz) | Coverage-guided fuzzing; returns priority hints (1, 0, -1) |
| [google/gofuzz](https://github.com/google/gofuzz) | Structured input generation from byte slices |

## Key Concepts

### Corpus Management

- Inputs that trigger new coverage are saved to corpus
- Corpus scheduling prioritizes high-coverage seeds
- Minimal corpus: smallest set covering all paths

### Shrinking

- **Hypothesis**: Internal shrinking via `ConjectureData` refinement
- **fast-check**: Smart shrinking preserves `oneof` structure
- **proptest**: Per-value shrinking (more flexible than per-type)

### Mutation Strategies

- **AFL**: Bit-flip, block replacement, dictionary-based
- **libFuzzer**: CMP instruction interception (`-fsanitize-coverage=trace-cmp`)
- **Structure-aware**: QuickCheck-style generators vs byte mutation

### Coverage Feedback

- Branch coverage for path discovery
- Value profiles for comparison guidance (libFuzzer)
- Mutation testing scores for fault detection (Mu2)

## Most Relevant to PropertyTestingKit

1. **[Google FuzzTest](https://github.com/google/fuzztest)** - Closest in vision: property testing API + coverage guidance
2. **[HypoFuzz](https://hypofuzz.com/)** - Coverage-guided layer on top of existing PBT tests
3. **[JQF/Zest](https://github.com/rohanpadhye/JQF)** - Academic foundation for coverage-guided property testing
4. **[proptest](https://crates.io/crates/proptest)** - Per-value strategies pattern (similar to our `Mutator` approach)

## Academic Papers

### Foundational

- **QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs** (ICFP 2000)
  Claessen & Hughes. The original property-based testing paper. Won ICFP Most Influential Paper award 2010.

- **AFL Technical Whitepaper** (2013)
  Michal Zalewski. Introduced coverage-guided greybox fuzzing.

### Coverage-Guided Property Testing

- **[Coverage Guided, Property Based Testing](https://dl.acm.org/doi/10.1145/3360607)** (OOPSLA 2019)
  Lampropoulos, Hicks, Pierce. Introduces CGPT combining property testing with coverage-guided fuzzing. Implemented as FuzzChick.

- **[JQF: Coverage-guided property-based testing in Java](https://dl.acm.org/doi/10.1145/3293882.3339002)** (ISSTA 2019)
  Padhye et al. Coverage-guided fuzzing with QuickCheck-style generators for Java.

- **[Zest: Validity Fuzzing and Parametric Generators](https://doi.org/10.1109/ICSE-Companion.2019.00107)** (ICSE 2019)
  Padhye et al. Structure-aware fuzzing using generators as decoders from byte sequences.

### Shrinking & Test-Case Reduction

- **[Test-Case Reduction via Test-Case Generation: Insights from the Hypothesis Reducer](https://doi.org/10.4230/LIPIcs.ECOOP.2020.13)** (ECOOP 2020)
  MacIver & Donaldson. Describes Hypothesis's internal shrinking approach.

- **[Shrinking Counterexamples in Property-Based Testing with Genetic Algorithms](https://ieeexplore.ieee.org/document/9185807/)** (2020)
  Using genetic algorithms for shrinking in QuickChick.

- **[falsify: Internal Shrinking Reimagined for Haskell](https://dl.acm.org/doi/10.1145/3609026.3609733)** (Haskell Symposium 2023)
  Bringing Hypothesis-style internal shrinking to Haskell.

- **[QuickerCheck](https://arxiv.org/abs/2404.16062)** (2024)
  Parallel QuickCheck with improved shrinking performance.

### Corpus Management

- **[Corpus Distillation for Effective Fuzzing: A Comparative Evaluation](https://arxiv.org/abs/1905.13055)** (2019)
  Herrera et al. Formalizes corpus minimization as weighted minimum set cover problem.

- **[MoonLight: Effective Fuzzing with Near-Optimal Corpus Distillation](https://www.semanticscholar.org/paper/MoonLight:-Effective-Fuzzing-with-Near-Optimal-Hayes-Gunadi/06b444a71996b3298f5dce95569ef9ab05b7e26b)** (2019)
  Near-optimal corpus distillation using dynamic programming.

### Mutation Strategies

- **[Generator-Based Fuzzers with Type-Based Targeted Mutation](https://arxiv.org/abs/2406.02034)** (2024)
  Type-based mutation heuristics for generator-based fuzzers.

- **[The Havoc Paradox in Generator-Based Fuzzing](https://dl.acm.org/doi/10.1145/3742894)** (ACM TOSEM)
  Addresses destructive mutations in parametric generators.

- **[Guiding Greybox Fuzzing with Mutation Testing](https://rohan.padhye.org/files/mu2-issta23.pdf)** (ISSTA 2023)
  Mu2: Using mutation scores as feedback instead of just coverage.

### Fuzzer Evaluation & Improvements

- **[AFL++: Combining Incremental Steps of Fuzzing Research](https://www.usenix.org/system/files/woot20-paper-fioraldi.pdf)** (USENIX WOOT 2020)
  State-of-the-art AFL fork combining academic improvements.

- **[FairFuzz: A Targeted Mutation Strategy for Increasing Greybox Fuzz Testing Coverage](https://dl.acm.org/doi/10.1145/3238147.3238176)** (ASE 2018)
  Lemieux & Sen. Targeting rare branches.

- **[Data Coverage for Guided Fuzzing](https://www.usenix.org/system/files/usenixsecurity24-wang-mingzhe.pdf)** (USENIX Security 2024)
  Data coverage as complementary feedback to code coverage.

### Industry & Practice

- **[Property-Based Testing in Practice](https://dl.acm.org/doi/10.1145/3597503.3639581)** (ICSE 2024)
  Goldstein et al. Study of PBT adoption at Amazon, Volvo, Stripe.

- **[Hypothesis: A new approach to property-based testing](https://www.researchgate.net/publication/337429879_Hypothesis_A_new_approach_to_property-based_testing)** (2019)
  MacIver & Hatfield-Dodds. Hypothesis design and implementation.

### Blog Posts & Resources

- **[Property-Based Testing Is Fuzzing](https://blog.nelhage.com/post/property-testing-is-fuzzing/)** - Nelson Elhage
- **[Bridging Fuzzing and Property Testing](https://blog.yoshuawuyts.com/bridging-fuzzing-and-property-testing/)** - Yoshua Wuyts (Rust)
- **[The Fuzzing Book](https://www.fuzzingbook.org/)** - Zeller et al. Interactive textbook
- **[HypoFuzz Literature](https://hypofuzz.com/docs/literature.html)** - Curated bibliography
