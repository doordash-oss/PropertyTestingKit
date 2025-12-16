//
//  PerTestCoverageDemo.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import PropertyTestingKit
import Foundation

/// These tests demonstrate per-test coverage using the `.coverage` trait.
///
/// The trait automatically:
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
@Suite("Per-Test Coverage Demo", .coverage(outputDirectory: "/tmp"))
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
