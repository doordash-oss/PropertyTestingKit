//
//  WithCoverageTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import PropertyTestingKit

@Suite("withCoverage API", .serialized)
struct WithCoverageAPITests {
    @Test("withCoverage captures coverage snapshot")
    func testWithCoverageBasic() throws {
        let db = MockDatabase()

        let (result, coverage) = try withCoverage {
            db.write(key: "test", value: "value")
            return db.read(key: "test")
        }

        #expect(result == "value")
        #expect(coverage.exists)
        #expect((coverage.fileSize ?? 0) > 0)

        // Clean up
        try coverage.delete()
    }

    @Test("withCoverage returns result correctly")
    func testWithCoverageReturnsResult() throws {
        let (result, coverage) = try withCoverage {
            return 42 * 2
        }

        #expect(result == 84)
        try coverage.delete()
    }

    @Test("withCoverage Void overload returns snapshot")
    func testWithCoverageVoid() throws {
        var sideEffect = 0

        let coverage = try withCoverage {
            sideEffect = 123
        }

        #expect(sideEffect == 123)
        #expect(coverage.exists)
        try coverage.delete()
    }

    @Test("withCoverage isolates coverage between calls")
    func testCoverageIsolation() throws {
        let db = MockDatabase()

        // First capture - only write
        let coverage1 = try withCoverage {
            db.write(key: "a", value: "1")
        }

        // Second capture - only read
        let coverage2 = try withCoverage {
            _ = db.read(key: "a")
        }

        // Both should have captured coverage
        #expect(coverage1.exists)
        #expect(coverage2.exists)

        // They should be different files
        #expect(coverage1.profilePath != coverage2.profilePath)

        try coverage1.delete()
        try coverage2.delete()
    }
}
