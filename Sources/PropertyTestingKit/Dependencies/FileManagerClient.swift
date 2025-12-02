//
//  FileManagerClient.swift
//  PropertyTestingKit
//
//  Dependency client for file system operations to enable testing.
//

import Dependencies
import Foundation
import IssueReporting

/// Dependency client for file system operations.
public struct FileManagerClient: Sendable {
    /// Get the current working directory path.
    public var currentDirectoryPath: @Sendable () -> String

    /// Check if a file exists at the given path.
    public var fileExists: @Sendable (String) -> Bool

    /// Create a directory at the given URL, optionally creating intermediate directories.
    public var createDirectory: @Sendable (URL, Bool) throws -> Void

    /// Remove the item at the given URL.
    public var removeItem: @Sendable (URL) throws -> Void

    /// Write data to a file at the given URL.
    public var writeData: @Sendable (Data, URL) throws -> Void

    /// Read data from a file at the given URL.
    public var readData: @Sendable (URL) throws -> Data

    public init(
        currentDirectoryPath: @escaping @Sendable () -> String,
        fileExists: @escaping @Sendable (String) -> Bool,
        createDirectory: @escaping @Sendable (URL, Bool) throws -> Void,
        removeItem: @escaping @Sendable (URL) throws -> Void,
        writeData: @escaping @Sendable (Data, URL) throws -> Void,
        readData: @escaping @Sendable (URL) throws -> Data
    ) {
        self.currentDirectoryPath = currentDirectoryPath
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.removeItem = removeItem
        self.writeData = writeData
        self.readData = readData
    }
}

// MARK: - Dependency Key

extension FileManagerClient: DependencyKey {
    public static let liveValue = FileManagerClient(
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

    public static let testValue = FileManagerClient(
        currentDirectoryPath: unimplemented("FileManagerClient.currentDirectoryPath", placeholder: ""),
        fileExists: unimplemented("FileManagerClient.fileExists", placeholder: false),
        createDirectory: unimplemented("FileManagerClient.createDirectory", placeholder: ()),
        removeItem: unimplemented("FileManagerClient.removeItem", placeholder: ()),
        writeData: unimplemented("FileManagerClient.writeData", placeholder: ()),
        readData: unimplemented("FileManagerClient.readData", placeholder: Data())
    )
}

extension DependencyValues {
    public var fileManager: FileManagerClient {
        get { self[FileManagerClient.self] }
        set { self[FileManagerClient.self] = newValue }
    }
}
