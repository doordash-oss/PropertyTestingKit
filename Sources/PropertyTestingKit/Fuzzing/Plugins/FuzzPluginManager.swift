//
//  FuzzPluginManager.swift
//  PropertyTestingKit
//
//  Manages plugin lifecycle during fuzzing.
//

import Foundation

/// Manages plugin execution during fuzzing.
/// This is an internal helper that coordinates calling all plugins at appropriate lifecycle points.
struct FuzzPluginManager: @unchecked Sendable {
    /// Observer plugins (read-only lifecycle notifications).
    private let observers: [any FuzzObserverPlugin]

    /// Stopping condition plugins (influence when to stop).
    /// Stored as mutable copies for tracking state.
    private var stoppingConditions: [any StoppingConditionPlugin]

    /// Analysis plugins (post-fuzzing analysis).
    private let analysisPlugins: [any AnalysisPlugin]

    /// Shrinking plugin for minimizing failing inputs.
    private let shrinkingPlugin: (any ShrinkingPlugin)?

    /// Whether any stopping plugins are configured.
    var hasStoppingPlugins: Bool {
        !stoppingConditions.isEmpty
    }

    /// Whether shrinking is enabled.
    var hasShrinkingEnabled: Bool {
        shrinkingPlugin?.isEnabled ?? false
    }

    /// Get the shrinking configuration (if available).
    var shrinkingConfig: ShrinkConfig? {
        guard let plugin = shrinkingPlugin, plugin.isEnabled else { return nil }
        return plugin.config
    }

    /// Initialize the plugin manager with plugin arrays.
    ///
    /// - Parameters:
    ///   - observerPlugins: Observer plugins for lifecycle notifications.
    ///   - stoppingPlugins: Stopping condition plugins.
    ///   - analysisPlugins: Analysis plugins.
    ///   - shrinkingPlugin: Plugin for shrinking failing inputs.
    init(
        observerPlugins: [any FuzzObserverPlugin],
        stoppingPlugins: [any StoppingConditionPlugin],
        analysisPlugins: [any AnalysisPlugin],
        shrinkingPlugin: (any ShrinkingPlugin)? = nil
    ) {
        self.observers = observerPlugins.sorted { $0.priority > $1.priority }
        self.stoppingConditions = stoppingPlugins.sorted { $0.priority > $1.priority }
        self.analysisPlugins = analysisPlugins.sorted { $0.priority > $1.priority }
        self.shrinkingPlugin = shrinkingPlugin
    }

    // MARK: - Observer Lifecycle

    /// Notify observers that fuzzing has started.
    func notifyStart(context: FuzzPluginContext.StartContext) async {
        for observer in observers {
            await observer.onStart(context: context)
        }
    }

    /// Notify observers of an iteration result.
    func notifyIteration(context: FuzzPluginContext.IterationContext) async {
        for observer in observers {
            await observer.onIteration(context: context)
        }
    }

    /// Notify observers that a batch completed.
    func notifyBatchComplete(context: FuzzPluginContext.BatchContext) async {
        for observer in observers {
            await observer.onBatchComplete(context: context)
        }
    }

    /// Notify observers that fuzzing has ended.
    func notifyEnd(context: FuzzPluginContext.EndContext) async {
        for observer in observers {
            await observer.onEnd(context: context)
        }
    }

    // MARK: - Stopping Conditions

    /// Record an iteration for all stopping condition plugins.
    mutating func recordIteration(discoveredNewCoverage: Bool) {
        for i in stoppingConditions.indices {
            stoppingConditions[i].recordIteration(discoveredNewCoverage: discoveredNewCoverage)
        }
    }

    /// Check if any stopping condition wants to stop.
    ///
    /// - Parameter context: Current stopping context.
    /// - Returns: The stop reason if any plugin wants to stop, nil otherwise.
    func shouldStop(context: FuzzPluginContext.StoppingContext) -> String? {
        for plugin in stoppingConditions {
            let decision = plugin.shouldStop(context: context)
            if case .stop(let reason) = decision {
                return reason
            }
        }
        return nil
    }

    /// Get statistics from all stopping condition plugins.
    func stoppingStats() -> [StoppingConditionStats] {
        stoppingConditions.map { $0.stats() }
    }

    // MARK: - Analysis

    /// Run all analysis plugins and collect reports.
    ///
    /// - Parameter context: Analysis context with coverage data.
    /// - Returns: Array of type-erased analysis reports.
    func runAnalysis(context: FuzzPluginContext.AnalysisContext) async -> [AnyAnalysisReport] {
        // Ensure DWARF source location cache is ready before analysis
        // (pre-warming started at fuzzing begin, this ensures it's complete)
        await SanCovCounters.awaitSourceLocationPreWarming()

        var reports: [AnyAnalysisReport] = []

        for plugin in analysisPlugins {
            let report = await runSingleAnalysis(plugin: plugin, context: context)
            reports.append(report)
        }

        return reports
    }

    /// Run a single analysis plugin (helper to handle associated types).
    private func runSingleAnalysis<P: AnalysisPlugin>(
        plugin: P,
        context: FuzzPluginContext.AnalysisContext
    ) async -> AnyAnalysisReport {
        let report = await plugin.analyze(context: context)
        let issues = plugin.issues(from: report)

        // Generate summary based on report type
        let summary: String
        if let gapReport = report as? CoverageGapReport {
            summary = gapReport.summary
        } else {
            summary = "Analysis complete"
        }

        return AnyAnalysisReport(
            pluginId: plugin.id,
            report: report,
            summary: summary,
            issues: issues
        )
    }

    /// Check if coverage gap detection is enabled.
    var hasGapDetection: Bool {
        analysisPlugins.contains { $0 is CoverageGapPlugin }
    }

    /// Get plateau statistics if the plateau detector plugin is present.
    func getPlateauStats() -> PlateauStats? {
        for plugin in stoppingConditions {
            if let plateauPlugin = plugin as? PlateauDetectorPlugin {
                return plateauPlugin.plateauStats()
            }
        }
        return nil
    }

    // MARK: - Shrinking

    /// Notify the shrinking plugin that shrinking is starting.
    func notifyShrinkingStart(originalSize: Int, error: Error) async {
        await shrinkingPlugin?.onShrinkingStart(originalSize: originalSize, error: error)
    }

    /// Notify the shrinking plugin of progress.
    func notifyShrinkingProgress(candidatesTested: Int, currentSize: Int, originalSize: Int) async {
        await shrinkingPlugin?.onShrinkingProgress(
            candidatesTested: candidatesTested,
            currentSize: currentSize,
            originalSize: originalSize
        )
    }

    /// Notify the shrinking plugin that shrinking is complete.
    func notifyShrinkingComplete(stats: ShrinkStats) async {
        await shrinkingPlugin?.onShrinkingComplete(stats: stats)
    }
}
