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

//
//  CorpusMode.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

/// Controls how the fuzzer handles existing corpus files.
public enum CorpusMode: String, Sendable {
    /// Auto-detect: Run regression if corpus exists, otherwise fuzz fresh.
    /// This is the default behavior.
    case auto

    /// Always fuzz fresh, replacing any existing corpus.
    /// Use when you want to start over with a clean slate.
    case refuzzReplace

    /// Load existing corpus as additional seeds, then continue fuzzing.
    /// New discoveries are added to the corpus.
    /// Use when you want to expand coverage beyond the current corpus.
    case refuzzExtend

    /// Only run regression mode. Fails if no corpus exists.
    /// Use when you only want to verify existing coverage.
    case regressionOnly

    /// Environment variable name for suite-level control.
    public static let environmentVariable = "FUZZ_CORPUS_MODE"

    /// Get mode from environment variable, or return default.
    public static func fromEnvironment(default defaultMode: CorpusMode = .auto) -> CorpusMode {
        @Dependency(\.environment) var environment
        guard let value = environment.environment()[environmentVariable] else {
            return defaultMode
        }
        return CorpusMode(rawValue: value.lowercased()) ?? defaultMode
    }
}
