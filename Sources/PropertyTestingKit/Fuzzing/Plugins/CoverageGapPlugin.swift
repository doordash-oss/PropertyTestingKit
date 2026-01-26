//
//  CoverageGapPlugin.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation

public struct CoverageGapPlugin: FuzzPlugin {
    public var id: String { "coverage_gap" }

    private let detector: CoverageGapDetector

    /// Create a coverage gap analysis plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for gap detection.
    public init(config: CoverageGapDetector.Config = .init()) {
        self.detector = CoverageGapDetector(config: config)
    }

    public func handle<each T: Sendable>(event: consuming PluginEvent<repeat each T>) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case .start:
            // Get counters ready, resolve source locations up front.
            await SanCovCounters.startPreWarmingSourceLocations()
            return []
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
        guard !report.gaps.isEmpty else { return [] }

        var actions: [FuzzPluginAction<repeat each T>] = []

        for gap in report.gaps {
            let file = URL(fileURLWithPath: gap.filename).lastPathComponent
            let pct = String(format: "%.0f", gap.coveragePercentage)

            // Create an issue for each uncovered region at its actual source location
            for region in gap.uncoveredRegions where region.lineStart > 0 {
                let desc = region.isBranch ? "branch not taken" : "code not executed"
                let message = "Coverage gap: \(gap.functionName) (\(pct)% covered) - \(desc)"

                // Use the region's DWARF-resolved file path if available, else fall back to gap's filename
                let effectiveFilePath = region.filePath ?? gap.filename

                // Construct fileID in "Module/File.swift" format
                let fileID = fileIDFromPath(effectiveFilePath)
                let sourceLocation = SourceLocation(
                    fileID: fileID,
                    filePath: effectiveFilePath,
                    line: region.lineStart,
                    column: max(1, region.columnStart)
                )

                actions.append(.recordIssue(FuzzPluginAction<repeat each T>.IssueAction(
                    comment: Comment(rawValue: message),
                    sourceLocation: sourceLocation
                )))
            }

            // If no regions have line info, fall back to fuzz call location
            if gap.uncoveredRegions.allSatisfy({ $0.lineStart == 0 }) {
                let message = "Coverage gap: \(gap.functionName) in \(file) is \(pct)% covered"
                actions.append(.recordIssue(FuzzPluginAction<repeat each T>.IssueAction(
                    comment: Comment(rawValue: message),
                    sourceLocation: endContext.sourceLocation
                )))
            }
        }

        return actions
    }

    /// Construct a fileID from a file path.
    /// Format: "ModuleName/FileName.swift"
    private func fileIDFromPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent

        // Try to extract module name from path (e.g., "Sources/ModuleName/...")
        let pathComponents = url.pathComponents
        if let sourcesIndex = pathComponents.lastIndex(of: "Sources"),
           sourcesIndex + 1 < pathComponents.count {
            let moduleName = pathComponents[sourcesIndex + 1]
            return "\(moduleName)/\(fileName)"
        }

        // Try "Tests/ModuleName/..."
        if let testsIndex = pathComponents.lastIndex(of: "Tests"),
           testsIndex + 1 < pathComponents.count {
            let moduleName = pathComponents[testsIndex + 1]
            return "\(moduleName)/\(fileName)"
        }

        // Fallback: use parent directory as module name
        if pathComponents.count >= 2 {
            let parentDir = pathComponents[pathComponents.count - 2]
            return "\(parentDir)/\(fileName)"
        }

        // Last resort
        return "Unknown/\(fileName)"
    }
}
