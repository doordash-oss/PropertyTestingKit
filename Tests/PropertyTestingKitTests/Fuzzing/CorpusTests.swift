//
//  CorpusTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

@Suite("Corpus", .serialized)
struct CorpusTests {

    @Test("Corpus adds interesting entries")
    func testCorpusAddsInteresting() {
        var corpus = Corpus<Int>(schemaVersion: "test")

        let sig1 = CoverageSignature(buckets: [0: .one])
        let sig2 = CoverageSignature(buckets: [1: .one])
        let sig3 = CoverageSignature(buckets: [0: .one])  // Duplicate coverage

        let added1 = corpus.addIfInteresting(input: 1, signature: sig1)
        let added2 = corpus.addIfInteresting(input: 2, signature: sig2)
        let added3 = corpus.addIfInteresting(input: 3, signature: sig3)

        #expect(added1)
        #expect(added2)
        #expect(!added3)  // Redundant

        #expect(corpus.count == 2)
    }

    @Test("Corpus minimization keeps essential entries")
    func testCorpusMinimization() {
        var corpus = Corpus<Int>(schemaVersion: "test")

        // Entry 1 covers indices 0, 1
        corpus.add(input: 1, signature: CoverageSignature(buckets: [0: .one, 1: .one]))
        // Entry 2 covers indices 1, 2
        corpus.add(input: 2, signature: CoverageSignature(buckets: [1: .one, 2: .one]))
        // Entry 3 covers indices 0, 2 (makes 1 and 2 redundant together)
        corpus.add(input: 3, signature: CoverageSignature(buckets: [0: .one, 2: .one]))

        let minimized = corpus.minimized()

        // Should need at most 2 entries to cover all 3 indices
        #expect(minimized.count <= 2)
        #expect(minimized.totalCoverage.executedIndices == Set([0, 1, 2]))
    }

    @Test("Corpus.exists returns true when file exists")
    func testCorpusExistsTrue() {
        let (fileExistsSpy, fileExistsFn) = spy { (_: String) in true }

        withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            let exists = Corpus<String>.exists(at: URL(fileURLWithPath: "/test"))
            #expect(exists)
        }

        #expect(fileExistsSpy.callCount == 1)
        #expect(fileExistsSpy.callParams[0].hasSuffix("corpus.json"))
    }

    @Test("Corpus.exists returns false when file does not exist")
    func testCorpusExistsFalse() {
        let (fileExistsSpy, fileExistsFn) = spy { (_: String) in false }

        withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            let exists = Corpus<String>.exists(at: URL(fileURLWithPath: "/test"))
            #expect(!exists)
        }

        #expect(fileExistsSpy.callCount == 1)
    }

    @Test("Corpus.delete removes file when it exists")
    func testCorpusDeleteWhenExists() throws {
        let (removeItemSpy, removeItemFn) = spy { (_: URL) in }

        try withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in true },
                createDirectory: { _, _ in },
                removeItem: removeItemFn,
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            try Corpus<String>.delete(from: URL(fileURLWithPath: "/test/corpus"))
        }

        #expect(removeItemSpy.callCount == 1)
        #expect(removeItemSpy.callParams[0].lastPathComponent == "corpus.json")
    }

    @Test("Corpus.delete does nothing when file does not exist")
    func testCorpusDeleteWhenNotExists() throws {
        let (removeItemSpy, removeItemFn) = spy { (_: URL) in }

        try withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: removeItemFn,
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            try Corpus<String>.delete(from: URL(fileURLWithPath: "/test/corpus"))
        }

        #expect(removeItemSpy.callCount == 0)
    }

    @Test("Corpus.save creates directory and writes data")
    func testCorpusSaveCreatesDirectoryAndWritesData() throws {
        let (createDirectorySpy, createDirectoryFn) = spy { (_: URL, _: Bool) in }
        let (writeDataSpy, writeDataFn) = spy { (_: Data, _: URL) in }
        let corpus = Corpus<String>(schemaVersion: "test")

        try withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: createDirectoryFn,
                removeItem: { _ in },
                writeData: writeDataFn,
                readData: { _ in Data() }
            )
        } operation: {
            try corpus.save(to: URL(fileURLWithPath: "/test/corpus"))
        }

        #expect(createDirectorySpy.callCount == 1)
        #expect(createDirectorySpy.callParams[0].0.path == "/test/corpus")
        #expect(writeDataSpy.callCount == 1)
        #expect(writeDataSpy.callParams[0].1.lastPathComponent == "corpus.json")
    }

    @Test("Corpus.load reads data from file")
    func testCorpusLoadReadsData() throws {
        // Create a valid corpus JSON
        var corpus = Corpus<String>(schemaVersion: "test-v1")
        corpus.add(input: "hello", signature: CoverageSignature(buckets: [0: .one]))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let corpusData = try encoder.encode(corpus)

        let (readDataSpy, readDataFn) = spy { (_: URL) in corpusData }

        let loaded: Corpus<String> = try withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in true },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
            )
        } operation: {
            try Corpus<String>.load(from: URL(fileURLWithPath: "/test/corpus"))
        }

        #expect(readDataSpy.callCount == 1)
        #expect(readDataSpy.callParams[0].lastPathComponent == "corpus.json")
        #expect(loaded.schemaVersion == "test-v1")
        #expect(loaded.count == 1)
        #expect(loaded.inputs.contains("hello"))
    }
}
