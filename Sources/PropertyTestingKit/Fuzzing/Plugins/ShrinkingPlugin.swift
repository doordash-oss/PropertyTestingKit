//
//  ShrinkingPlugin.swift
//  PropertyTestingKit
//
//  Plugin protocol for shrinking failing inputs to minimal reproducing cases.
//

import Foundation

// MARK: - Shrinking Plugin Protocol

/// Plugin protocol for shrinking failing inputs to minimal reproducing cases.
///
/// Shrinking uses delta debugging to systematically reduce failing inputs
/// while preserving the failure condition. This makes debugging much easier
/// by providing minimal reproduction cases.
///
/// ## Usage
///
/// ```swift
/// // Enable shrinking with default settings
/// try fuzz(shrinkingPlugin: .default()) { (input: String) in
///     // test code
/// }
///
/// // Custom shrinking configuration
/// try fuzz(shrinkingPlugin: .default(config: ShrinkConfig(
///     maxExecutions: 500,
///     timeout: 15,
///     verbose: true
/// ))) { (input: String) in
///     // test code
/// }
///
/// // Disable shrinking
/// try fuzz(shrinkingPlugin: nil) { ... }
/// ```
public protocol ShrinkingPlugin: FuzzPlugin {
    /// Configuration for shrinking behavior.
    var config: ShrinkConfig { get }

    /// Whether shrinking is enabled.
    var isEnabled: Bool { get }

    /// Called before shrinking begins.
    ///
    /// - Parameters:
    ///   - originalSize: The size of the original failing input.
    ///   - error: The error that was thrown.
    func onShrinkingStart(originalSize: Int, error: Error) async

    /// Called periodically during shrinking with progress updates.
    ///
    /// - Parameters:
    ///   - candidatesTested: Number of candidates tested so far.
    ///   - currentSize: Current minimized size.
    ///   - originalSize: Original input size.
    func onShrinkingProgress(candidatesTested: Int, currentSize: Int, originalSize: Int) async

    /// Called when shrinking completes.
    ///
    /// - Parameter stats: Statistics about the shrinking run.
    func onShrinkingComplete(stats: ShrinkStats) async
}

// MARK: - Default Implementations

extension ShrinkingPlugin {
    public var isEnabled: Bool { true }

    public func onShrinkingStart(originalSize: Int, error: Error) async {}

    public func onShrinkingProgress(candidatesTested: Int, currentSize: Int, originalSize: Int) async {}

    public func onShrinkingComplete(stats: ShrinkStats) async {}
}

// MARK: - Shrinking Context

extension FuzzPluginContext {
    /// Context provided when a failure is being shrunk.
    public struct ShrinkingContext: Sendable {
        /// Size of the original failing input.
        public let originalSize: Int
        /// The error that triggered shrinking.
        public let error: any Error
        /// Configuration being used for shrinking.
        public let config: ShrinkConfig

        public init(originalSize: Int, error: any Error, config: ShrinkConfig) {
            self.originalSize = originalSize
            self.error = error
            self.config = config
        }
    }
}

// MARK: - Shrunk Failure

/// A failure that has been minimized through shrinking.
public struct ShrunkFailure<Input: Sendable>: Sendable {
    /// The minimized input that still triggers the failure.
    public let minimizedInput: Input

    /// The original (unminimized) input.
    public let originalInput: Input

    /// The error thrown by the test.
    public let error: any Error

    /// Statistics about the shrinking process.
    public let shrinkStats: ShrinkStats

    public init(
        minimizedInput: Input,
        originalInput: Input,
        error: any Error,
        shrinkStats: ShrinkStats
    ) {
        self.minimizedInput = minimizedInput
        self.originalInput = originalInput
        self.error = error
        self.shrinkStats = shrinkStats
    }
}
