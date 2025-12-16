//
//  Corpus.swift
//  PropertyTestingKit
//
//  Storage and management of fuzzing inputs with coverage signatures.
//

import Dependencies
import Foundation

// MARK: - FailureInfo

/// Information about a failure caused by a corpus entry.
///
/// Based on Elhage 2020 "Property Testing Like AFL" - preserving failure-inducing
/// inputs is critical for regression testing and preventing bug recurrence.
public struct FailureInfo: Codable, Sendable {
    /// The type name of the error that occurred.
    public let errorType: String

    /// The localized error message.
    public let message: String

    /// Optional stack trace (if available).
    public let stackTrace: String?

    /// When this failure was first discovered.
    public let discoveredAt: Date

    public init(error: Error, stackTrace: String? = nil) {
        @Dependency(\.dateClient) var dateClient
        self.errorType = String(describing: type(of: error))
        self.message = error.localizedDescription
        self.stackTrace = stackTrace
        self.discoveredAt = dateClient.now()
    }

    public init(
        errorType: String,
        message: String,
        stackTrace: String? = nil,
        discoveredAt: Date? = nil
    ) {
        @Dependency(\.dateClient) var dateClient
        self.errorType = errorType
        self.message = message
        self.stackTrace = stackTrace
        self.discoveredAt = discoveredAt ?? dateClient.now()
    }
}

// MARK: - CorpusEntryType

/// The reason this entry was added to the corpus.
public enum CorpusEntryType: String, Codable, Sendable {
    /// Entry was added because it discovered new coverage.
    case coverage

    /// Entry was added because it caused a test failure.
    case failure

    /// Entry was added because it caused a hang (timeout).
    case hang

    /// Entry was added because it made value profile progress.
    case valueProfile
}

// MARK: - CorpusEntry

/// A single entry in the corpus: an input and its coverage signature.
public struct CorpusEntry<each Input: Codable & Sendable>: Sendable, Codable {
    /// The test input.
    public let input: (repeat each Input)

    /// The coverage signature produced by this input.
    public let signature: CoverageSignature

    /// When this entry was discovered.
    public let discoveredAt: Date

    /// Optional: the parent input this was mutated from.
    public let parentIndex: Int?

    /// The reason this entry was added to the corpus.
    public let entryType: CorpusEntryType

    /// Failure information if this entry caused a test failure.
    public let failure: FailureInfo?

    public init(
        input: repeat each Input,
        signature: CoverageSignature,
        discoveredAt: Date? = nil,
        parentIndex: Int? = nil,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        @Dependency(\.dateClient) var dateClient
        self.input = (repeat each input)
        self.signature = signature
        self.discoveredAt = discoveredAt ?? dateClient.now()
        self.parentIndex = parentIndex
        self.entryType = entryType
        self.failure = failure
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CorpusEntryCodingKeys.self)
        var dataList = [Data]()
        var readableList = [String]()
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys]

        (repeat try dataList.append(jsonEncoder.encode(each input)))
        (repeat readableList.append(toReadableString(each input)))

        try container.encode(dataList, forKey: .input)
        try container.encode(readableList, forKey: .inputReadable)

        try container.encode(signature, forKey: .signature)
        try container.encode(discoveredAt, forKey: .discoveredAt)
        try container.encodeIfPresent(parentIndex, forKey: .parentIndex)
        try container.encode(entryType, forKey: .entryType)
        try container.encodeIfPresent(failure, forKey: .failure)
    }

    /// Convert a value to a human-readable string representation.
    private func toReadableString<T>(_ value: T) -> String {
        if let string = value as? String {
            return string
        } else if let data = value as? Data {
            // Try to decode as UTF-8 string, fall back to hex representation
            if let str = String(data: data, encoding: .utf8) {
                return str
            } else {
                return data.map { String(format: "%02x", $0) }.joined(separator: " ")
            }
        } else if let array = value as? [Any] {
            return "[\(array.map { "\($0)" }.joined(separator: ", "))]"
        } else {
            return "\(value)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CorpusEntryCodingKeys.self)
        let dataList = try container.decode([Data].self, forKey: .input)
        var dataIterator = dataList.makeIterator()

        let jsonDecoder = JSONDecoder()

        self.input = try (repeat jsonDecoder.decode((each Input).self, from: dataIterator.next()!))

        self.signature = try container.decode(CoverageSignature.self, forKey: .signature)
        self.discoveredAt = try container.decode(Date.self, forKey: .discoveredAt)
        self.parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        // Default to .coverage for backward compatibility with existing corpus files
        self.entryType = try container.decodeIfPresent(CorpusEntryType.self, forKey: .entryType) ?? .coverage
        self.failure = try container.decodeIfPresent(FailureInfo.self, forKey: .failure)
    }
}

public enum CorpusEntryCodingKeys: String, CodingKey {
    case input
    case inputReadable
    case signature
    case discoveredAt
    case parentIndex
    case entryType
    case failure
}

// MARK: - Corpus Coding Keys

/// Coding keys for Corpus serialization.
/// Note: Must be declared outside the generic struct due to parameter pack limitations.
private enum CorpusCodingKeys: String, CodingKey {
    case entries
    case schemaVersion
    case createdAt
    case updatedAt
    case totalCoverage
    // Note: entropicScheduler is intentionally excluded - it's runtime state
}

/// A collection of test inputs with their coverage signatures.
///
/// The corpus tracks which inputs produce unique coverage and provides
/// minimization to keep only the essential inputs.
public struct Corpus<each Input: Codable & Sendable>: Sendable, Codable {
    @Dependency(\.dateClient) var dateClient

    /// All entries in the corpus.
    public private(set) var entries: [CorpusEntry<repeat each Input>]

    /// Schema version to detect when code changes invalidate the corpus.
    public let schemaVersion: String

    /// When this corpus was created.
    public let createdAt: Date

    /// When this corpus was last updated.
    public private(set) var updatedAt: Date

    /// The union of all coverage signatures.
    public private(set) var totalCoverage: CoverageSignature

    // Note: entropicScheduler is defined later in the file but declared here
    // for context - it's excluded from Codable as it's runtime state.

    public init(schemaVersion: String) {
        @Dependency(\.dateClient) var dateClient
        let now = dateClient.now()
        self.entries = []
        self.schemaVersion = schemaVersion
        self.createdAt = now
        self.updatedAt = now
        self.totalCoverage = CoverageSignature(buckets: [:])
    }

    // MARK: - Codable

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CorpusCodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(totalCoverage, forKey: .totalCoverage)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CorpusCodingKeys.self)
        self.entries = try container.decode([CorpusEntry<repeat each Input>].self, forKey: .entries)
        self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.totalCoverage = try container.decode(CoverageSignature.self, forKey: .totalCoverage)
        // entropicScheduler is not persisted - initialized as nil at runtime
    }

    /// Number of entries in the corpus.
    public var count: Int { entries.count }

    /// Whether the corpus is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All inputs in the corpus.
    public var inputs: [(repeat each Input)] {
        // Note: Can't use map(\.input) due to keypath limitations with parameter packs
        var result: [(repeat each Input)] = []
        for entry in entries {
            result.append(entry.input)
        }
        return result
    }

    /// All signatures in the corpus.
    public var signatures: [CoverageSignature] {
        // Note: Can't use map(\.signature) consistently, using explicit loop
        var result: [CoverageSignature] = []
        for entry in entries {
            result.append(entry.signature)
        }
        return result
    }

    // MARK: - Adding Entries

    /// Add an entry if it contributes new coverage.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    public mutating func addIfInteresting(
        input: repeat each Input,
        signature: CoverageSignature,
        parentIndex: Int? = nil
    ) -> Bool {
        // Check if this signature adds new coverage
        guard signature.hasUniqueCoverage(comparedTo: totalCoverage) else {
            return false
        }

        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = dateClient.now()
        return true
    }

    /// Add an entry unconditionally.
    public mutating func add(
        input: repeat each Input,
        signature: CoverageSignature,
        parentIndex: Int? = nil,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex,
            entryType: entryType,
            failure: failure
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = dateClient.now()
    }

    /// Add a failure-inducing input to the corpus.
    ///
    /// Failure entries are always preserved during minimization to prevent
    /// regression of discovered bugs.
    public mutating func addFailure(
        input: repeat each Input,
        signature: CoverageSignature,
        error: Error,
        parentIndex: Int? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex,
            entryType: .failure,
            failure: FailureInfo(error: error)
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = dateClient.now()
    }

    /// Add a hang-inducing input to the corpus.
    ///
    /// Hang entries are preserved during minimization.
    public mutating func addHang(
        input: repeat each Input,
        signature: CoverageSignature,
        timeout: TimeInterval,
        parentIndex: Int? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex,
            entryType: .hang,
            failure: FailureInfo(
                errorType: "HangDetectedError",
                message: "Execution timed out after \(timeout) seconds"
            )
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = dateClient.now()
    }

    // MARK: - Failure Statistics

    /// Number of failure-inducing entries in the corpus.
    public var failureCount: Int {
        entries.filter { $0.entryType == .failure }.count
    }

    /// Number of hang-inducing entries in the corpus.
    public var hangCount: Int {
        entries.filter { $0.entryType == .hang }.count
    }

    /// All failure entries.
    public var failureEntries: [CorpusEntry<repeat each Input>] {
        entries.filter { $0.entryType == .failure }
    }

    /// All hang entries.
    public var hangEntries: [CorpusEntry<repeat each Input>] {
        entries.filter { $0.entryType == .hang }
    }

    // MARK: - Minimization

    /// Minimize the corpus to the smallest set that covers all unique signatures.
    ///
    /// Uses a greedy algorithm: repeatedly select the entry that covers the
    /// most uncovered indices until all indices are covered.
    ///
    /// **Important:** Failure and hang entries are ALWAYS preserved during minimization
    /// to prevent regression of discovered bugs. This follows Elhage 2020's recommendation
    /// that "previously-failing cases must be preserved during minimization."
    ///
    /// - Returns: A new minimized corpus.
    public func minimized() -> Corpus<repeat each Input> {
        guard !entries.isEmpty else { return self }

        var minimized = Corpus<repeat each Input>(schemaVersion: schemaVersion)
        var uncovered = totalCoverage.executedIndices

        // First, preserve ALL failure and hang entries - these are never removed
        // during minimization to prevent regression of discovered bugs.
        var remainingCoverage = entries.enumerated().map { ($0.offset, $0.element) }
        var indicesToRemove: [Int] = []

        for (i, (_, entry)) in remainingCoverage.enumerated() {
            if entry.entryType == .failure || entry.entryType == .hang {
                minimized.addEntry(entry)
                uncovered.subtract(entry.signature.executedIndices)
                indicesToRemove.append(i)
            }
        }

        // Remove preserved entries from remaining pool (in reverse order to maintain indices)
        for index in indicesToRemove.reversed() {
            remainingCoverage.remove(at: index)
        }

        // Now use greedy algorithm for remaining coverage-based entries
        while !uncovered.isEmpty && !remainingCoverage.isEmpty {
            // Find entry that covers the most uncovered indices.
            var bestIndex = 0
            var bestCoverageCount = 0

            for (i, (_, entry)) in remainingCoverage.enumerated() {
                let covers = entry.signature.executedIndices.intersection(uncovered).count
                if covers > bestCoverageCount {
                    bestCoverageCount = covers
                    bestIndex = i
                }
            }

            // If no entry covers any uncovered indices, we're done
            if bestCoverageCount == 0 {
                break
            }

            // Add the best entry
            let (_, bestEntry) = remainingCoverage.remove(at: bestIndex)
            minimized.addEntry(bestEntry)

            // Remove covered indices
            uncovered.subtract(bestEntry.signature.executedIndices)
        }

        return minimized
    }

    /// Add an existing entry to the corpus.
    private mutating func addEntry(_ entry: CorpusEntry<repeat each Input>) {
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: entry.signature)
        updatedAt = dateClient.now()
    }

    // MARK: - Selection for Mutation

    /// Entropic scheduler for entropy-based seed selection.
    /// When enabled, uses Shannon entropy to prioritize seeds exercising rare features.
    private var entropicScheduler: EntropicScheduler?

    /// Select an entry for mutation using energy-based scheduling.
    ///
    /// When entropic scheduling is enabled (default), uses Shannon entropy to
    /// prioritize seeds that exercise rare (index, bucket) features.
    /// Falls back to simple frequency-based selection when disabled.
    ///
    /// Based on Böhme 2020 "Entropic" which achieved 1.63x improvement in
    /// coverage discovery speed.
    public mutating func selectForMutation() -> Int? {
        guard !entries.isEmpty else { return nil }

        // Use entropic selection if enabled
        if let scheduler = entropicScheduler {
            return scheduler.selectForMutation(signatures: signatures)
        }

        // Fallback: Simple frequency-based selection using (index, bucket) features
        // This is still more fine-grained than the original (index-only) approach
        var featureFrequency: [Feature: Int] = [:]
        for entry in entries {
            for feature in EntropicScheduler.extractFeatures(from: entry.signature) {
                featureFrequency[feature, default: 0] += 1
            }
        }

        // Score each entry by sum of (1 / frequency) for its features
        var scores = Array(repeating: 0.0, count: entries.count)
        for (feature, freq) in featureFrequency {
            let contribution = 1.0 / Double(freq)
            for (i, entry) in entries.enumerated() {
                if let bucket = entry.signature.buckets[feature.index], bucket == feature.bucket {
                    scores[i] += contribution
                }
            }
        }

        // Weighted random selection
        let totalScore = scores.reduce(0, +)
        guard totalScore > 0 else { return entries.indices.randomElement() }

        var random = Double.random(in: 0..<totalScore)

        // Iterate through all but the last score. If we don't return early,
        // the last entry is selected by elimination.
        for (i, score) in scores.dropLast().enumerated() {
            random -= score
            if random <= 0 {
                return i
            }
        }

        return scores.count - 1
    }

    /// Enable entropic seed selection with the given configuration.
    ///
    /// When enabled, corpus selection uses Shannon entropy to prioritize
    /// seeds exercising rare features. This typically improves coverage
    /// discovery speed by 1.5-2x.
    public mutating func enableEntropic(config: EntropicScheduler.Config = .init()) {
        var scheduler = EntropicScheduler(config: config)

        // Initialize with existing entries
        for entry in entries {
            scheduler.recordEntry(entry.signature)
        }

        // Copy signatures to avoid exclusivity violation
        let sigs = signatures

        // Force initial entropy computation
        scheduler.recomputeEntropies(for: sigs)

        entropicScheduler = scheduler
    }

    /// Disable entropic seed selection.
    ///
    /// Falls back to simple frequency-based selection.
    public mutating func disableEntropic() {
        entropicScheduler = nil
    }

    /// Get entropic statistics if enabled.
    public var entropicStats: EntropicStats? {
        entropicScheduler?.stats
    }

    // MARK: - Regression Test Generation

    /// Generate Swift test code for a failure entry that can be copied into test files.
    ///
    /// Based on Elhage 2020's recommendation for "formatted examples developers can copy
    /// directly into committed test suites."
    ///
    /// - Parameters:
    ///   - entry: The failure entry to generate code for.
    ///   - functionName: Optional function name override (defaults to generated name).
    /// - Returns: Swift code snippet for a regression test.
    public func generateRegressionTestCode(
        for entry: CorpusEntry<repeat each Input>,
        functionName: String? = nil
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: entry.discoveredAt)

        let funcName = functionName ?? "testRegression_\(timestamp)"

        // Serialize the input for code generation
        var inputParts: [String] = []
        (repeat inputParts.append(serializeForCode(each entry.input)))

        let inputCode = inputParts.joined(separator: ", ")
        let inputType = inputParts.count == 1 ? "input" : "inputs"

        var code = """
            // =============================================================================
            // FUZZER-DISCOVERED REGRESSION TEST
            // =============================================================================
            //
            // This test was automatically generated by PropertyTestingKit after
            // discovering a failure-inducing input. Add this to your test suite to
            // prevent regression of this bug.
            //

            """

        if let failure = entry.failure {
            code += """
                // Error Type: \(failure.errorType)
                // Error Message: \(failure.message)
                // Discovered: \(entry.discoveredAt)
                //

                """
        }

        code += """
            @Test func \(funcName)() throws {
                let \(inputType) = (\(inputCode))
                // TODO: Update the expected behavior based on whether this is:
                // - A bug that should throw an error (use #expect(throws:))
                // - A bug that was fixed (use the fixed expectation)
                // - An edge case that should now be handled

                // Original behavior (caused failure):
                // #expect(throws: Error.self) {
                //     try yourFunction(\(inputType))
                // }
            }

            // =============================================================================
            """

        return code
    }

    /// Serialize a value into Swift code representation.
    private func serializeForCode<T>(_ value: T) -> String {
        if let string = value as? String {
            return escapeStringForCode(string)
        } else if let int = value as? Int {
            return "\(int)"
        } else if let double = value as? Double {
            return "\(double)"
        } else if let bool = value as? Bool {
            return bool ? "true" : "false"
        } else if let data = value as? Data {
            return "Data(base64Encoded: \"\(data.base64EncodedString())\")!"
        } else {
            // For complex types, use JSON encoding
            if let codable = value as? Codable,
               let jsonData = try? JSONEncoder().encode(codable),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return "/* JSON: \(jsonString) */"
            }
            return "/* \(String(describing: value)) */"
        }
    }

    /// Escape a string for inclusion in Swift code.
    private func escapeStringForCode(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        // Handle null bytes and other control characters
        var result = ""
        for char in escaped.unicodeScalars {
            if char.value < 32 && char.value != 10 && char.value != 13 && char.value != 9 {
                result += String(format: "\\u{%02X}", char.value)
            } else {
                result += String(char)
            }
        }

        return "\"\(result)\""
    }

    /// Generate regression test code for all failure entries in the corpus.
    ///
    /// - Returns: Swift code snippets for all failure regression tests.
    public func generateAllRegressionTests() -> String {
        var code = """
            // =============================================================================
            // FUZZER-DISCOVERED REGRESSION TESTS
            // =============================================================================
            //
            // These tests were automatically generated by PropertyTestingKit.
            // Copy them to your test suite to prevent regression of discovered bugs.
            //
            // Total failures: \(failureCount)
            // Total hangs: \(hangCount)
            // Generated: \(dateClient.now())
            //
            // =============================================================================

            import Testing


            """

        for (index, entry) in failureEntries.enumerated() {
            let funcName = "testFuzzRegression_\(index + 1)"
            code += generateRegressionTestCode(for: entry, functionName: funcName)
            code += "\n\n"
        }

        for (index, entry) in hangEntries.enumerated() {
            let funcName = "testFuzzHang_\(index + 1)"
            code += generateRegressionTestCode(for: entry, functionName: funcName)
            code += "\n\n"
        }

        return code
    }
}

// MARK: - Corpus Persistence

extension Corpus {
    /// The filename for corpus storage.
    public static var filename: String { "corpus.json" }

    /// Save the corpus to a directory.
    public func save(to directory: URL) throws {
        @Dependency(\.fileManager) var fileManager
        try fileManager.createDirectory(directory, true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(self)
        let fileURL = directory.appendingPathComponent(Self.filename)
        try fileManager.writeData(data, fileURL)
    }

    /// Load a corpus from a directory.
    public static func load(from directory: URL) throws -> Corpus<repeat each Input> {
        @Dependency(\.fileManager) var fileManager
        let fileURL = directory.appendingPathComponent(filename)
        let data = try fileManager.readData(fileURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(Corpus<repeat each Input>.self, from: data)
    }

    /// Check if a corpus exists at the given directory.
    public static func exists(at directory: URL) -> Bool {
        @Dependency(\.fileManager) var fileManager
        let fileURL = directory.appendingPathComponent(filename)
        return fileManager.fileExists(fileURL.path)
    }

    /// Delete a corpus from a directory.
    public static func delete(from directory: URL) throws {
        @Dependency(\.fileManager) var fileManager
        let fileURL = directory.appendingPathComponent(filename)
        if fileManager.fileExists(fileURL.path) {
            try fileManager.removeItem(fileURL)
        }
    }
}

// MARK: - Schema Versioning

/// Utilities for generating schema versions from coverage mapping.
public enum CorpusSchema {
    /// Generate a schema version from the current coverage mapping.
    ///
    /// This creates a hash of the coverage structure so we can detect
    /// when code changes invalidate the corpus.
    public static func currentVersion() -> String {
        @Dependency(\.coverageCounters) var coverageCounters
        return currentVersion(using: coverageCounters)
    }

    /// Generate a schema version using a specific coverage counters client.
    /// This overload enables testing with mocked dependencies.
    public static func currentVersion(using coverageCounters: CoverageCountersClient) -> String {
        // Use a hash of:
        // 1. Number of counters
        // 2. Build timestamp or similar

        guard let counters = coverageCounters.snapshot() else {
            return "unknown"
        }

        // Simple version: just the counter count
        // In practice, we'd hash more metadata
        return "v1-\(counters.count)"
    }

    /// Check if a schema version is compatible with the current code.
    public static func isCompatible(_ version: String) -> Bool {
        version == currentVersion()
    }
}
