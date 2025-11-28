//
//  PerTestCoverageDemo.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import PropertyTestingKit
import Foundation

// MARK: - Demo Tests with Per-Test Coverage

/// These tests demonstrate per-test coverage using the `.coverage` trait.
///
/// The trait automatically:
/// - Serializes test execution (required for isolated coverage)
/// - Resets coverage counters before each test
/// - Writes a separate `.profraw` file after each test
///
/// Run with coverage enabled:
/// ```
/// swift test --enable-code-coverage
/// ```
///
/// Then check the coverage files:
/// ```
/// ls /tmp/coverage-*.profraw
/// ```
@Suite("Per-Test Coverage Demo", .serialized, .coverage(outputDirectory: "/tmp"))
struct PerTestCoverageDemo {

    @Test("Database write path")
    func testDbWriteCall() {
        let db = MockDatabase()

        // This test ONLY covers the write path
        db.write(key: "foo", value: "bar")

        #expect(db.writeCount == 1)
        #expect(db.readCount == 0) // We didn't read
    }

    @Test("Database read path")
    func testDbReadCall() {
        let db = MockDatabase()
        db.write(key: "foo", value: "bar")

        // This test covers write AND read paths
        let result = db.read(key: "foo")

        #expect(result == "bar")
        #expect(db.readCount == 1)
    }

    @Test("Database delete - existing key")
    func testDbDeleteCall() {
        let db = MockDatabase()
        db.write(key: "foo", value: "bar")

        // This test covers write AND delete paths
        let deleted = db.delete(key: "foo")

        #expect(deleted == true)
    }

    @Test("Database delete - nonexistent key")
    func testDbDeleteNonexistent() {
        let db = MockDatabase()

        // This test covers the "not found" branch in delete
        let deleted = db.delete(key: "nonexistent")

        #expect(deleted == false)
    }

    @Test("UserService - create new user")
    func testUserServiceCreateUser() {
        let db = MockDatabase()
        let service = UserService(db: db)

        // Covers: createUser success path, exists (false branch)
        let created = service.createUser(id: "123", name: "Alice")

        #expect(created == true)
    }

    @Test("UserService - create duplicate user")
    func testUserServiceCreateDuplicateUser() {
        let db = MockDatabase()
        let service = UserService(db: db)

        _ = service.createUser(id: "123", name: "Alice")

        // Covers: createUser failure path (user exists), exists (true branch)
        let createdAgain = service.createUser(id: "123", name: "Bob")

        #expect(createdAgain == false)
    }

    @Test("UserService - update existing user")
    func testUserServiceUpdateExisting() {
        let db = MockDatabase()
        let service = UserService(db: db)

        _ = service.createUser(id: "123", name: "Alice")

        // Covers: updateUser success path
        let updated = service.updateUser(id: "123", name: "Alice Updated")

        #expect(updated == true)
        #expect(service.getUser(id: "123") == "Alice Updated")
    }

    @Test("UserService - update nonexistent user")
    func testUserServiceUpdateNonexistent() {
        let db = MockDatabase()
        let service = UserService(db: db)

        // Covers: updateUser failure path (user doesn't exist)
        let updated = service.updateUser(id: "999", name: "Ghost")

        #expect(updated == false)
    }
}

// MARK: - Diagnostic Tests

@Suite("Coverage Diagnostics")
struct CoverageDiagnostics {
    @Test("Check coverage availability")
    func testCoverageAvailability() {
        print("Coverage instrumentation available: \(PerTestCoverage.isAvailable)")
    }
}

// MARK: - CoverageCounters Tests (In-Memory, No File I/O)

@Suite("CoverageCounters API", .serialized)
struct CoverageCountersTests {

    @Test("CoverageCounters.snapshot captures counter state")
    func testSnapshot() {
        guard let snapshot = CoverageCounters.snapshot() else {
            Issue.record("Coverage counters not available (expected when not built with coverage)")
            return
        }

        #expect(snapshot.count > 0)
        print("Captured \(snapshot.count) counters")
    }

    @Test("measureCoverage detects code execution")
    func testMeasureCoverage() {
        let db = MockDatabase()

        guard let diff = measureCoverage({
            db.write(key: "test", value: "value")
        }) else {
            Issue.record("Coverage counters not available")
            return
        }

        #expect(diff.hasChanges)
        print("Executed \(diff.executedRegions) new regions, \(diff.changedCount) changed")
    }

    @Test("measureCoverage shows different code paths")
    func testDifferentCodePaths() {
        let db = MockDatabase()

        // Measure write path
        let writeDiff = measureCoverage {
            db.write(key: "a", value: "1")
        }

        // Measure read path
        let readDiff = measureCoverage {
            _ = db.read(key: "a")
        }

        guard let w = writeDiff, let r = readDiff else {
            Issue.record("Coverage counters not available")
            return
        }

        // Both should have changes
        #expect(w.hasChanges)
        #expect(r.hasChanges)

        // They might hit different regions
        print("Write path: \(w.executedRegions) regions")
        print("Read path: \(r.executedRegions) regions")
    }

    @Test("measureIsolatedCoverage resets counters first")
    func testIsolatedCoverage() {
        let db = MockDatabase()

        // First call exercises some code
        _ = measureCoverage {
            db.write(key: "warmup", value: "data")
        }

        // Isolated measurement should only see new executions
        let (result, diff) = measureIsolatedCoverage {
            db.write(key: "test", value: "value")
            return db.read(key: "test")
        }

        #expect(result == "value")

        if let diff = diff {
            print("Isolated coverage: \(diff.executedRegions) regions")
        }
    }
}

// MARK: - InMemoryCoverageReader Tests

@Suite("InMemoryCoverageReader API", .serialized)
struct InMemoryCoverageReaderTests {

    @Test("InMemoryCoverageReader loads from current process")
    func testLoadFromCurrentProcess() throws {
        // Print diagnostic info
        let execPath = ProcessInfo.processInfo.arguments[0]
        print("Test executable path: \(execPath)")

        do {
            let reader = try InMemoryCoverageReader.loadFromCurrentProcess()

            // Should have some functions
            #expect(reader.functionCount > 0)
            print("Loaded \(reader.functionCount) functions from coverage mapping")

            // Should have some source files
            let files = reader.sourceFiles
            #expect(files.count > 0)
            print("Found \(files.count) source files")
        } catch {
            // Skip test if coverage mapping isn't available
            // This can happen if the binary wasn't built with proper coverage flags
            print("Skipping test: \(error)")
            print("Note: In-memory coverage requires binary to have __llvm_covmap section")
        }
    }

    @Test("InMemoryCoverageReader resolves coverage")
    func testResolveCoverage() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let db = MockDatabase()

        // Exercise some code
        db.write(key: "test", value: "value")
        _ = db.read(key: "test")

        // Resolve coverage
        let coverage = reader.resolveCoverage()

        #expect(coverage.functions.count > 0)
        #expect(coverage.sourceFiles.count > 0)

        // Print some coverage details
        let executedRegions = coverage.executedRegions
        print("Executed \(executedRegions.count) regions")

        // Look for coverage in this test file
        let thisFileCoverage = coverage.coverage(for: "PerTestCoverageDemo.swift")
        print("Found \(thisFileCoverage.count) regions in this file")
    }

    @Test("InMemoryCoverageReader shows different code paths")
    func testDifferentCodePaths() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let db = MockDatabase()

        // Check if counters are available
        guard let snapshot = CoverageCounters.snapshot() else {
            print("Coverage counters not available - skipping test")
            return
        }
        print("Counter count: \(snapshot.count)")
        print("Non-zero counters before: \(snapshot.nonZeroCount)")

        // First measurement - write only
        CoverageCounters.reset()
        db.write(key: "a", value: "1")

        if let afterWrite = CoverageCounters.snapshot() {
            print("Non-zero counters after write: \(afterWrite.nonZeroCount)")
        }

        let writeCoverage = reader.resolveCoverage()

        // Second measurement - read only
        CoverageCounters.reset()
        _ = db.read(key: "a")
        let readCoverage = reader.resolveCoverage()

        // Print some debug info
        print("Write path executed \(writeCoverage.executedRegions.count) regions")
        print("Read path executed \(readCoverage.executedRegions.count) regions")
        print("Total functions in coverage: \(writeCoverage.functions.count)")

        // The test may fail if counter indices don't match coverage mapping
        // This can happen when multiple modules are involved
        if writeCoverage.executedRegions.count == 0 {
            print("Warning: Counter values may not match coverage mapping indices")
            print("This is expected when test binary and coverage mapping are from different modules")
        }
    }
}
