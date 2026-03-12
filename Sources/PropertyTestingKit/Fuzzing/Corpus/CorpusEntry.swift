//
//  CorpusEntry.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Dependencies

/// A single entry in the corpus: an input and its coverage data.
public struct CorpusEntry<each Input: Codable & Sendable>: Sendable, Codable {
    /// The test input.
    public let input: (repeat each Input)

    /// The sparse coverage data.
    public let sparseCoverage: SparseCoverage

    /// The reason this entry was added to the corpus.
    public let entryType: CorpusEntryType

    // TODO: Move failureInfo into corpus entry type
    /// Failure information if this entry caused a test failure.
    public let failure: FailureInfo?

    public init(
        input: repeat each Input,
        sparseCoverage: consuming SparseCoverage,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        self.input = (repeat each input)
        self.sparseCoverage = sparseCoverage
        self.entryType = entryType
        self.failure = failure
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CorpusEntryCodingKeys.self)
        var dataList = [Data]()
        var readableList = [String]()
        let jsonEncoder = JSONEncoder.corpusEncoder

        (repeat try dataList.append(jsonEncoder.encode(each input)))
        (repeat readableList.append(toReadableString(each input)))

        try container.encode(dataList, forKey: .input)
        try container.encode(readableList, forKey: .inputReadable)

        try container.encode(sparseCoverage, forKey: .signature)
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

        let jsonDecoder = JSONDecoder.corpusDecoder

        self.input = try (repeat jsonDecoder.decode((each Input).self, from: dataIterator.next()!))

        self.sparseCoverage = try container.decode(SparseCoverage.self, forKey: .signature)
        // Default to .coverage for backward compatibility with existing corpus files
        self.entryType = try container.decodeIfPresent(CorpusEntryType.self, forKey: .entryType) ?? .coverage
        self.failure = try container.decodeIfPresent(FailureInfo.self, forKey: .failure)
    }
}

public enum CorpusEntryCodingKeys: String, CodingKey {
    case input
    case inputReadable
    case signature
    case entryType
    case failure
}
