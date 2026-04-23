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

/// A coverage gap in a partially-covered function.
struct CoverageGap: Sendable, Equatable {
    /// The function name containing the gap.
    let functionName: String

    /// Source file path.
    let filename: String

    /// Uncovered regions within this function.
    let uncoveredRegions: [UncoveredRegion]

    /// Number of covered edges in this function.
    let coveredEdgeCount: Int

    /// Total number of edges in this function.
    let totalEdgeCount: Int

    /// Coverage percentage for this function.
    var coveragePercentage: Double {
        totalEdgeCount > 0 ? Double(coveredEdgeCount) / Double(totalEdgeCount) * 100 : 0
    }

    /// Whether this gap is significant (more than one uncovered edge).
    var isSignificant: Bool {
        uncoveredRegions.count > 1 || (totalEdgeCount > 2 && coveragePercentage < 90)
    }

    init(
        functionName: String,
        filename: String,
        uncoveredRegions: [UncoveredRegion],
        coveredEdgeCount: Int,
        totalEdgeCount: Int
    ) {
        self.functionName = functionName
        self.filename = filename
        self.uncoveredRegions = uncoveredRegions
        self.coveredEdgeCount = coveredEdgeCount
        self.totalEdgeCount = totalEdgeCount
    }
}
