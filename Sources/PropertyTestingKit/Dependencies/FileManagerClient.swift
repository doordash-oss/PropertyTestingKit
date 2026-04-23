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

//  Dependency client for file system operations to enable testing.
//

import Dependencies
import Foundation
import IssueReporting

/// Dependency client for file system operations.
struct FileManagerClient: Sendable {
    /// Get the current working directory path.
    var currentDirectoryPath: @Sendable () -> String

    /// Check if a file exists at the given path.
    let _fileExists: @Sendable (String) -> Bool

    /// Create a directory at the given URL, optionally creating intermediate directories.
    var createDirectory: @Sendable (URL, Bool) throws -> Void

    /// Remove the item at the given URL.
    var removeItem: @Sendable (URL) throws -> Void

    /// Write data to a file at the given URL.
    var writeData: @Sendable (Data, URL) throws -> Void

    /// Read data from a file at the given URL.
    var readData: @Sendable (URL) throws -> Data

    init(
        currentDirectoryPath: @escaping @Sendable () -> String = unimplemented(
            "currentDirectoryPath",
            placeholder: "/test"
        ),
        fileExists: @escaping @Sendable (String) -> Bool = unimplemented(
            "fileExists",
            placeholder: false
        ),
        createDirectory: @escaping @Sendable (URL, Bool) throws -> Void = unimplemented(
            "createDirectory"
        ),
        removeItem: @escaping @Sendable (URL) throws -> Void = unimplemented(
            "removeItem"
        ),
        writeData: @escaping @Sendable (Data, URL) throws -> Void = unimplemented(
            "writeData"
        ),
        readData: @escaping @Sendable (URL) throws -> Data = unimplemented(
            "readData",
            placeholder: Data()
        )
    ) {
        self.currentDirectoryPath = currentDirectoryPath
        self._fileExists = fileExists
        self.createDirectory = createDirectory
        self.removeItem = removeItem
        self.writeData = writeData
        self.readData = readData
    }

    func fileExists(atPath: String) -> Bool {
        self._fileExists(atPath)
    }
}

// MARK: - Dependency Key

extension FileManagerClient: DependencyKey {
    static let liveValue = FileManagerClient(
        currentDirectoryPath: { FileManager.default.currentDirectoryPath },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        createDirectory: { url, createIntermediates in
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: createIntermediates
            )
        },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        writeData: { data, url in try data.write(to: url) },
        readData: { url in try Data(contentsOf: url) }
    )

    static let testValue = liveValue
}

extension DependencyValues {
    var fileManager: FileManagerClient {
        get { self[FileManagerClient.self] }
        set { self[FileManagerClient.self] = newValue }
    }
}
