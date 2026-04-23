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
//  CoverageGapReport.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Report of all coverage gaps found during fuzzing.
struct CoverageGapReport: Sendable, Equatable {
    /// Functions with partial coverage (some edges hit, some not).
    let gaps: [CoverageGap]

    /// Total functions analyzed.
    let totalFunctionsAnalyzed: Int

    /// Functions with complete coverage (100%).
    let fullyCoveredFunctionCount: Int

    /// Functions with no coverage (0%).
    let uncoveredFunctionCount: Int

    /// Whether any significant gaps were found.
    var hasSignificantGaps: Bool {
        gaps.contains { $0.isSignificant }
    }

    /// Summary for display.
    var summary: String {
        if gaps.isEmpty {
            return "No coverage gaps detected in \(totalFunctionsAnalyzed) functions"
        }

        let significantCount = gaps.filter { $0.isSignificant }.count
        var result = "Coverage gaps in \(gaps.count) function(s)"
        if significantCount > 0 && significantCount < gaps.count {
            result += " (\(significantCount) significant)"
        }
        return result
    }

    /// Detailed report for verbose output.
    var detailedSummary: String {
        guard !gaps.isEmpty else {
            return summary
        }

        var lines = [summary]

        for gap in gaps.sorted(by: { $0.coveragePercentage < $1.coveragePercentage }) {
            let file = URL(fileURLWithPath: gap.filename).lastPathComponent
            let pct = String(format: "%.0f", gap.coveragePercentage)
            lines.append("  - \(gap.functionName) (\(file)): \(pct)% covered, \(gap.uncoveredRegions.count) uncovered region(s)")

            // Show first few uncovered regions
            for region in gap.uncoveredRegions.prefix(3) {
                if region.lineStart > 0 {
                    let desc = region.isBranch ? "branch not taken" : "not executed"
                    lines.append("    - Line \(region.lineStart): \(desc)")
                }
            }
            if gap.uncoveredRegions.count > 3 {
                lines.append("    - ... and \(gap.uncoveredRegions.count - 3) more")
            }
        }

        return lines.joined(separator: "\n")
    }

    init(
        gaps: [CoverageGap],
        totalFunctionsAnalyzed: Int,
        fullyCoveredFunctionCount: Int,
        uncoveredFunctionCount: Int
    ) {
        self.gaps = gaps
        self.totalFunctionsAnalyzed = totalFunctionsAnalyzed
        self.fullyCoveredFunctionCount = fullyCoveredFunctionCount
        self.uncoveredFunctionCount = uncoveredFunctionCount
    }
}
