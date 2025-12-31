//
//  EventBasedCoverageGapPlugin.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation

public struct EventBasedCoverageGapPlugin: EventBasedPlugin {
    private let detector: CoverageGapDetector

    /// Create a coverage gap analysis plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for gap detection.
    ///   - priority: Plugin priority (higher runs first). Default is 0.
    public init(config: CoverageGapDetector.Config = .init()) {
        self.detector = CoverageGapDetector(config: config)
    }

    mutating func handle<each T>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction] {
        switch event {
        case let .end(endContext):
            let coverageGapReport = await detector
                .detect(
                    from: endContext.totalCoveredIndices,
                    projectPath: endContext.projectPath
                )

            for issue in constructIssues(report: coverageGapReport, endContext: endContext) {
                Issue.record(Comment(rawValue: issue.message), sourceLocation: issue.location)
            }

            return []
        default:
            return []
        }
    }

    private func constructIssues<each T>(report: CoverageGapReport, endContext: PluginEvent<repeat each T>.EndContext) -> [(message: String, location: SourceLocation)] {
        guard !report.gaps.isEmpty else { return [] }

        return report.gaps.map { gap in
            let file = URL(fileURLWithPath: gap.filename).lastPathComponent
            let pct = String(format: "%.0f", gap.coveragePercentage)
            // TODO: We should always have lines. Determine in what situations we don't have lines.
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

            // Place issues at the location of the gap if we have it, otherwise
            // place it at the location of the fuzz call
            let sourceLocation = if let line = (gap.uncoveredRegions.map(\.lineStart).filter { $0 > 0 }.first) {
                SourceLocation(
                    fileID: gap.filename,
                    filePath: gap.filename,
                    line: line,
                    column: 1
                )
            } else {
                SourceLocation(
                    fileID: endContext.testFilePath,
                    filePath: endContext.testFilePath,
                    line: endContext.testFunctionLine,
                    column: 1
                )
            }

            return (message: message, sourceLocation)
        }
    }
}
