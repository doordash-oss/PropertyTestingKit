//
//  EventBasedCoverageGapPlugin.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation

public struct EventBasedCoverageGapPlugin: EventBasedPlugin {
    public var id: String { "coverage_gap" }

    private let detector: CoverageGapDetector

    /// Create a coverage gap analysis plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for gap detection.
    public init(config: CoverageGapDetector.Config = .init()) {
        self.detector = CoverageGapDetector(config: config)
    }

    public func handle<each T: Sendable>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .end(endContext):
            let coverageGapReport = await detector
                .detect(
                    from: endContext.totalCoveredIndices,
                    projectPath: endContext.projectPath
                )

            return constructIssueActions(report: coverageGapReport, endContext: endContext)
        default:
            return []
        }
    }

    private func constructIssueActions<each T: Sendable>(
        report: CoverageGapReport,
        endContext: PluginEvent<repeat each T>.EndContext
    ) -> [FuzzPluginAction<repeat each T>] {
        // Skip if no gaps or no source location to attach issues to
        guard !report.gaps.isEmpty, let sourceLocation = endContext.sourceLocation else { return [] }

        return report.gaps.map { gap in
            let file = URL(fileURLWithPath: gap.filename).lastPathComponent
            let pct = String(format: "%.0f", gap.coveragePercentage)
            // Include line info in the message since we can't create SourceLocation
            // from runtime strings (SourceLocation requires compile-time StaticStrings)
            let lines = gap.uncoveredRegions
                .map { $0.lineStart }
                .filter { $0 > 0 }
                .prefix(5)
                .map(String.init)
                .joined(separator: ", ")

            let message = if lines.isEmpty {
                "Coverage gap: \(gap.functionName) in \(file) is \(pct)% covered"
            } else {
                "Coverage gap: \(gap.functionName) in \(file) is \(pct)% covered (lines: \(lines))"
            }

            // Use the source location from the fuzz call since we can't create
            // SourceLocation from runtime strings (it requires compile-time StaticStrings)
            return .recordIssue(FuzzPluginAction<repeat each T>.IssueAction(
                comment: Comment(rawValue: message),
                sourceLocation: sourceLocation
            ))
        }
    }
}
