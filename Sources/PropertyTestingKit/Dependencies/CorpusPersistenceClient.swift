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
struct CorpusPersistenceClient: Sendable {
    // Internal data-level operations (mockable in tests)
    private var _save: @Sendable (Data, URL) throws -> Void
    private var _load: @Sendable (URL) throws -> Data
    var exists: @Sendable (URL) -> Bool
    var delete: @Sendable (URL) throws -> Void

    init(
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

    // Generic API - specializes at call site

    /// Save a corpus snapshot to the given directory.
    func save<each Input: Codable & Sendable>(
        _ snapshot: CorpusSnapshot<repeat each Input>,
        to url: URL,
        scheduleFuzzing: Bool = false
    ) throws {
        let data = try JSONEncoder.corpusEncoder(scheduleFuzzing: scheduleFuzzing).encode(snapshot)
        try _save(data, url)
    }

    /// Load a corpus snapshot from the given directory.
    func loadSnapshot<each Input: Codable & Sendable>(
        from url: URL,
        scheduleFuzzing: Bool = false
    ) throws -> CorpusSnapshot<repeat each Input> {
        let data = try _load(url)
        return try JSONDecoder.corpusDecoder(scheduleFuzzing: scheduleFuzzing).decode(CorpusSnapshot<repeat each Input>.self, from: data)
    }
}

// MARK: - Dependency Key

struct CorpusPersistenceClientKey: DependencyKey {
    static var liveValue: CorpusPersistenceClient {
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

    static let testValue = liveValue
}

extension DependencyValues {
    var corpusPersistence: CorpusPersistenceClient {
        get { self[CorpusPersistenceClientKey.self] }
        set { self[CorpusPersistenceClientKey.self] = newValue }
    }
}
