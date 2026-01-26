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
public struct CorpusClient<each Input: Codable & Sendable>: Sendable {
    // MARK: - Properties

    public var count: @Sendable () -> Int
    public var isEmpty: @Sendable () -> Bool
    public var entries: @Sendable () -> [CorpusEntry<repeat each Input>]
    public var inputs: @Sendable () -> [(repeat each Input)]
    public var signatures: @Sendable () -> [CoverageSignature]
    public var totalCoverage: @Sendable () -> CoverageSignature
    public var updatedAt: @Sendable () -> Date
    public var createdAt: @Sendable () -> Date
    public var failureCount: @Sendable () -> Int
    public var hangCount: @Sendable () -> Int
    public var failureEntries: @Sendable () -> [CorpusEntry<repeat each Input>]
    public var hangEntries: @Sendable () -> [CorpusEntry<repeat each Input>]

    // MARK: - Batch Operations

    /// Get all commonly-needed corpus state in a single call.
    public var batchState: @Sendable () -> CorpusBatchState<repeat each Input>

    // MARK: - Mutating Operations

    public var addIfInteresting: @Sendable ((repeat each Input), CoverageSignature) -> Bool
    public var addIfInterestingSparse: @Sendable ((repeat each Input), SparseCoverage) -> Bool
    public var batchAddIfInteresting: @Sendable ([Corpus<repeat each Input>.CandidateEntry]) -> [Bool]
    public var add: @Sendable ((repeat each Input), CoverageSignature, CorpusEntryType, FailureInfo?) -> Void
    public var minimized: @Sendable () -> CorpusSnapshot<repeat each Input>
    public var snapshot: @Sendable () -> CorpusSnapshot<repeat each Input>

    public init(
        count: @escaping @Sendable () -> Int,
        isEmpty: @escaping @Sendable () -> Bool,
        entries: @escaping @Sendable () -> [CorpusEntry<repeat each Input>],
        inputs: @escaping @Sendable () -> [(repeat each Input)],
        signatures: @escaping @Sendable () -> [CoverageSignature],
        totalCoverage: @escaping @Sendable () -> CoverageSignature,
        updatedAt: @escaping @Sendable () -> Date,
        createdAt: @escaping @Sendable () -> Date,
        failureCount: @escaping @Sendable () -> Int,
        hangCount: @escaping @Sendable () -> Int,
        failureEntries: @escaping @Sendable () -> [CorpusEntry<repeat each Input>],
        hangEntries: @escaping @Sendable () -> [CorpusEntry<repeat each Input>],
        batchState: @escaping @Sendable () -> CorpusBatchState<repeat each Input>,
        addIfInteresting: @escaping @Sendable ((repeat each Input), CoverageSignature) -> Bool,
        addIfInterestingSparse: @escaping @Sendable ((repeat each Input), SparseCoverage) -> Bool,
        batchAddIfInteresting: @escaping @Sendable ([Corpus<repeat each Input>.CandidateEntry]) -> [Bool],
        add: @escaping @Sendable ((repeat each Input), CoverageSignature, CorpusEntryType, FailureInfo?) -> Void,
        minimized: @escaping @Sendable () -> CorpusSnapshot<repeat each Input>,
        snapshot: @escaping @Sendable () -> CorpusSnapshot<repeat each Input>
    ) {
        self.count = count
        self.isEmpty = isEmpty
        self.entries = entries
        self.inputs = inputs
        self.signatures = signatures
        self.totalCoverage = totalCoverage
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.failureCount = failureCount
        self.hangCount = hangCount
        self.failureEntries = failureEntries
        self.hangEntries = hangEntries
        self.batchState = batchState
        self.addIfInteresting = addIfInteresting
        self.addIfInterestingSparse = addIfInterestingSparse
        self.batchAddIfInteresting = batchAddIfInteresting
        self.add = add
        self.minimized = minimized
        self.snapshot = snapshot
    }

    /// Create a live client backed by a Corpus instance.
    public static func live() -> CorpusClient<repeat each Input> {
        let corpus = Corpus<repeat each Input>()
        return live(corpus: corpus)
    }

    /// Create a live client backed by an existing Corpus instance.
    public static func live(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        return CorpusClient<repeat each Input>(
            count: { corpus.count },
            isEmpty: { corpus.isEmpty },
            entries: { corpus.entries },
            inputs: { corpus.inputs },
            signatures: { corpus.signatures },
            totalCoverage: { corpus.totalCoverage },
            updatedAt: { corpus.updatedAt },
            createdAt: { corpus.createdAt },
            failureCount: { corpus.failureCount },
            hangCount: { corpus.hangCount },
            failureEntries: { corpus.failureEntries },
            hangEntries: { corpus.hangEntries },
            batchState: { corpus.batchState() },
            addIfInteresting: { input, signature in
                corpus.addIfInteresting(input: input, signature: signature)
            },
            addIfInterestingSparse: { input, sparse in
                corpus.addIfInterestingSparse(input: input, sparse: sparse)
            },
            batchAddIfInteresting: { candidates in
                corpus.batchAddIfInteresting(candidates)
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
    public static func alwaysInteresting() -> CorpusClient<repeat each Input> {
        let corpus = Corpus<repeat each Input>()
        return CorpusClient<repeat each Input>(
            count: { corpus.count },
            isEmpty: { corpus.isEmpty },
            entries: { corpus.entries },
            inputs: { corpus.inputs },
            signatures: { corpus.signatures },
            totalCoverage: { corpus.totalCoverage },
            updatedAt: { corpus.updatedAt },
            createdAt: { corpus.createdAt },
            failureCount: { corpus.failureCount },
            hangCount: { corpus.hangCount },
            failureEntries: { corpus.failureEntries },
            hangEntries: { corpus.hangEntries },
            batchState: { corpus.batchState() },
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
            batchAddIfInteresting: { candidates in
                // Always add all candidates to corpus (bypass coverage check)
                for candidate in candidates {
                    corpus.add(
                        input: candidate.input,
                        signature: candidate.signature,
                        entryType: .coverage,
                        failure: nil
                    )
                }
                return [Bool](repeating: true, count: candidates.count)
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
public struct CorpusRegistry: Sendable {
    /// Create a corpus client for the given input types.
    public func get<each Input: Codable & Sendable>() -> CorpusClient<repeat each Input> {
        return CorpusClient.live()
    }

    /// Create a corpus client from an existing corpus.
    public func get<each Input: Codable & Sendable>(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        return CorpusClient.live(corpus: corpus)
    }
}

extension CorpusRegistry: CorpusRegistryProtocol {}

public protocol CorpusRegistryProtocol: Sendable {
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
    public var corpusRegistry: CorpusRegistryProtocol {
        get { self[CorpusRegistryKey.self] }
        set { self[CorpusRegistryKey.self] = newValue }
    }
}
