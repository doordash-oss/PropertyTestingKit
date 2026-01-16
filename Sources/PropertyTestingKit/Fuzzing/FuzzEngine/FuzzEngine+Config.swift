//
//  FuzzEngine+Config.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Testing

extension FuzzEngine {
    /// Configuration for the fuzzing run.
    public struct Config: Sendable {
        /// Maximum time to spend fuzzing.
        public var maxDuration: Duration

        /// Whether to minimize the corpus before saving.
        public let minimizeCorpus: Bool

        /// Verbose logging.
        public var verbose: Bool

        /// Controls how the fuzzer handles existing corpus files.
        /// Defaults to checking the `FUZZ_CORPUS_MODE` environment variable,
        /// then falling back to `.auto`.
        public let corpusMode: CorpusMode

        /// Project root path for filtering coverage gaps to project files only.
        /// When set, only reports gaps in files under this path.
        public let projectPath: String?

        /// Source location where the fuzz test was called.
        /// Used for reporting failures and plugin actions.
        public let sourceLocation: SourceLocation

        // MARK: - Plugin Configuration

        /// User-provided plugins that handle fuzzing events and return actions.
        /// Plugins run in array order for each event, after baseline plugins.
        /// Default: empty (no additional plugins).
        public let plugins: [any FuzzPlugin]

        /// These plugins represent core behavior of the fuzzing engine. Users may alter or remove these,
        /// but doing so could break core functionality.
        public let defaultBehaviorPlugins: [any FuzzPlugin]

        /// All plugins combined: baseline plugins followed by user plugins.
        public var allPlugins: [any FuzzPlugin] {
            defaultBehaviorPlugins + plugins
        }

        public init(
            maxDuration: Duration = .seconds(60),
            minimizeCorpus: Bool = true,
            verbose: Bool = false,
            corpusMode: CorpusMode? = nil,
            projectPath: String? = nil,
            fileID: String = #fileID,
            filePath: String = #filePath,
            line: Int = #line,
            column: Int = #column,
            plugins: [any FuzzPlugin] = [],
            defaultBehaviorPlugins: [any FuzzPlugin] = [MutationPlugin()]
        ) {
            self.maxDuration = maxDuration
            self.minimizeCorpus = minimizeCorpus
            self.verbose = verbose
            // Use provided mode, or check environment, or default to auto
            self.corpusMode = corpusMode ?? CorpusMode.fromEnvironment()
            self.projectPath = projectPath
            self.sourceLocation = SourceLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            self.plugins = plugins
            self.defaultBehaviorPlugins = defaultBehaviorPlugins
        }
    }
}
