//
//  CoverageGapPlugin.swift
//  PropertyTestingKit
//
//  Analysis plugin that detects coverage gaps.
//

import Foundation

/// Analysis plugin that detects coverage gaps in partially-covered functions.
///
/// This plugin wraps `CoverageGapDetector` to identify functions where
/// some edges were executed but others weren't, indicating incomplete testing.
///
/// Usage:
/// ```swift
/// try fuzz(analysisPlugins: [.coverageGaps()]) { input in ... }
/// ```
public struct CoverageGapPlugin: AnalysisPlugin, Sendable {
    public let id: String = "coverageGaps"
    public let priority: Int

    private let detector: CoverageGapDetector

    /// Create a coverage gap analysis plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for gap detection.
    ///   - priority: Plugin priority (higher runs first). Default is 0.
    public init(
        config: CoverageGapDetector.Config = .init(),
        priority: Int = 0
    ) {
        self.detector = CoverageGapDetector(config: config)
        self.priority = priority
    }

    public func analyze(context: FuzzPluginContext.AnalysisContext) async -> CoverageGapReport {
        await detector.detect(
            from: context.totalCoveredIndices,
            projectPath: context.projectPath
        )
    }

    public func issues(from report: CoverageGapReport) -> [String] {
        guard !report.gaps.isEmpty else { return [] }

        return report.gaps.map { gap in
            let file = URL(fileURLWithPath: gap.filename).lastPathComponent
            let pct = String(format: "%.0f", gap.coveragePercentage)
            let lines = gap.uncoveredRegions
                .map { $0.lineStart }
                .filter { $0 > 0 }
                .prefix(5)
                .map(String.init)
                .joined(separator: ", ")

            if lines.isEmpty {
                return "Coverage gap: \(gap.functionName) in \(file) is \(pct)% covered"
            } else {
                return "Coverage gap: \(gap.functionName) in \(file) is \(pct)% covered (lines: \(lines))"
            }
        }
    }
}

// MARK: - Convenience Constructor

extension AnalysisPlugin where Self == CoverageGapPlugin {
    /// Create a coverage gap analysis plugin with default configuration.
    ///
    /// - Returns: A configured coverage gap plugin.
    public static func coverageGaps() -> CoverageGapPlugin {
        CoverageGapPlugin()
    }

    /// Create a coverage gap analysis plugin with custom configuration.
    ///
    /// - Parameter config: The gap detector configuration.
    /// - Returns: A configured coverage gap plugin.
    public static func coverageGaps(
        config: CoverageGapDetector.Config
    ) -> CoverageGapPlugin {
        CoverageGapPlugin(config: config)
    }

    /// Create a coverage gap analysis plugin.
    ///
    /// - Parameters:
    ///   - minCoveragePercentage: Minimum coverage percentage to report as a gap.
    ///   - excludedPathPrefixes: Paths to exclude from gap detection.
    ///   - onlyReportSignificant: Whether to only report significant gaps.
    /// - Returns: A configured coverage gap plugin.
    public static func coverageGaps(
        minCoveragePercentage: Double = 5.0,
        excludedPathPrefixes: [String] = [],
        onlyReportSignificant: Bool = true
    ) -> CoverageGapPlugin {
        CoverageGapPlugin(
            config: .init(
                minCoveragePercentageToReport: minCoveragePercentage,
                excludedPathPrefixes: excludedPathPrefixes,
                onlyReportSignificant: onlyReportSignificant
            )
        )
    }
}
