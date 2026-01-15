# Codebase Structure

## Source Layout

```
Sources/
├── PropertyTestingKit/           # Main Swift library
│   ├── Fuzzing/
│   │   ├── FuzzEngine/           # Core fuzzing engine
│   │   │   ├── FuzzEngine.swift  # Main actor
│   │   │   ├── FuzzEngine+Config.swift
│   │   │   ├── FuzzStateMachine.swift
│   │   │   ├── FuzzResult.swift
│   │   │   ├── CorpusMode.swift
│   │   │   └── TaskResults.swift
│   │   ├── Plugins/              # Plugin system
│   │   │   ├── FuzzPlugin.swift
│   │   │   ├── *Plugin.swift     # Various plugins
│   │   │   └── ActionExecutor.swift
│   │   ├── Corpus/               # Corpus management
│   │   ├── Mutators/             # Mutation strategies
│   │   │   ├── Array/, Int/, Double/, String/
│   │   │   └── MutatorProviding/
│   │   ├── CoverageGap/          # Coverage gap detection
│   │   ├── TestCaseShrinker/     # Input minimization
│   │   ├── FuzzAPI.swift         # Public API
│   │   ├── Mutator.swift         # Mutator protocol
│   │   └── *PlateauDetector.swift
│   ├── Coverage/                 # Coverage tracking
│   │   ├── SanCovCounters.swift
│   │   ├── SparseCoverage.swift
│   │   └── DWARF/                # Debug info parsing
│   └── Dependencies/             # DI clients
├── SanCovHooks/                  # C: SanitizerCoverage hooks
│   ├── SanCovHooks.c
│   ├── ck_ht.c                   # ConcurrencyKit hash table
│   └── include/ck/              # ConcurrencyKit headers
└── CLLVMSymbolizer/              # C++: LLVM symbolizer
```

## Test Layout

```
Tests/
├── PropertyTestingKitTests/      # Main test suite
│   ├── Fuzzing/                  # Fuzzing tests
│   │   └── Corpus/               # Saved test corpora
│   └── Corpus/                   # More corpora
├── SanCovTests/                  # Coverage hook tests
├── TSanTests/                    # Thread sanitizer tests
├── StressTests/                  # Load/stress tests
└── ScratchPad/                   # Experimental
```

## Key Files
- `Package.swift` - SPM manifest with sanitizer flags
- `CLAUDE.md` - Development instructions
- `scripts/build-local-toolchain.sh` - Required build script
