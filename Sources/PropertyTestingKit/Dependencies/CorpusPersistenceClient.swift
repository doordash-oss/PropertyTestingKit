// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
        to url: URL
    ) throws {
        let data = try JSONEncoder.corpusEncoder().encode(snapshot)
        try _save(data, url)
    }

    /// Load a corpus snapshot from the given directory.
    func loadSnapshot<each Input: Codable & Sendable>(
        from url: URL
    ) throws -> CorpusSnapshot<repeat each Input> {
        let data = try _load(url)
        return try JSONDecoder.corpusDecoder().decode(CorpusSnapshot<repeat each Input>.self, from: data)
    }
}

// MARK: - Dependency Key

struct CorpusPersistenceClientKey: DependencyKey {
    static var liveValue: CorpusPersistenceClient {
        // Resolve `\.fileManager` PER CALL (inside each closure), not once here.
        //
        // `liveValue` is cached globally by swift-dependencies, and `@Dependency`
        // snapshots the dependency context where it is *initialized*. Declaring the
        // `fileManager` wrapper at this scope captured it from whichever task first
        // triggered `liveValue` computation under the parallel test suite — if that
        // task had `\.fileManager` overridden (e.g. a test mock whose `fileExists`
        // returns false), the cached live client was poisoned for the whole process.
        // Declaring it inside each closure binds it to the *calling* task's context.
        return CorpusPersistenceClient(
            save: { data, directory in
                @Dependency(\.fileManager) var fileManager
                try fileManager.createDirectory(directory, true)
                let fileURL = directory.appendingPathComponent(corpusFilename)
                try fileManager.writeData(data, fileURL)
            },
            load: { directory in
                @Dependency(\.fileManager) var fileManager
                let fileURL = directory.appendingPathComponent(corpusFilename)
                return try fileManager.readData(fileURL)
            },
            exists: { directory in
                @Dependency(\.fileManager) var fileManager
                let fileURL = directory.appendingPathComponent(corpusFilename)
                return fileManager.fileExists(atPath: fileURL.path)
            },
            delete: { directory in
                @Dependency(\.fileManager) var fileManager
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
