import Testing
import PropertyTestingKit

/// Diagnostic test to investigate why UserService.createUser shows 0 coverage
/// while updateUser shows 1 call in Xcode.
@Suite("UserService Coverage Diagnostics", .serialized)
struct UserServiceCoverageDiagnostics {

    @Test("Compare createUser vs updateUser coverage")
    func compareUserServiceMethods() throws {
        let db = MockDatabase()
        let service = UserService(db: db)

        // Measure createUser
        let (createResult, createCoverage) = try measureSourceCoverage {
            return service.createUser(id: "test1", name: "Alice")
        }

        // Measure updateUser (on existing user)
        _ = service.createUser(id: "test2", name: "Bob")
        let (updateResult, updateCoverage) = try measureSourceCoverage {
            return service.updateUser(id: "test2", name: "Bob Updated")
        }

        print("\n=== createUser Coverage ===")
        print("Result: \(createResult)")
        let createUserFns = createCoverage.functions.filter { $0.name.contains("createUser") }
        for fn in createUserFns {
            print("Function: \(fn.name)")
            print("  executionCount: \(fn.executionCount)")
            for region in fn.regions {
                print("  Region \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount)")
            }
        }

        print("\n=== updateUser Coverage ===")
        print("Result: \(updateResult)")
        let updateUserFns = updateCoverage.functions.filter { $0.name.contains("updateUser") }
        for fn in updateUserFns {
            print("Function: \(fn.name)")
            print("  executionCount: \(fn.executionCount)")
            for region in fn.regions {
                print("  Region \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount)")
            }
        }

        // Also check raw counter changes
        print("\n=== Raw Counter Analysis ===")
        guard let before = CoverageCounters.snapshot() else {
            print("No counters available")
            return
        }

        _ = service.createUser(id: "test3", name: "Charlie")

        guard let afterCreate = CoverageCounters.snapshot() else {
            print("No counters available after create")
            return
        }

        let createDiff = afterCreate.difference(from: before)
        print("createUser changed \(createDiff.changedCount) counters")
        print("createUser newly executed \(createDiff.executedRegions) regions")
        print("Changed indices: \(createDiff.changedIndices.prefix(20))...")

        _ = service.updateUser(id: "test3", name: "Charlie Updated")

        guard let afterUpdate = CoverageCounters.snapshot() else {
            print("No counters available after update")
            return
        }

        let updateDiff = afterUpdate.difference(from: afterCreate)
        print("\nupdateUser changed \(updateDiff.changedCount) counters")
        print("updateUser newly executed \(updateDiff.executedRegions) regions")
        print("Changed indices: \(updateDiff.changedIndices.prefix(20))...")

        // Basic assertions
        #expect(createResult == true)
        #expect(updateResult == true)
    }

    @Test("Check all UserService functions in coverage mapping")
    func checkUserServiceInCoverageMapping() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
        let coverage = reader.resolveCoverage()

        print("\n=== All UserService Functions in Coverage Mapping ===")
        let userServiceFns = coverage.functions.filter {
            $0.name.contains("UserService")
        }

        for fn in userServiceFns {
            print("\nFunction: \(fn.name)")
            print("  Hash: \(fn.hash)")
            print("  Execution count: \(fn.executionCount)")
            print("  Regions: \(fn.regions.count)")
            for region in fn.regions {
                print("    \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount) (\(region.filename.split(separator: "/").last ?? ""))")
            }
        }

        #expect(userServiceFns.count > 0, "Should have UserService functions")
    }

    @Test("Direct counter inspection for UserService methods")
    func inspectCountersDirectly() throws {
        // Get a fresh snapshot
        guard let snapshot1 = CoverageCounters.snapshot() else {
            Issue.record("No counters")
            return
        }

        let db = MockDatabase()
        let service = UserService(db: db)

        // Call createUser
        let created = service.createUser(id: "direct1", name: "Test")
        #expect(created == true)

        guard let snapshot2 = CoverageCounters.snapshot() else {
            Issue.record("No counters after create")
            return
        }

        // Find which counters changed
        var createChanges: [(index: Int, before: UInt64, after: UInt64)] = []
        for i in 0..<min(snapshot1.count, snapshot2.count) {
            if snapshot2.counters[i] != snapshot1.counters[i] {
                createChanges.append((i, snapshot1.counters[i], snapshot2.counters[i]))
            }
        }

        print("\n=== Counters changed by createUser ===")
        print("Total changed: \(createChanges.count)")
        for change in createChanges.prefix(30) {
            print("  [\(change.index)]: \(change.before) -> \(change.after)")
        }

        // Now call updateUser
        let updated = service.updateUser(id: "direct1", name: "Updated")
        #expect(updated == true)

        guard let snapshot3 = CoverageCounters.snapshot() else {
            Issue.record("No counters after update")
            return
        }

        var updateChanges: [(index: Int, before: UInt64, after: UInt64)] = []
        for i in 0..<min(snapshot2.count, snapshot3.count) {
            if snapshot3.counters[i] != snapshot2.counters[i] {
                updateChanges.append((i, snapshot2.counters[i], snapshot3.counters[i]))
            }
        }

        print("\n=== Counters changed by updateUser ===")
        print("Total changed: \(updateChanges.count)")
        for change in updateChanges.prefix(30) {
            print("  [\(change.index)]: \(change.before) -> \(change.after)")
        }

        // Check overlap
        let createIndices = Set(createChanges.map { $0.index })
        let updateIndices = Set(updateChanges.map { $0.index })
        let overlap = createIndices.intersection(updateIndices)
        print("\n=== Overlap ===")
        print("Counters changed by both: \(overlap.sorted().prefix(20))...")
    }
}
