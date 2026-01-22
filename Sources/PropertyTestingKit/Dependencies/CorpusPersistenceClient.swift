//
//  CorpusPersistenceClient.swift
//  PropertyTestingKit
//
//  Dependency client for corpus persistence operations.
//

import Dependencies
import Foundation
import IssueReporting

/// The standard filename for corpus storage.
private let corpusFilename = "corpus.json"

/// Dependency client for corpus file persistence.
///
/// This abstracts file operations for corpus storage, allowing tests to mock
/// persistence without setting up actual files.
public struct CorpusPersistenceClient: Sendable {
    // Internal data-level operations (mockable in tests)
    private var _save: @Sendable (Data, URL) throws -> Void
    private var _load: @Sendable (URL) throws -> Data
    public var exists: @Sendable (URL) -> Bool
    public var delete: @Sendable (URL) throws -> Void

    public init(
        save: @escaping @Sendable (Data, URL) throws -> Void,
        load: @escaping @Sendable (URL) throws -> Data,
        exists: @escaping @Sendable (URL) -> Bool,
        delete: @escaping @Sendable (URL) throws -> Void
    ) {
        self._save = save
        self._load = load
        self.exists = exists
        self.delete = delete
    }

    // Generic public API - specializes at call site

    /// Save a corpus snapshot to the given directory.
    public func save<each Input: Codable & Sendable>(
        _ snapshot: CorpusSnapshot<repeat each Input>,
        to url: URL
    ) throws {
        let data = try JSONEncoder.corpusEncoder.encode(snapshot)
        try _save(data, url)
    }

    /// Load a corpus from the given directory.
    public func load<each Input: Codable & Sendable>(
        from url: URL
    ) throws -> Corpus<repeat each Input> {
        let data = try _load(url)
        let snapshot = try JSONDecoder.corpusDecoder.decode(CorpusSnapshot<repeat each Input>.self, from: data)
        return Corpus(from: snapshot)
    }

    /// Load a corpus snapshot from the given directory.
    public func loadSnapshot<each Input: Codable & Sendable>(
        from url: URL
    ) throws -> CorpusSnapshot<repeat each Input> {
        let data = try _load(url)
        return try JSONDecoder.corpusDecoder.decode(CorpusSnapshot<repeat each Input>.self, from: data)
    }
}

// MARK: - Dependency Key

struct CorpusPersistenceClientKey: DependencyKey {
    public static var liveValue: CorpusPersistenceClient {
        @Dependency(\.fileManager) var fileManager

        return CorpusPersistenceClient(
            save: { data, directory in
                try fileManager.createDirectory(directory, true)
                let fileURL = directory.appendingPathComponent(corpusFilename)
                try fileManager.writeData(data, fileURL)
            },
            load: { directory in
                let fileURL = directory.appendingPathComponent(corpusFilename)
                return try fileManager.readData(fileURL)
            },
            exists: { directory in
                let fileURL = directory.appendingPathComponent(corpusFilename)
                return fileManager.fileExists(atPath: fileURL.path)
            },
            delete: { directory in
                let fileURL = directory.appendingPathComponent(corpusFilename)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(fileURL)
                }
            }
        )
    }

    public static let testValue = liveValue
}

extension DependencyValues {
    public var corpusPersistence: CorpusPersistenceClient {
        get { self[CorpusPersistenceClientKey.self] }
        set { self[CorpusPersistenceClientKey.self] = newValue }
    }
}
