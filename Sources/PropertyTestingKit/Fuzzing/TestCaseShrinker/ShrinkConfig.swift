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
//  ShrinkConfig.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Configuration for test case shrinking.
public struct ShrinkConfig: Sendable {
    /// Maximum number of test executions during shrinking.
    /// Prevents runaway shrinking on complex inputs.
    public var maxExecutions: Int

    /// Maximum time to spend shrinking.
    public var timeout: TimeInterval

    /// Whether to enable verbose logging during shrinking.
    public var verbose: Bool

    /// Initial granularity for delta debugging (number of partitions).
    /// Larger values find smaller reductions faster but may miss some.
    public var initialGranularity: Int

    /// Minimum granularity (stop subdividing when partitions reach this size).
    public var minGranularity: Int

    public init(
        maxExecutions: Int = 1000,
        timeout: TimeInterval = 30,
        verbose: Bool = false,
        initialGranularity: Int = 2,
        minGranularity: Int = 1
    ) {
        self.maxExecutions = maxExecutions
        self.timeout = timeout
        self.verbose = verbose
        self.initialGranularity = max(2, initialGranularity)
        self.minGranularity = max(1, minGranularity)
    }
}
