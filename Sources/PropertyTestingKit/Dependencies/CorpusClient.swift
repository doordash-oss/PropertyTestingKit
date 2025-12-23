//
//  CorpusClient.swift
//  PropertyTestingKit
//
//  Dependency client for corpus operations with generic type support.
//

import Dependencies
import Foundation

// MARK: - Corpus Actor (Thread-safe wrapper)

/// Actor wrapper around Corpus for thread-safe mutation.
///
/// Since Corpus is a value type that mutates, this actor provides
/// safe concurrent access when used through CorpusClient.
public actor CorpusActor<each Input: Codable & Sendable> {
    public var corpus: Corpus<repeat each Input>

    public init(schemaVersion: String) {
        self.corpus = Corpus<repeat each Input>(schemaVersion: schemaVersion)
    }

    public init(corpus: Corpus<repeat each Input>) {
        self.corpus = corpus
    }

    // MARK: - Properties

    public var count: Int { corpus.count }
    public var isEmpty: Bool { corpus.isEmpty }
    public var entries: [CorpusEntry<repeat each Input>] { corpus.entries }
    public var inputs: [(repeat each Input)] { corpus.inputs }
    public var signatures: [CoverageSignature] { corpus.signatures }
    public var totalCoverage: CoverageSignature { corpus.totalCoverage }
    public var schemaVersion: String { corpus.schemaVersion }
    public var failureCount: Int { corpus.failureCount }
    public var hangCount: Int { corpus.hangCount }
    public var failureEntries: [CorpusEntry<repeat each Input>] { corpus.failureEntries }
    public var hangEntries: [CorpusEntry<repeat each Input>] { corpus.hangEntries }

    // MARK: - Mutating Operations

    @discardableResult
    public func addIfInteresting(
        input: (repeat each Input),
        signature: CoverageSignature,
        parentIndex: Int? = nil
    ) -> Bool {
        corpus.addIfInteresting(input: input, signature: signature, parentIndex: parentIndex)
    }

    public func add(
        input: (repeat each Input),
        signature: CoverageSignature,
        parentIndex: Int? = nil,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        corpus.add(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex,
            entryType: entryType,
            failure: failure
        )
    }

    public func selectForMutation() -> Int? {
        corpus.selectForMutation()
    }

    public func minimized() -> Corpus<repeat each Input> {
        corpus.minimized()
    }

    /// Replace the corpus with a new one (used after minimization).
    public func replace(with newCorpus: Corpus<repeat each Input>) {
        corpus = newCorpus
    }

    /// Get a snapshot of the current corpus.
    public func snapshot() -> Corpus<repeat each Input> {
        corpus
    }
}

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
/// let client: CorpusClient<Int, String> = registry.get()!
///
/// // Use client operations
/// let wasAdded = await client.addIfInteresting((42, "test"), signature)
/// let count = await client.count()
/// ```
public struct CorpusClient<each Input: Codable & Sendable>: Sendable {
    // MARK: - Properties (async closures for actor-wrapped access)

    public var count: @Sendable () async -> Int
    public var isEmpty: @Sendable () async -> Bool
    public var entries: @Sendable () async -> [CorpusEntry<repeat each Input>]
    public var inputs: @Sendable () async -> [(repeat each Input)]
    public var signatures: @Sendable () async -> [CoverageSignature]
    public var totalCoverage: @Sendable () async -> CoverageSignature
    public var schemaVersion: @Sendable () async -> String
    public var failureCount: @Sendable () async -> Int
    public var hangCount: @Sendable () async -> Int
    public var failureEntries: @Sendable () async -> [CorpusEntry<repeat each Input>]
    public var hangEntries: @Sendable () async -> [CorpusEntry<repeat each Input>]

    // MARK: - Mutating Operations

    public var addIfInteresting: @Sendable ((repeat each Input), CoverageSignature, Int?) async -> Bool
    public var add: @Sendable ((repeat each Input), CoverageSignature, Int?, CorpusEntryType, FailureInfo?) async -> Void
    public var selectForMutation: @Sendable () async -> Int?
    public var minimized: @Sendable () async -> Corpus<repeat each Input>
    public var replace: @Sendable (Corpus<repeat each Input>) async -> Void
    public var snapshot: @Sendable () async -> Corpus<repeat each Input>

    public init(
        count: @escaping @Sendable () async -> Int,
        isEmpty: @escaping @Sendable () async -> Bool,
        entries: @escaping @Sendable () async -> [CorpusEntry<repeat each Input>],
        inputs: @escaping @Sendable () async -> [(repeat each Input)],
        signatures: @escaping @Sendable () async -> [CoverageSignature],
        totalCoverage: @escaping @Sendable () async -> CoverageSignature,
        schemaVersion: @escaping @Sendable () async -> String,
        failureCount: @escaping @Sendable () async -> Int,
        hangCount: @escaping @Sendable () async -> Int,
        failureEntries: @escaping @Sendable () async -> [CorpusEntry<repeat each Input>],
        hangEntries: @escaping @Sendable () async -> [CorpusEntry<repeat each Input>],
        addIfInteresting: @escaping @Sendable ((repeat each Input), CoverageSignature, Int?) async -> Bool,
        add: @escaping @Sendable ((repeat each Input), CoverageSignature, Int?, CorpusEntryType, FailureInfo?) async -> Void,
        selectForMutation: @escaping @Sendable () async -> Int?,
        minimized: @escaping @Sendable () async -> Corpus<repeat each Input>,
        replace: @escaping @Sendable (Corpus<repeat each Input>) async -> Void,
        snapshot: @escaping @Sendable () async -> Corpus<repeat each Input>
    ) {
        self.count = count
        self.isEmpty = isEmpty
        self.entries = entries
        self.inputs = inputs
        self.signatures = signatures
        self.totalCoverage = totalCoverage
        self.schemaVersion = schemaVersion
        self.failureCount = failureCount
        self.hangCount = hangCount
        self.failureEntries = failureEntries
        self.hangEntries = hangEntries
        self.addIfInteresting = addIfInteresting
        self.add = add
        self.selectForMutation = selectForMutation
        self.minimized = minimized
        self.replace = replace
        self.snapshot = snapshot
    }

    /// Create a live client backed by an actor.
    public static func live(schemaVersion: String) -> CorpusClient<repeat each Input> {
        let actor = CorpusActor<repeat each Input>(schemaVersion: schemaVersion)
        return CorpusClient<repeat each Input>(
            count: { await actor.count },
            isEmpty: { await actor.isEmpty },
            entries: { await actor.entries },
            inputs: { await actor.inputs },
            signatures: { await actor.signatures },
            totalCoverage: { await actor.totalCoverage },
            schemaVersion: { await actor.schemaVersion },
            failureCount: { await actor.failureCount },
            hangCount: { await actor.hangCount },
            failureEntries: { await actor.failureEntries },
            hangEntries: { await actor.hangEntries },
            addIfInteresting: { input, signature, parentIndex in
                await actor.addIfInteresting(input: input, signature: signature, parentIndex: parentIndex)
            },
            add: { input, signature, parentIndex, entryType, failure in
                await actor.add(input: input, signature: signature, parentIndex: parentIndex, entryType: entryType, failure: failure)
            },
            selectForMutation: { await actor.selectForMutation() },
            minimized: { await actor.minimized() },
            replace: { await actor.replace(with: $0) },
            snapshot: { await actor.snapshot() }
        )
    }

    /// Create a live client backed by an existing corpus.
    public static func live(corpus: Corpus<repeat each Input>) -> CorpusClient<repeat each Input> {
        let actor = CorpusActor<repeat each Input>(corpus: corpus)
        return CorpusClient<repeat each Input>(
            count: { await actor.count },
            isEmpty: { await actor.isEmpty },
            entries: { await actor.entries },
            inputs: { await actor.inputs },
            signatures: { await actor.signatures },
            totalCoverage: { await actor.totalCoverage },
            schemaVersion: { await actor.schemaVersion },
            failureCount: { await actor.failureCount },
            hangCount: { await actor.hangCount },
            failureEntries: { await actor.failureEntries },
            hangEntries: { await actor.hangEntries },
            addIfInteresting: { input, signature, parentIndex in
                await actor.addIfInteresting(input: input, signature: signature, parentIndex: parentIndex)
            },
            add: { input, signature, parentIndex, entryType, failure in
                await actor.add(input: input, signature: signature, parentIndex: parentIndex, entryType: entryType, failure: failure)
            },
            selectForMutation: { await actor.selectForMutation() },
            minimized: { await actor.minimized() },
            replace: { await actor.replace(with: $0) },
            snapshot: { await actor.snapshot() }
        )
    }

    /// Create a test client where addIfInteresting always returns true.
    ///
    /// This is useful for tests that want to verify mutation/generation
    /// without needing to mock coverage data.
    public static func alwaysInteresting(schemaVersion: String = "test") -> CorpusClient<repeat each Input> {
        let actor = CorpusActor<repeat each Input>(schemaVersion: schemaVersion)
        return CorpusClient<repeat each Input>(
            count: { await actor.count },
            isEmpty: { await actor.isEmpty },
            entries: { await actor.entries },
            inputs: { await actor.inputs },
            signatures: { await actor.signatures },
            totalCoverage: { await actor.totalCoverage },
            schemaVersion: { await actor.schemaVersion },
            failureCount: { await actor.failureCount },
            hangCount: { await actor.hangCount },
            failureEntries: { await actor.failureEntries },
            hangEntries: { await actor.hangEntries },
            addIfInteresting: { input, signature, parentIndex in
                // Always add to corpus (bypass coverage check)
                await actor.add(
                    input: input,
                    signature: signature,
                    parentIndex: parentIndex,
                    entryType: .coverage,
                    failure: nil
                )
                return true
            },
            add: { input, signature, parentIndex, entryType, failure in
                await actor.add(input: input, signature: signature, parentIndex: parentIndex, entryType: entryType, failure: failure)
            },
            selectForMutation: { await actor.selectForMutation() },
            minimized: { await actor.minimized() },
            replace: { await actor.replace(with: $0) },
            snapshot: { await actor.snapshot() }
        )
    }
}

// MARK: - Type-erased storage

/// Type-erased box for storing CorpusClient instances.
private final class CorpusClientBox: @unchecked Sendable {
    let value: Any
    init(_ value: Any) {
        self.value = value
    }
}

// MARK: - Corpus Registry

/// Registry for corpus clients, keyed by their generic type parameters.
///
/// This enables dependency injection of generic corpus clients by storing
/// them in a type-keyed dictionary.
///
/// ## Usage
///
/// ```swift
/// // Register a client
/// var registry = CorpusRegistry()
/// registry.register(CorpusClient<Int>.live(schemaVersion: "v1"))
///
/// // Retrieve the client
/// let client: CorpusClient<Int>? = registry.get()
/// ```
///
/// ## Downsides
///
/// - Runtime type safety: Uses string-based type keys and `as?` casts
/// - Registration burden: Must register before use
/// - No `@Dependency` property wrapper: Must use registry.get<Type>()
public struct CorpusRegistry: Sendable {
//    private var storage: [String: CorpusClientBox] = [:]

//    public init() {}

//    /// Generate a key from type metadata.
//    private static func key<each Input>(for types: (repeat (each Input).Type)) -> String {
//        var names: [String] = []
//        repeat names.append(String(describing: each types))
//        return names.joined(separator: ":")
//    }

//    /// Register a corpus client for the given input types.
//    public mutating func register<each Input: Codable & Sendable>(
//        _ client: CorpusClient<repeat each Input>
//    ) {
//        let key = Self.key(for: (repeat (each Input).self))
//        storage[key] = CorpusClientBox(client)
//    }

    /// Retrieve a corpus client for the given input types.
    ///
    /// Returns nil if no client has been registered for these types.
    public func get<each Input: Codable & Sendable>(schemaVersion: String) -> CorpusClient<repeat each Input> {
        return CorpusClient.live(corpus: .init(schemaVersion: schemaVersion))
//        let key = Self.key(for: (repeat (each Input).self))
//        return storage[key]?.value as? CorpusClient<repeat each Input>
    }

//    /// Check if a client is registered for the given input types.
//    public func contains<each Input: Codable & Sendable>(for types: (repeat (each Input).Type)) -> Bool {
//        let key = Self.key(for: (repeat (each Input).self))
//        return storage[key] != nil
//    }
//
//    /// Remove a registered client.
//    public mutating func remove<each Input: Codable & Sendable>(for types: (repeat (each Input).Type)) {
//        let key = Self.key(for: (repeat (each Input).self))
//        storage.removeValue(forKey: key)
//    }
//
//    /// Remove all registered clients.
//    public mutating func removeAll() {
//        storage.removeAll()
//    }
}

extension CorpusRegistry: CorpusRegistryProtocol {}

struct MockCorpusRegistry<each T: Codable & Sendable>: CorpusRegistryProtocol {
    func get<each U: Codable & Sendable>(schemaVersion: String) -> CorpusClient<repeat each U> {
        return (_get(schemaVersion) as! CorpusClient<repeat each U>)
    }

    let _get: @Sendable (_ schemaVersion: String) -> CorpusClient<repeat each T>
}

public protocol CorpusRegistryProtocol: Sendable {
    func get<each T: Codable & Sendable>(schemaVersion: String) -> CorpusClient<repeat each T>
}

// MARK: - Dependency Key

private struct CorpusRegistryKey: DependencyKey {
    static let liveValue: CorpusRegistryProtocol = CorpusRegistry()
    static let testValue: CorpusRegistryProtocol = liveValue
}

extension DependencyValues {
    /// Registry for corpus clients.
    ///
    /// Use this to register and retrieve type-specific corpus clients:
    ///
    /// ```swift
    /// @Dependency(\.corpusRegistry) var registry
    ///
    /// // Register
    /// registry.register(CorpusClient<Int>.live(schemaVersion: "v1"))
    ///
    /// // Retrieve
    /// let client: CorpusClient<Int>? = registry.get()
    /// ```
    public var corpusRegistry: CorpusRegistryProtocol {
        get { self[CorpusRegistryKey.self] }
        set { self[CorpusRegistryKey.self] = newValue }
    }
}
