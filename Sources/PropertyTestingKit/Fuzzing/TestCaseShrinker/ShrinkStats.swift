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

/// Statistics about a shrinking run.
struct ShrinkStats: Sendable {
    /// Number of candidates tested.
    let candidatesTested: Int

    /// Original input size (element count).
    let originalSize: Int

    /// Minimized input size (element count).
    let minimizedSize: Int

    /// Time spent shrinking.
    let duration: TimeInterval

    /// Whether shrinking timed out.
    let timedOut: Bool

    /// Whether max executions was reached.
    let maxExecutionsReached: Bool

    /// Empty stats for non-shrinkable types.
    static let empty = ShrinkStats(
        candidatesTested: 0,
        originalSize: 0,
        minimizedSize: 0,
        duration: 0,
        timedOut: false,
        maxExecutionsReached: false
    )

    init(
        candidatesTested: Int,
        originalSize: Int,
        minimizedSize: Int,
        duration: TimeInterval,
        timedOut: Bool,
        maxExecutionsReached: Bool
    ) {
        self.candidatesTested = candidatesTested
        self.originalSize = originalSize
        self.minimizedSize = minimizedSize
        self.duration = duration
        self.timedOut = timedOut
        self.maxExecutionsReached = maxExecutionsReached
    }

    /// Combine multiple stats into one aggregate.
    static func combined(_ stats: [ShrinkStats]) -> ShrinkStats {
        ShrinkStats(
            candidatesTested: stats.reduce(0) { $0 + $1.candidatesTested },
            originalSize: stats.reduce(0) { $0 + $1.originalSize },
            minimizedSize: stats.reduce(0) { $0 + $1.minimizedSize },
            duration: stats.reduce(0) { $0 + $1.duration },
            timedOut: stats.contains { $0.timedOut },
            maxExecutionsReached: stats.contains { $0.maxExecutionsReached }
        )
    }

    /// Reduction ratio (0.0 = no reduction, 1.0 = reduced to nothing).
    var reductionRatio: Double {
        guard originalSize > 0 else { return 0 }
        return 1.0 - Double(minimizedSize) / Double(originalSize)
    }

    /// Generate a human-readable report.
    func report() -> String {
        var lines: [String] = []
        lines.append("Shrinking Statistics:")
        lines.append("  Original size: \(originalSize) elements")
        lines.append("  Minimized size: \(minimizedSize) elements")
        lines.append("  Reduction: \(String(format: "%.1f%%", reductionRatio * 100))")
        lines.append("  Candidates tested: \(candidatesTested)")
        lines.append("  Duration: \(String(format: "%.2fs", duration))")
        if timedOut {
            lines.append("  Note: Shrinking timed out")
        }
        if maxExecutionsReached {
            lines.append("  Note: Max executions reached")
        }
        return lines.joined(separator: "\n")
    }
}
