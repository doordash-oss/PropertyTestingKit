//
//  CorpusClient.swift
//  PropertyTestingKit
//
//  Dependency for creating corpus instances with generic type support.
//

import Dependencies
import Foundation

// MARK: - Corpus Registry

/// Registry for corpus instances.
///
/// Provides a factory for creating corpus instances with the appropriate type.
/// The Corpus type is ~Copyable (non-copyable) for performance optimization,
/// so it cannot be wrapped in closure-based clients.
struct CorpusRegistry: Sendable {
    /// Create a corpus for the given input types.
    func getCorpus<each Input: Codable & Sendable>() -> Corpus<repeat each Input> {
        return Corpus<repeat each Input>()
    }

    /// Create a corpus that always considers inputs interesting (for testing).
    func getCorpusAlwaysInteresting<each Input: Codable & Sendable>() -> Corpus<repeat each Input> {
        return Corpus<repeat each Input>(alwaysInteresting: true)
    }
}

extension CorpusRegistry: CorpusRegistryProtocol {}

protocol CorpusRegistryProtocol: Sendable {
    func getCorpus<each T: Codable & Sendable>() -> Corpus<repeat each T>
    func getCorpusAlwaysInteresting<each T: Codable & Sendable>() -> Corpus<repeat each T>
}

// MARK: - Dependency Key

private struct CorpusRegistryKey: DependencyKey {
    static let liveValue: CorpusRegistryProtocol = CorpusRegistry()
    static let testValue: CorpusRegistryProtocol = liveValue
}

extension DependencyValues {
    /// Registry for corpus instances.
    ///
    /// Use this to create type-specific corpus instances:
    ///
    /// ```swift
    /// @Dependency(\.corpusRegistry) var registry
    /// var corpus: Corpus<Int> = registry.getCorpus()
    /// ```
    var corpusRegistry: CorpusRegistryProtocol {
        get { self[CorpusRegistryKey.self] }
        set { self[CorpusRegistryKey.self] = newValue }
    }
}
