//
//  CorpusClient.swift
//  PropertyTestingKit
//
//  Dependency client for corpus operations with generic type support.
//

import Dependencies
import Foundation

// MARK: - Corpus Client

/// Client for corpus operations, allowing dependency injection.
///
/// This struct wraps all corpus operations as closures, enabling:
/// - Mocking in tests (e.g., `addIfInteresting` always returns true)
/// - Type-safe generic operations via the registry pattern
///
/// ## Usage
///
/// ```swift
/// // Get client from registry
/// @Dependency(\.corpusRegistry) var registry
/// let client: CorpusClient<Int, String> = registry.get()
///
/// // Use client operations
/// let wasAdded = client.addIfInteresting((42, "test"), signature)
/// let count = client.count()
/// ```
struct CorpusClient<each Input: Codable & Sendable>: Sendable {
    // MARK: - Properties

    var count: @Sendable () -> Int
    var isEmpty: @Sendable () -> Bool
    var entries: @Sendable () -> [CorpusEntry<repeat each Input>]
    var inputs: @Sendable () -> [(repeat each Input)]
    var totalCoverage: @Sendable () -> CoverageSignature

    // MARK: - Mutating Operations

    var addIfInteresting: @Sendable ((repeat each Input), CoverageSignature) -> Bool
    var addIfInterestingSparse: @Sendable ((repeat each Input), SparseCoverage) -> Bool
    var add: @Sendable ((repeat each Input), CoverageSignature, CorpusEntryType, FailureInfo?) -> Void
    var minimized: @Sendable () -> CorpusSnapshot<repeat each Input>
    var snapshot: @Sendable () -> CorpusSnapshot<repeat each Input>

    init(
        count: @escaping @Sendable () -> Int,
        isEmpty: @escaping @Sendable () -> Bool,
        entries: @escaping @Sendable () -> [CorpusEntry<repeat each Input>],
        inputs: @escaping @Sendable () -> [(repeat each Input)],
        totalCoverage: @escaping @Sendable () -> CoverageSignature,
        addIfInteresting: @escaping @Sendable ((repeat each Input), CoverageSignature) -> Bool,
        addIfInterestingSparse: @escaping @Sendable ((repeat each Input), SparseCoverage) -> Bool,
        add: @escaping @Sendable ((repeat each Input), CoverageSignature, CorpusEntryType, FailureInfo?) -> Void,
        minimized: @escaping @Sendable () -> CorpusSnapshot<repeat each Input>,
        snapshot: @escaping @Sendable () -> CorpusSnapshot<repeat each Input>
    ) {
        self.count = count
        self.isEmpty = isEmpty
        self.entries = entries
        self.inputs = inputs
        self.totalCoverage = totalCoverage
        self.addIfInteresting = addIfInteresting
        self.addIfInterestingSparse = addIfInterestingSparse
        self.add = add
        self.minimized = minimized
        self.snapshot = snapshot
    }

    /// Create a live client backed by a Corpus instance.
    static func live() -> CorpusClient<repeat each Input> {
        let corpus = Corpus<repeat each Input>()
        return live(corpus: corpus)
    }

    /// Create a live client backed by an existing Corpus instance.
    static func live(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        return CorpusClient<repeat each Input>(
            count: { corpus.count },
            isEmpty: { corpus.isEmpty },
            entries: { corpus.entries },
            inputs: { corpus.inputs },
            totalCoverage: { corpus.totalCoverage },
            addIfInteresting: { input, signature in
                corpus.addIfInteresting(input: input, signature: signature)
            },
            addIfInterestingSparse: { input, sparse in
                corpus.addIfInterestingSparse(input: input, sparse: sparse)
            },
            add: { input, signature, entryType, failure in
                corpus.add(input: input, signature: signature, entryType: entryType, failure: failure)
            },
            minimized: { corpus.minimized() },
            snapshot: { corpus.snapshot() }
        )
    }

    /// Create a test client where addIfInteresting always returns true.
    ///
    /// This is useful for tests that want to verify mutation/generation
    /// without needing to mock coverage data.
    static func alwaysInteresting() -> CorpusClient<repeat each Input> {
        let corpus = Corpus<repeat each Input>()
        return CorpusClient<repeat each Input>(
            count: { corpus.count },
            isEmpty: { corpus.isEmpty },
            entries: { corpus.entries },
            inputs: { corpus.inputs },
            totalCoverage: { corpus.totalCoverage },
            addIfInteresting: { input, signature in
                // Always add to corpus (bypass coverage check)
                corpus.add(
                    input: input,
                    signature: signature,
                    entryType: .coverage,
                    failure: nil
                )
                return true
            },
            addIfInterestingSparse: { input, sparse in
                // Always add to corpus (bypass coverage check)
                let signature = CoverageSignature(sparse: sparse)
                corpus.add(
                    input: input,
                    signature: signature,
                    entryType: .coverage,
                    failure: nil
                )
                return true
            },
            add: { input, signature, entryType, failure in
                corpus.add(input: input, signature: signature, entryType: entryType, failure: failure)
            },
            minimized: { corpus.minimized() },
            snapshot: { corpus.snapshot() }
        )
    }
}

// MARK: - Corpus Registry

/// Registry for corpus clients.
///
/// Provides a factory for creating corpus clients with the appropriate type.
struct CorpusRegistry: Sendable {
    /// Create a corpus client for the given input types.
    func get<each Input: Codable & Sendable>() -> CorpusClient<repeat each Input> {
        return CorpusClient.live()
    }

    /// Create a corpus client from an existing corpus.
    func get<each Input: Codable & Sendable>(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        return CorpusClient.live(corpus: corpus)
    }
}

extension CorpusRegistry: CorpusRegistryProtocol {}

protocol CorpusRegistryProtocol: Sendable {
    func get<each T: Codable & Sendable>() -> CorpusClient<repeat each T>
    func get<each T: Codable & Sendable>(corpus: Corpus<repeat each T>) -> CorpusClient<repeat each T>
}

// MARK: - Dependency Key

private struct CorpusRegistryKey: DependencyKey {
    static let liveValue: CorpusRegistryProtocol = CorpusRegistry()
    static let testValue: CorpusRegistryProtocol = liveValue
}

extension DependencyValues {
    /// Registry for corpus clients.
    ///
    /// Use this to create type-specific corpus clients:
    ///
    /// ```swift
    /// @Dependency(\.corpusRegistry) var registry
    /// let client: CorpusClient<Int> = registry.get()
    /// ```
    var corpusRegistry: CorpusRegistryProtocol {
        get { self[CorpusRegistryKey.self] }
        set { self[CorpusRegistryKey.self] = newValue }
    }
}
