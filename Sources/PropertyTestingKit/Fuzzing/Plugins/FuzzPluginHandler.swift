//
//  FuzzPluginHandler.swift
//  PropertyTestingKit
//
//  Closure-based plugin handler that eliminates protocol witness overhead.
//

import Testing
import Foundation

/// A plugin handler with closures specialized for specific input types.
///
/// This replaces `FuzzPlugin` protocol for the hot path. Instead of generic
/// protocol methods that require runtime dispatch, this struct holds closures
/// that are already specialized for the input types.
public struct FuzzPluginHandler<each Input: Sendable>: Sendable {
    public let id: String

    /// Synchronous event handler - hot path, called millions of times.
    public let handleSync: @Sendable (SyncPluginEvent<repeat each Input>) -> [FuzzPluginAction<repeat each Input>]

    /// Asynchronous event handler - cold path, called rarely.
    public let handleAsync: @Sendable (AsyncPluginEvent<repeat each Input>) async throws -> [FuzzPluginAction<repeat each Input>]

    @inlinable
    public init(
        id: String,
        handleSync: @escaping @Sendable (SyncPluginEvent<repeat each Input>) -> [FuzzPluginAction<repeat each Input>],
        handleAsync: @escaping @Sendable (AsyncPluginEvent<repeat each Input>) async throws -> [FuzzPluginAction<repeat each Input>] = { _ in [] }
    ) {
        self.id = id
        self.handleSync = handleSync
        self.handleAsync = handleAsync
    }
}

// MARK: - Box for Stateful Handlers

/// Simple box for reference semantics. Not thread-safe.
/// Handlers run on a single task so no synchronization needed.
@usableFromInline
final class Box<Value>: @unchecked Sendable {
    @usableFromInline
    var value: Value

    @usableFromInline
    init(_ value: Value) {
        self.value = value
    }
}

// MARK: - Built-in Handlers

extension FuzzPluginHandler {
    /// Creates the mutation handler - selects inputs for mutation when they discover new coverage.
    ///
    /// This is the default handler that implements the core fuzzing feedback loop.
    @inlinable
    public static func mutation() -> FuzzPluginHandler<repeat each Input> {
        FuzzPluginHandler(
            id: "mutation",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    if context.discoveredNewCoverage {
                        return [.selectForMutation(.init(input: context.input))]
                    }
                    return []
                }
            }
        )
    }

    /// Creates a shrinking handler that minimizes failing inputs using delta debugging.
    ///
    /// When a test failure is found, this handler attempts to find a smaller
    /// input that still reproduces the failure, making debugging easier.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - verbose: Whether to print verbose progress during shrinking.
    /// - Returns: A configured shrinking handler.
    public static func shrinking(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) -> FuzzPluginHandler<repeat each Input> where repeat each Input: Sendable {
        FuzzPluginHandler(
            id: "shrinking",
            handleSync: { _ in [] },
            handleAsync: { event in
                switch event {
                case let .failureFound(context):
                    let shrinker = MultiComponentShrinker(config: config)
                    let (minimized, stats) = await shrinker.shrink(input: context.input, test: context.test)

                    // Format minimized input for display
                    let minimizedDescription = formatMinimizedInput(minimized)

                    // Build shrink result message
                    var message = "[Shrink] Minimized failing input"
                    message += "\n  Original size: \(stats.originalSize) elements"
                    message += "\n  Minimized size: \(stats.minimizedSize) elements"
                    message += "\n  Candidates tested: \(stats.candidatesTested)"

                    if stats.minimizedSize < stats.originalSize {
                        let reduction = Double(stats.originalSize - stats.minimizedSize) / Double(stats.originalSize) * 100
                        message += "\n  Reduction: \(String(format: "%.1f", reduction))%"
                    }

                    message += "\n  Minimized input: \(minimizedDescription)"

                    if verbose {
                        print(message)
                    }

                    // Return actions: select for mutation, add to corpus, and record issue
                    return [
                        .selectForMutation(.init(input: minimized)),
                        .submitToCorpus(.init(
                            input: minimized,
                            coverageSignature: context.coverageSignature,
                            entryType: .failure
                        )),
                        .recordIssue(.init(
                            comment: Comment(rawValue: message),
                            sourceLocation: context.sourceLocation
                        ))
                    ]
                case .start, .end:
                    return []
                }
            }
        )
    }

    /// Creates a simple plateau detector that stops when no new coverage is found.
    ///
    /// - Parameter config: Configuration for plateau detection.
    /// - Returns: A configured plateau detector handler.
    public static func plateauDetector(
        config: SimpleCoveragePlateauDetector.Config = .init()
    ) -> FuzzPluginHandler<repeat each Input> {
        let detector = Box(SimpleCoveragePlateauDetector(config: config))

        return FuzzPluginHandler(
            id: "plateau_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.value.record(discoveredNewCoverage: context.discoveredNewCoverage)

                    if detector.value.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("coverage_plateaued")))]
                    }

                    return []
                }
            }
        )
    }

    /// Creates a STADS plateau detector using Good-Turing estimator.
    ///
    /// Uses statistical principles from species discovery to estimate the
    /// probability of finding new coverage. More principled than simple
    /// window-based approaches.
    ///
    /// - Parameters:
    ///   - minDiscoveryProbability: Minimum probability before declaring plateau. Default is 0.001.
    ///   - confirmationChecks: Consecutive low-probability checks required. Default is 3.
    ///   - checkInterval: Iterations between probability recalculations. Default is 100.
    /// - Returns: A configured STADS plateau detector handler.
    public static func stadsDetector(
        minDiscoveryProbability: Double = 0.001,
        confirmationChecks: Int = 3,
        checkInterval: Int = 100
    ) -> FuzzPluginHandler<repeat each Input> {
        stadsDetector(config: .init(
            minDiscoveryProbability: minDiscoveryProbability,
            confirmationChecks: confirmationChecks,
            checkInterval: checkInterval
        ))
    }

    /// Creates a STADS plateau detector with custom configuration.
    ///
    /// - Parameter config: The STADS detector configuration.
    /// - Returns: A configured STADS plateau detector handler.
    public static func stadsDetector(
        config: STADSPlateauDetector.Config
    ) -> FuzzPluginHandler<repeat each Input> {
        let detector = Box(STADSPlateauDetector(config: config))

        return FuzzPluginHandler(
            id: "stads_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.value.record(discoveredNewCoverage: context.discoveredNewCoverage)

                    if detector.value.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("stads_plateau")))]
                    }

                    return []
                }
            }
        )
    }

    /// Creates a saturation plateau detector using saturation-based metrics.
    ///
    /// Models coverage growth as an asymptotic process and stops when saturation
    /// approaches the estimated maximum coverage.
    ///
    /// - Parameters:
    ///   - minSaturation: Saturation level (0-1) to declare plateau. Default is 0.99.
    ///   - minGrowthRate: Minimum growth rate before plateau. Default is 0.0001.
    ///   - windowSize: Window size for growth rate calculation. Default is 500.
    ///   - confirmationWindows: Consecutive low-growth windows required. Default is 3.
    /// - Returns: A configured saturation plateau detector handler.
    public static func saturationDetector(
        minSaturation: Double = 0.99,
        minGrowthRate: Double = 0.0001,
        windowSize: Int = 500,
        confirmationWindows: Int = 3
    ) -> FuzzPluginHandler<repeat each Input> {
        saturationDetector(config: .init(
            minSaturation: minSaturation,
            minGrowthRate: minGrowthRate,
            windowSize: windowSize,
            confirmationWindows: confirmationWindows
        ))
    }

    /// Creates a saturation plateau detector with custom configuration.
    ///
    /// - Parameter config: The saturation detector configuration.
    /// - Returns: A configured saturation plateau detector handler.
    public static func saturationDetector(
        config: SaturationPlateauDetector.Config
    ) -> FuzzPluginHandler<repeat each Input> {
        let detector = Box(SaturationPlateauDetector(config: config))

        return FuzzPluginHandler(
            id: "saturation_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.value.record(discoveredNewCoverage: context.discoveredNewCoverage)

                    if detector.value.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("saturation_plateau")))]
                    }

                    return []
                }
            }
        )
    }

    /// Creates a coverage gap analysis handler.
    ///
    /// Analyzes coverage at the end of fuzzing and reports gaps in coverage
    /// as issues at the specific source locations.
    ///
    /// - Parameter config: Configuration for gap detection.
    /// - Returns: A configured coverage gap handler.
    public static func coverageGap(
        config: CoverageGapDetector.Config = .init()
    ) -> FuzzPluginHandler<repeat each Input> {
        let detector = CoverageGapDetector(config: config)

        return FuzzPluginHandler(
            id: "coverage_gap",
            handleSync: { _ in [] },
            handleAsync: { event in
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

                    return constructCoverageGapActions(report: coverageGapReport, endContext: endContext)
                case .failureFound:
                    return []
                }
            }
        )
    }
}

// MARK: - Helper Functions

/// Format minimized input for display.
private func formatMinimizedInput<each T>(_ input: (repeat each T)) -> String {
    // Use Mirror to get a readable representation
    let mirror = Mirror(reflecting: input)
    if mirror.children.isEmpty {
        return String(describing: input)
    }

    // For tuples, format each element
    var elements: [String] = []
    for child in mirror.children {
        elements.append(String(describing: child.value))
    }
    return "(\(elements.joined(separator: ", ")))"
}

/// Construct issue actions for coverage gap report.
private func constructCoverageGapActions<each T: Sendable>(
    report: CoverageGapReport,
    endContext: AsyncPluginEvent<repeat each T>.EndContext
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

// MARK: - Processor

/// Processes plugin handlers without protocol witness overhead.
@usableFromInline
struct PluginHandlerProcessor<each Input: Sendable>: Sendable {
    @usableFromInline
    let handlers: [FuzzPluginHandler<repeat each Input>]

    @inlinable
    init(handlers: [FuzzPluginHandler<repeat each Input>]) {
        self.handlers = handlers
    }

    /// Process a synchronous event - hot path.
    @inlinable
    func processSync(
        event: consuming SyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) {
        for handler in handlers {
            let actions = handler.handleSync(copy event)
            for action in actions {
                execute(action)
            }
        }
        _ = consume event
    }

    /// Process an asynchronous event - cold path.
    @inlinable
    func processAsync(
        isolation: isolated (any Actor)? = #isolation,
        event: consuming AsyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) async {
        for handler in handlers {
            do {
                let actions = try await handler.handleAsync(copy event)
                for action in actions {
                    execute(action)
                }
            } catch {
                // Plugin errors are non-fatal
            }
        }
        _ = consume event
    }
}
