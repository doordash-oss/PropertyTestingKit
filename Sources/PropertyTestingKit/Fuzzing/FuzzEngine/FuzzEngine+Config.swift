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
//  FuzzEngine+Config.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Testing

/// Configuration for the fuzzing run.
struct FuzzEngineConfig: Sendable {
    /// Maximum time to spend fuzzing.
    var maxDuration: Duration

    /// Whether to minimize the corpus before saving.
    let minimizeCorpus: Bool

    /// Verbose logging.
    var verbose: Bool

    /// Controls how the fuzzer handles existing corpus files.
    /// Defaults to checking the `FUZZ_CORPUS_MODE` environment variable,
    /// then falling back to `.auto`.
    let corpusMode: CorpusMode

    /// Project root path for filtering coverage gaps to project files only.
    /// When set, only reports gaps in files under this path.
    let projectPath: String?

    /// Source location where the fuzz test was called.
    /// Used for reporting failures and plugin actions.
    let sourceLocation: SourceLocation

    /// How often to check the time limit (in iterations).
    /// Higher values reduce overhead from Date.init() calls but may overshoot the time limit slightly.
    /// Default: 1000 (checks ~10K times/sec at 10M iterations/sec, ~3x faster than per-iteration).
    /// Tests that need precise iteration control should use 1.
    let timeLimitCheckInterval: Int

    /// The coverage strategy that determines when an input is "interesting."
    /// Default: `.pathTrie` — O(1) per-hit trie-based path tracking.
    let coverageStrategy: CoverageStrategyKind

    /// Custom edge hook called on every edge hit.
    /// When set, replaces the default binary recording in the sanitizer coverage hook.
    /// The hook receives the guard pointer — dereference it to get the edge index.
    /// Call `sancov_record_edge(guardPtr)` from your hook for default behavior.
    /// When `nil`, the default binary recording is used.
    let edgeHook: EdgeHook?

    init(
        maxDuration: Duration = .seconds(60),
        minimizeCorpus: Bool = true,
        verbose: Bool = false,
        corpusMode: CorpusMode? = nil,
        projectPath: String? = nil,
        timeLimitCheckInterval: Int = 1000,
        coverageStrategy: CoverageStrategyKind = .pathTrie,
        edgeHook: EdgeHook? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        self.maxDuration = maxDuration
        self.minimizeCorpus = minimizeCorpus
        self.verbose = verbose
        // Use provided mode, or check environment, or default to auto
        self.corpusMode = corpusMode ?? CorpusMode.fromEnvironment()
        self.projectPath = projectPath
        self.timeLimitCheckInterval = timeLimitCheckInterval
        self.coverageStrategy = coverageStrategy
        self.edgeHook = edgeHook
        self.sourceLocation = SourceLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}
