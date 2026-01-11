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
/// This struct wraps all corpus operations as async closures, enabling:
/// - Mocking in tests (e.g., `addIfInteresting` always returns true)
/// - Type-safe generic operations via the registry pattern
///
/// ## Usage
///
/// ```swift
/// // Get client from registry
/// @Dependency(\.corpusRegistry) var registry
/// let client: CorpusClient<Int, String> = await registry.get(schemaVersion: "v1")
///
/// // Use client operations
/// let wasAdded = await client.addIfInteresting((42, "test"), signature)
/// let count = await client.count()
/// ```
public struct CorpusClient<each Input: Codable & Sendable>: Sendable {
    // MARK: - Properties (async closures for actor access)

    public var count: @Sendable () async -> Int
    public var isEmpty: @Sendable () async -> Bool
    public var entries: @Sendable () async -> [CorpusEntry<repeat each Input>]
    public var inputs: @Sendable () async -> [(repeat each Input)]
    public var signatures: @Sendable () async -> [CoverageSignature]
    public var totalCoverage: @Sendable () async -> CoverageSignature
    public var schemaVersion: @Sendable () async -> String
    public var updatedAt: @Sendable () async -> Date
    public var createdAt: @Sendable () async -> Date
    public var failureCount: @Sendable () async -> Int
    public var hangCount: @Sendable () async -> Int
    public var failureEntries: @Sendable () async -> [CorpusEntry<repeat each Input>]
    public var hangEntries: @Sendable () async -> [CorpusEntry<repeat each Input>]

    // MARK: - Batch Operations

    /// Get all commonly-needed corpus state in a single call.
    ///
    /// Use this at the start of batch generation to avoid multiple actor hops:
    /// ```swift
    /// let state = await corpus.batchState()
    /// for _ in 0..<batchSize {
    ///     if state.isEmpty { ... }
    ///     let parent = state.entries.randomElement()?.input
    /// }
    /// ```
    public var batchState: @Sendable () async -> CorpusBatchState<repeat each Input>

    // MARK: - Mutating Operations

    public var addIfInteresting: @Sendable ((repeat each Input), CoverageSignature) async -> Bool
    public var batchAddIfInteresting: @Sendable ([Corpus<repeat each Input>.CandidateEntry]) async -> [Bool]
    public var add: @Sendable ((repeat each Input), CoverageSignature, CorpusEntryType, FailureInfo?) async -> Void
    public var minimized: @Sendable () async -> CorpusSnapshot<repeat each Input>
    public var snapshot: @Sendable () async -> CorpusSnapshot<repeat each Input>

    public init(
        count: @escaping @Sendable () async -> Int,
        isEmpty: @escaping @Sendable () async -> Bool,
        entries: @escaping @Sendable () async -> [CorpusEntry<repeat each Input>],
        inputs: @escaping @Sendable () async -> [(repeat each Input)],
        signatures: @escaping @Sendable () async -> [CoverageSignature],
        totalCoverage: @escaping @Sendable () async -> CoverageSignature,
        schemaVersion: @escaping @Sendable () async -> String,
        updatedAt: @escaping @Sendable () async -> Date,
        createdAt: @escaping @Sendable () async -> Date,
        failureCount: @escaping @Sendable () async -> Int,
        hangCount: @escaping @Sendable () async -> Int,
        failureEntries: @escaping @Sendable () async -> [CorpusEntry<repeat each Input>],
        hangEntries: @escaping @Sendable () async -> [CorpusEntry<repeat each Input>],
        batchState: @escaping @Sendable () async -> CorpusBatchState<repeat each Input>,
        addIfInteresting: @escaping @Sendable ((repeat each Input), CoverageSignature) async -> Bool,
        batchAddIfInteresting: @escaping @Sendable ([Corpus<repeat each Input>.CandidateEntry]) async -> [Bool],
        add: @escaping @Sendable ((repeat each Input), CoverageSignature, CorpusEntryType, FailureInfo?) async -> Void,
        minimized: @escaping @Sendable () async -> CorpusSnapshot<repeat each Input>,
        snapshot: @escaping @Sendable () async -> CorpusSnapshot<repeat each Input>
    ) {
        self.count = count
        self.isEmpty = isEmpty
        self.entries = entries
        self.inputs = inputs
        self.signatures = signatures
        self.totalCoverage = totalCoverage
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.failureCount = failureCount
        self.hangCount = hangCount
        self.failureEntries = failureEntries
        self.hangEntries = hangEntries
        self.batchState = batchState
        self.addIfInteresting = addIfInteresting
        self.batchAddIfInteresting = batchAddIfInteresting
        self.add = add
        self.minimized = minimized
        self.snapshot = snapshot
    }

    /// Create a live client backed by a Corpus actor.
    public static func live(schemaVersion: String) -> CorpusClient<repeat each Input> {
        let corpus = Corpus<repeat each Input>(schemaVersion: schemaVersion)
        return CorpusClient<repeat each Input>(
            count: { await corpus.count },
            isEmpty: { await corpus.isEmpty },
            entries: { await corpus.entries },
            inputs: { await corpus.inputs },
            signatures: { await corpus.signatures },
            totalCoverage: { await corpus.totalCoverage },
            schemaVersion: { corpus.schemaVersion },
            updatedAt: { await corpus.updatedAt },
            createdAt: { corpus.createdAt },
            failureCount: { await corpus.failureCount },
            hangCount: { await corpus.hangCount },
            failureEntries: { await corpus.failureEntries },
            hangEntries: { await corpus.hangEntries },
            batchState: { await corpus.batchState() },
            addIfInteresting: { input, signature in
                await corpus.addIfInteresting(input: input, signature: signature)
            },
            batchAddIfInteresting: { candidates in
                await corpus.batchAddIfInteresting(candidates)
            },
            add: { input, signature, entryType, failure in
                await corpus.add(input: input, signature: signature, entryType: entryType, failure: failure)
            },
            minimized: { await corpus.minimized() },
            snapshot: { await corpus.snapshot() }
        )
    }

    /// Create a live client backed by an existing Corpus actor.
    public static func live(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        return CorpusClient<repeat each Input>(
            count: { await corpus.count },
            isEmpty: { await corpus.isEmpty },
            entries: { await corpus.entries },
            inputs: { await corpus.inputs },
            signatures: { await corpus.signatures },
            totalCoverage: { await corpus.totalCoverage },
            schemaVersion: { corpus.schemaVersion },
            updatedAt: { await corpus.updatedAt },
            createdAt: { corpus.createdAt },
            failureCount: { await corpus.failureCount },
            hangCount: { await corpus.hangCount },
            failureEntries: { await corpus.failureEntries },
            hangEntries: { await corpus.hangEntries },
            batchState: { await corpus.batchState() },
            addIfInteresting: { input, signature in
                await corpus.addIfInteresting(input: input, signature: signature)
            },
            batchAddIfInteresting: { candidates in
                await corpus.batchAddIfInteresting(candidates)
            },
            add: { input, signature, entryType, failure in
                await corpus.add(input: input, signature: signature, entryType: entryType, failure: failure)
            },
            minimized: { await corpus.minimized() },
            snapshot: { await corpus.snapshot() }
        )
    }

    /// Create a test client where addIfInteresting always returns true.
    ///
    /// This is useful for tests that want to verify mutation/generation
    /// without needing to mock coverage data.
    public static func alwaysInteresting(schemaVersion: String = "test") -> CorpusClient<repeat each Input> {
        let corpus = Corpus<repeat each Input>(schemaVersion: schemaVersion)
        return CorpusClient<repeat each Input>(
            count: { await corpus.count },
            isEmpty: { await corpus.isEmpty },
            entries: { await corpus.entries },
            inputs: { await corpus.inputs },
            signatures: { await corpus.signatures },
            totalCoverage: { await corpus.totalCoverage },
            schemaVersion: { corpus.schemaVersion },
            updatedAt: { await corpus.updatedAt },
            createdAt: { corpus.createdAt },
            failureCount: { await corpus.failureCount },
            hangCount: { await corpus.hangCount },
            failureEntries: { await corpus.failureEntries },
            hangEntries: { await corpus.hangEntries },
            batchState: { await corpus.batchState() },
            addIfInteresting: { input, signature in
                // Always add to corpus (bypass coverage check)
                await corpus.add(
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
                    await corpus.add(
                        input: candidate.input,
                        signature: candidate.signature,
                        entryType: .coverage,
                        failure: nil
                    )
                }
                return [Bool](repeating: true, count: candidates.count)
            },
            add: { input, signature, entryType, failure in
                await corpus.add(input: input, signature: signature, entryType: entryType, failure: failure)
            },
            minimized: { await corpus.minimized() },
            snapshot: { await corpus.snapshot() }
        )
    }
}

// MARK: - Corpus Registry

/// Registry for corpus clients.
///
/// Provides a factory for creating corpus clients with the appropriate type.
public struct CorpusRegistry: Sendable {
    /// Create a corpus client for the given input types.
    public func get<each Input: Codable & Sendable>(schemaVersion: String) -> CorpusClient<repeat each Input> {
        return CorpusClient.live(schemaVersion: schemaVersion)
    }

    /// Create a corpus client from an existing corpus.
    public func get<each Input: Codable & Sendable>(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        return CorpusClient.live(corpus: corpus)
    }
}

extension CorpusRegistry: CorpusRegistryProtocol {}

public protocol CorpusRegistryProtocol: Sendable {
    func get<each T: Codable & Sendable>(schemaVersion: String) -> CorpusClient<repeat each T>
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
    /// let client: CorpusClient<Int> = registry.get(schemaVersion: "v1")
    /// ```
    public var corpusRegistry: CorpusRegistryProtocol {
        get { self[CorpusRegistryKey.self] }
        set { self[CorpusRegistryKey.self] = newValue }
    }
}
