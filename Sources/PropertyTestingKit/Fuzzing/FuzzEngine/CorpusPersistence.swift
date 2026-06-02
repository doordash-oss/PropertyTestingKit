// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Dependencies

/// How `fuzz(...)` treats an existing on-disk corpus.
///
/// These are the only corpus policies that make sense when you are *fuzzing*. Pure
/// replay (verify a saved corpus without exploring) is not here — that's the separate
/// `regress(...)` entry point, which carries none of the fuzz-only knobs. Splitting the
/// two means a regression run can't be handed a coverage strategy, parallelism, seeds,
/// or write-emitting plugins it would silently ignore.
public enum CorpusPersistence: Sendable {
    /// Replay the saved corpus if one exists, otherwise fuzz fresh and save.
    /// This is the default — it maintains a corpus across runs.
    case auto

    /// Delete any existing corpus, fuzz fresh, and save the result.
    /// Use when you want to start over with a clean slate.
    case replace

    /// Load the existing corpus as additional seeds, fuzz, and save.
    /// Use when you want to expand coverage beyond the current corpus.
    case extend

    /// Fuzz in memory only — ignore any existing corpus and don't save. Nothing
    /// touches disk. Use for throwaway runs (benchmarks, exploratory tests) that
    /// care about the in-memory result, not a persisted corpus.
    case ephemeral
}

// MARK: - Environment override

/// The outcome of resolving the `FUZZ_CORPUS_MODE` env var against a call site's
/// `CorpusPersistence`. A `fuzz(...)` call either fuzzes with some persistence policy,
/// or is forced into a pure replay by the suite-level env override.
enum ResolvedFuzzMode {
    /// Fuzz with this persistence policy.
    case fuzz(CorpusPersistence)
    /// The env var forced a verify-only replay (CI determinism). The replay runs with
    /// no user handlers, so the no-write guarantee holds without a runtime gate.
    case forcedReplay
}

extension CorpusPersistence {
    /// Environment variable for suite-level control (e.g. CI). Legacy string values are
    /// preserved so existing `FUZZ_CORPUS_MODE=...` invocations keep working.
    static let environmentVariable = "FUZZ_CORPUS_MODE"

    /// Resolve the env override against the call site's persistence. Only the `fuzz(...)`
    /// path consults this; `regress(...)` always replays regardless of the env var.
    ///
    /// - `regressiononly` forces a replay (handler-less — see `ResolvedFuzzMode.forcedReplay`).
    /// - `refuzzreplace` / `refuzzextend` / `auto` force the corresponding persistence.
    /// - anything else (unset/unknown) honors the call site.
    static func resolveForFuzz(callSite: CorpusPersistence) -> ResolvedFuzzMode {
        @Dependency(\.environment) var environment
        switch environment.environment()[environmentVariable]?.lowercased() {
        case "regressiononly": return .forcedReplay
        case "refuzzreplace": return .fuzz(.replace)
        case "refuzzextend": return .fuzz(.extend)
        case "ephemeral": return .fuzz(.ephemeral)
        case "auto": return .fuzz(.auto)
        default: return .fuzz(callSite)
        }
    }
}
