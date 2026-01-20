# PropertyTestingKit - Project Overview

## Purpose
Coverage-guided fuzz testing library for Swift. Brings AFL-style fuzzing to Swift Testing framework.

## Key Features
- Coverage-guided fuzzing with automatic input generation
- Corpus persistence and regression detection
- Plugin system for customization

## Tech Stack
- **Language**: Swift 6.2+ (requires patched toolchain for parameter packs)
- **Platforms**: macOS 26+, iOS 26+

## Architecture
- `FuzzEngine`: Main actor-based fuzzing engine with state machine
- `Mutator` protocol: Extensible mutation strategies
- `Corpus`: Persistent storage of interesting inputs
- Plugin system: Observer, Stopping, and Analysis plugins
- Coverage tracking via SanitizerCoverage with task-keyed isolation
