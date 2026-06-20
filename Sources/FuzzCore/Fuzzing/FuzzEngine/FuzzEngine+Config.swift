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

import Foundation
import Testing

/// Configuration for the fuzzing run.
public struct FuzzEngineConfig: Sendable {
    /// Maximum time to spend fuzzing.
    public var maxDuration: Duration

    /// Verbose logging.
    public var verbose: Bool

    /// Project root path for filtering coverage gaps to project files only.
    /// When set, only reports gaps in files under this path.
    public let projectPath: String?

    /// Source location where the fuzz test was called.
    /// Used for reporting failures and plugin actions.
    public let sourceLocation: SourceLocation

    /// How often to check the time limit (in iterations).
    /// Higher values reduce overhead from Date.init() calls but may overshoot the time limit slightly.
    /// Default: 1000 (checks ~10K times/sec at 10M iterations/sec, ~3x faster than per-iteration).
    /// Tests that need precise iteration control should use 1.
    public let timeLimitCheckInterval: Int

    /// How many single-step mutants a bus plugin's `.selectForMutation` action
    /// queues. This is the flat-plugin-bus mutation path (distinct from the
    /// scheduler, which owns its own production); the engine queues this many
    /// mutants of the supplied input. Default: 16.
    public let mutationBurstLength: Int

    public init(
        maxDuration: Duration = .seconds(60),
        verbose: Bool = false,
        projectPath: String? = nil,
        timeLimitCheckInterval: Int = 1000,
        mutationBurstLength: Int = 16,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        self.maxDuration = maxDuration
        self.verbose = verbose
        self.projectPath = projectPath
        self.timeLimitCheckInterval = timeLimitCheckInterval
        self.mutationBurstLength = max(1, mutationBurstLength)
        self.sourceLocation = SourceLocation(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}
