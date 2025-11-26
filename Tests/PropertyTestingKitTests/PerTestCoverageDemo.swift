//
//  PerTestCoverageDemo.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
@testable import PropertyTestingKit

// MARK: - Example Code to Test (simulating production code)

/// A simple database-like class to demonstrate coverage isolation.
class MockDatabase {
    private var data: [String: String] = [:]
    var writeCount = 0
    var readCount = 0

    func write(key: String, value: String) {
        writeCount += 1
        data[key] = value
    }

    func read(key: String) -> String? {
        readCount += 1
        return data[key]
    }

    func delete(key: String) -> Bool {
        if data.removeValue(forKey: key) != nil {
            return true
        }
        return false
    }

    func exists(key: String) -> Bool {
        return data[key] != nil
    }

    func clear() {
        data.removeAll()
        writeCount = 0
        readCount = 0
    }
}

/// A service that uses the database.
class UserService {
    let db: MockDatabase

    init(db: MockDatabase) {
        self.db = db
    }

    func createUser(id: String, name: String) -> Bool {
        if db.exists(key: "user:\(id)") {
            return false // User already exists
        }
        db.write(key: "user:\(id)", value: name)
        return true
    }

    func getUser(id: String) -> String? {
        return db.read(key: "user:\(id)")
    }

    func deleteUser(id: String) -> Bool {
        return db.delete(key: "user:\(id)")
    }

    func updateUser(id: String, name: String) -> Bool {
        if !db.exists(key: "user:\(id)") {
            return false // User doesn't exist
        }
        db.write(key: "user:\(id)", value: name)
        return true
    }
}

// MARK: - Demo Tests with Per-Test Coverage

/// These tests demonstrate how to capture coverage per-test.
///
/// Run with coverage enabled:
/// ```
/// swift test --enable-code-coverage
/// ```
///
/// Then check the coverage files in the current directory:
/// ```
/// ls coverage-*.profraw
/// ```
struct PerTestCoverageDemo {

    @Test func testDbWriteCall() {
        PerTestCoverage.run(testName: "testDbWriteCall") {
            let db = MockDatabase()

            // This test ONLY covers the write path
            db.write(key: "foo", value: "bar")

            #expect(db.writeCount == 1)
            #expect(db.readCount == 0) // We didn't read
        }
    }

    @Test func testDbReadCall() {
        PerTestCoverage.run(testName: "testDbReadCall") {
            let db = MockDatabase()
            db.write(key: "foo", value: "bar")

            // This test covers write AND read paths
            let result = db.read(key: "foo")

            #expect(result == "bar")
            #expect(db.readCount == 1)
        }
    }

    @Test func testDbDeleteCall() {
        PerTestCoverage.run(testName: "testDbDeleteCall") {
            let db = MockDatabase()
            db.write(key: "foo", value: "bar")

            // This test covers write AND delete paths
            let deleted = db.delete(key: "foo")

            #expect(deleted == true)
        }
    }

    @Test func testDbDeleteNonexistent() {
        PerTestCoverage.run(testName: "testDbDeleteNonexistent") {
            let db = MockDatabase()

            // This test covers the "not found" branch in delete
            let deleted = db.delete(key: "nonexistent")

            #expect(deleted == false)
        }
    }

    @Test func testUserServiceCreateUser() {
        PerTestCoverage.run(testName: "testUserServiceCreateUser") {
            let db = MockDatabase()
            let service = UserService(db: db)

            // Covers: createUser success path, exists (false branch)
            let created = service.createUser(id: "123", name: "Alice")

            #expect(created == true)
        }
    }

    @Test func testUserServiceCreateDuplicateUser() {
        PerTestCoverage.run(testName: "testUserServiceCreateDuplicateUser") {
            let db = MockDatabase()
            let service = UserService(db: db)

            _ = service.createUser(id: "123", name: "Alice")

            // Covers: createUser failure path (user exists), exists (true branch)
            let createdAgain = service.createUser(id: "123", name: "Bob")

            #expect(createdAgain == false)
        }
    }

    @Test func testUserServiceUpdateExisting() {
        PerTestCoverage.run(testName: "testUserServiceUpdateExisting") {
            let db = MockDatabase()
            let service = UserService(db: db)

            _ = service.createUser(id: "123", name: "Alice")

            // Covers: updateUser success path
            let updated = service.updateUser(id: "123", name: "Alice Updated")

            #expect(updated == true)
            #expect(service.getUser(id: "123") == "Alice Updated")
        }
    }

    @Test func testUserServiceUpdateNonexistent() {
        PerTestCoverage.run(testName: "testUserServiceUpdateNonexistent") {
            let db = MockDatabase()
            let service = UserService(db: db)

            // Covers: updateUser failure path (user doesn't exist)
            let updated = service.updateUser(id: "999", name: "Ghost")

            #expect(updated == false)
        }
    }
}

// MARK: - Print Instructions

/// A test that prints usage instructions (run this to see how to analyze coverage).
@Test func printCoverageInstructions() {
    CoverageAnalyzer.printUsageInstructions()
}

// MARK: - Diagnostic Test

@Test func testCoverageAvailability() {
    print("🔍 Coverage instrumentation available: \(PerTestCoverage.isAvailable)")
    print("🔍 Output directory: \(PerTestCoverage.outputDirectory)")
}
