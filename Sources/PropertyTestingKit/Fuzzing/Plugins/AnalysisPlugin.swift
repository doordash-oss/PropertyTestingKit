//
//  AnalysisPlugin.swift
//  PropertyTestingKit
//
//  Plugins that analyze fuzzing results after completion.
//

import Foundation

// MARK: - Analysis Plugin Protocol

/// Plugin protocol for post-fuzzing analysis.
/// These plugins run after fuzzing completes and produce reports.
public protocol AnalysisPlugin: FuzzPlugin {
    /// The type of report this plugin produces.
    associatedtype Report: Sendable

    /// Analyze fuzzing results and produce a report.
    ///
    /// - Parameter context: Analysis context with coverage data.
    /// - Returns: A report of the analysis results.
    func analyze(context: FuzzPluginContext.AnalysisContext) async -> Report

    /// Generate test issues from the analysis report.
    /// These will be recorded as warnings in Swift Testing.
    ///
    /// - Parameter report: The report from `analyze()`.
    /// - Returns: Array of issue messages to report.
    func issues(from report: Report) -> [String]
}

// MARK: - Default Implementations

extension AnalysisPlugin {
    public func issues(from report: Report) -> [String] {
        []
    }
}

// MARK: - Type-Erased Analysis Report

/// Type-erased container for analysis reports.
/// Allows storing different report types in a collection.
public struct AnyAnalysisReport: Sendable {
    /// The plugin ID that produced this report.
    public let pluginId: String

    /// The wrapped report (type-erased).
    private let _report: any Sendable

    /// Summary of the report for display.
    public let summary: String

    /// Issues generated from this report.
    public let issues: [String]

    public init<R: Sendable>(
        pluginId: String,
        report: R,
        summary: String,
        issues: [String]
    ) {
        self.pluginId = pluginId
        self._report = report
        self.summary = summary
        self.issues = issues
    }

    /// Attempt to retrieve the report as a specific type.
    public func report<R>(as type: R.Type) -> R? {
        _report as? R
    }
}
